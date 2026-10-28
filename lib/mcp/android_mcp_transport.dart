import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';

import 'vnext_mcp_server.dart';

VnextMcpServer androidReadServer(VnextMcpPort port) => VnextMcpServer(port,
    protocolServer: McpServer(
      const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
      options: const McpServerOptions(
          instructions:
              'Read the selected Android phone question library. Android STAGE and file operations are unavailable.',
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools())),
    ));

/// Connection lifetime only. The App's P0/P15/Host owners remain outside it.
final class AndroidMcpTransport extends Transport {
  AndroidMcpTransport(
      {required this.read,
      required this.newNonce,
      required this.validNonce,
      required this.write,
      required this.closeChannel,
      required this.invalidate,
      required this.connectionId,
      required this.current});
  final Future<(int, Map<String, dynamic>)> Function() read;
  final String Function() newNonce;
  final bool Function(Object?) validNonce;
  final Future<void> Function(int, Map<String, dynamic>) write;
  final Future<void> Function() closeChannel;
  final void Function() invalidate;
  final String connectionId;
  final bool Function() current;
  final _elapsed = Stopwatch()..start();
  Duration _lastPeer = Duration.zero;
  String? _ping;
  Timer? _timer;
  bool _closed = false, _sendingPing = false;
  Future<void>? _pump, _closing;
  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {
    _lastPeer = _elapsed.elapsed;
    _pump = _read();
    unawaited(_pump!.catchError((Object _) {}));
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closed) return;
      if (!current() ||
          _elapsed.elapsed - _lastPeer >= const Duration(seconds: 45)) {
        unawaited(close().catchError((Object _) {}));
        return;
      }
      if (_ping != null || _sendingPing) return;
      _sendingPing = true;
      final nonce = _ping = newNonce();
      unawaited(write(
              1, {'type': 'ping', 'connectionId': connectionId, 'nonce': nonce})
          .catchError((Object _) {
        unawaited(close().catchError((Object _) {}));
      }).whenComplete(() => _sendingPing = false));
    });
  }

  Future<void> _read() async {
    try {
      while (!_closed) {
        final (kind, message) = await read();
        if (!current()) androidLinkFail();
        if (kind == 1) {
          if (message.length != 3 ||
              !{'type', 'connectionId', 'nonce'}.every(message.containsKey)) {
            androidLinkFail();
          }
          if (message['connectionId'] != connectionId ||
              !validNonce(message['nonce'])) {
            androidLinkFail();
          }
          if (message['type'] == 'ping') {
            await write(1, {...message, 'type': 'pong'});
          } else if (message['type'] == 'pong' &&
              _ping != null &&
              message['nonce'] == _ping) {
            _ping = null;
          } else {
            androidLinkFail();
          }
        } else if (kind == 2) {
          final parsed = JsonRpcMessage.fromJson(message);
          onmessage
              ?.call(parsed); // SDK work does not occupy the control reader.
        } else {
          androidLinkFail();
        }
        _lastPeer = _elapsed.elapsed;
      }
    } finally {
      _closed = true;
      _timer?.cancel();
      invalidate();
      onclose?.call();
    }
  }

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    if (_closed || !current()) androidLinkFail();
    await write(2, message.toJson());
  }

  @override
  Future<void> close() => _closing ??= () async {
        _closed = true;
        _timer?.cancel();
        invalidate();
        try {
          await closeChannel();
        } finally {
          try {
            await _pump;
          } catch (_) {/* Original channel close decides settlement. */}
          onclose?.call();
        }
      }();
}

Never androidLinkFail() => throw StateError('android_link_unavailable');

/// READ-only Android guard over the unchanged seven-tool schema and App port.
/// Closing it cancels and joins its original calls, never App-wide shutdown.
final class AndroidReadOnlyPort implements VnextMcpPort {
  AndroidReadOnlyPort(this.inner, this.current);
  final VnextMcpPort inner;
  final bool Function() current;
  final _cancel = StreamController<void>.broadcast(sync: true);
  Completer<void>? _idle;
  bool _closed = false;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || !current()) return vnextFailure('unavailable');
    if (!const {
      'open_generation_context',
      'search_questions',
      'get_question_detail'
    }.contains(tool)) {
      return vnextFailure('unavailable');
    }
    if (_idle != null) return vnextFailure('resourceLimit');
    final done = _idle = Completer<void>();
    final merged = StreamController<void>.broadcast(sync: true);
    final subscriptions = [
      cancelled.listen((_) => merged.add(null)),
      _cancel.stream.listen((_) => merged.add(null))
    ];
    try {
      return await inner.call(tool, arguments,
          cancelled: merged.stream,
          available: () => !_closed && current() && available());
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await merged.close();
      _idle = null;
      done.complete();
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _cancel.add(null);
    }
    await _idle?.future;
    await _cancel.close();
  }
}
