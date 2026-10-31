import 'dart:async';
import '../data/external/windows_local_relay.dart';
import '../data/external/link/link_values.dart';
import 'vnext_mcp_server.dart';

/// Optional adjacent Windows client. The ORIGINAL App owns every Bridge/key.
final class LinkWindowsClient implements VnextMcpPort {
  WindowsLocalRelay? _pipe;
  int _nextId = 0;
  bool _closed = false, _busy = false;
  Future<void>? _closing;
  Future<LinkVerifiedTarget> connect() async {
    final pipe = _pipe = WindowsLocalRelay.openAdapter();
    await pipe.accept();
    await pipe
        .send({'version': 2, 'kind': 'attach'}, const Duration(seconds: 5));
    final response = await pipe.receive(const Duration(seconds: 5));
    linkFields(response, {'version', 'kind', 'binding'});
    if (response['version'] != 2 ||
        response['kind'] != 'attached' ||
        response['binding'] is! Map<String, dynamic>) {
      linkFail('unavailable');
    }
    return LinkVerifiedTarget.fromJson(
        response['binding'] as Map<String, dynamic>);
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || _pipe == null || !available()) {
      return vnextFailure('unavailable', profileVersion: 3);
    }
    if (_busy) return vnextFailure('busy', profileVersion: 3);
    _busy = true;
    try {
      final id = ++_nextId;
      await _pipe!.send({
        'version': 2,
        'kind': 'call',
        'id': id,
        'tool': tool,
        'arguments': arguments
      }, const Duration(seconds: 5));
      final response = await _pipe!.receive(
          tool == 'propose_generated_questions'
              ? const Duration(seconds: 150)
              : const Duration(seconds: 15));
      linkFields(response, {'version', 'id', 'result'});
      if (response['version'] != 2 ||
          response['id'] != id ||
          response['result'] is! Map<String, dynamic>) {
        linkFail('unavailable');
      }
      return response['result'] as Map<String, dynamic>;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      final pipe = _pipe;
      if (pipe == null) return;
      try {
        if (_busy) linkFail('owner_unsettled');
        final id = ++_nextId;
        await pipe.send({'version': 2, 'kind': 'close', 'id': id},
            const Duration(seconds: 5));
        final response = await pipe.receive(const Duration(seconds: 45));
        linkFields(response, {'version', 'kind', 'id'});
        if (response['version'] != 2 ||
            response['kind'] != 'closed' ||
            response['id'] != id) {
          linkFail('owner_unsettled');
        }
      } finally {
        await pipe.close();
      }
    }();
  }
}
