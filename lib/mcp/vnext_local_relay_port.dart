import 'dart:async';

import '../data/external/windows_local_relay.dart';
import 'vnext_mcp_server.dart';

/// Codex owns only this adapter. Discovery constructs no connection or Owner.
final class VnextLocalRelayPort implements VnextMcpPort {
  WindowsLocalRelay? _connection;
  Future<void>? _closing;
  bool _busy = false, _closed = false;
  int _nextId = 0;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || !available()) return vnextFailure('unavailable');
    if (_busy) return vnextFailure('busy');
    _busy = true;
    final cancellation = cancelled.listen((_) {
      unawaited(close().then((_) {}, onError: (Object _, StackTrace __) {}));
    });
    try {
      if (!VnextMcpServer.inputSchemas.containsKey(tool) ||
          _nextId >= 0x7fffffff) {
        return vnextFailure('invalidRequest');
      }
      if (_connection == null) {
        final connection = _connection = WindowsLocalRelay.openAdapter();
        await connection.accept();
        if (_closed || !available()) throw const LocalRelayException();
      }
      final connection = _connection!;
      final id = ++_nextId;
      await connection.send(
          {'version': 1, 'id': id, 'tool': tool, 'arguments': arguments},
          const Duration(seconds: 5));
      final response = await connection.receive(
          tool == 'propose_generated_questions'
              ? const Duration(seconds: 150)
              : const Duration(seconds: 15));
      if (_closed ||
          !available() ||
          response.length != 3 ||
          response['version'] != 1 ||
          response['id'] != id ||
          response['result'] is! Map<String, dynamic>) {
        throw const LocalRelayException();
      }
      return response['result']! as Map<String, dynamic>;
    } catch (_) {
      await close();
      // Unknown writes are never replayed or described as successful/rolled back.
      return vnextFailure('unavailable');
    } finally {
      await cancellation.cancel();
      _busy = false;
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await _connection?.close();
    }();
  }
}
