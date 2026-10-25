import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/external/windows_bridge_process.dart';
import '../data/external/windows_local_relay.dart';
import '../data/external/windows_release_candidate.dart';
import '../mcp/vnext_app_owned_client.dart';
import '../mcp/vnext_mcp_server.dart';

/// Normal App custody for the new local hop. It does not manufacture admission
/// for the adjacent Bridge: its existing formal entry remains fail-closed.
final class McpVnextAppOwnedRelay {
  McpVnextAppOwnedRelay({void Function(String, int)? onEvent})
      : _onEvent = onEvent;
  final void Function(String, int)? _onEvent;
  int _connectionId = 0;
  void _report(String event) {
    try {
      _onEvent?.call(event, _connectionId);
    } catch (_) {/* Observation only. */}
  }

  WindowsLocalRelay? _pipe;
  _OwnedBridge? _bridge;
  Future<void>? _serving, _closing;
  bool _closed = false, _failed = false, _nativeUnsettled = false;
  bool get available => !_closed && !_failed && _pipe != null;

  /// Registration errors disable only this optional connection surface.
  /// No scan, fallback path, credentials or external configuration is loaded.
  void start() {
    if (_serving != null || _closed) {
      throw StateError('Local relay unavailable');
    }
    try {
      _pipe = WindowsLocalRelay.openApp();
      _report('listening');
    } on LocalRelayException catch (failure) {
      _nativeUnsettled = failure.unsettled;
      _failed = true;
      _report(failure.unsettled
          ? 'registrationUnsettled'
          : failure.independentAppRequired
              ? 'independentAppRequired'
              : 'registrationUnavailable');
      return;
    }
    _serving = _serve();
    unawaited(_serving!.then((_) {}, onError: (Object _, StackTrace __) {
      _failed = true;
    }));
  }

  Future<void> _serve() async {
    while (!_closed) {
      final pipe = _pipe!;
      try {
        await pipe.accept();
        if (_closed) break;
        _connectionId++;
        _report('peerAuthenticated');
        await _connection(pipe);
      } on LocalRelayException {
        _report('relayInterrupted');
        // Peer interruption is not a successful business call. Original child
        // cleanup below is independent, and an unknown cleanup is never reset.
      } finally {
        await _bridge?.close();
        if (_bridge != null) _report('originalBridgeSettled');
        _bridge = null;
        await pipe.close();
        _pipe = null;
      }
      if (_closed) break;
      // Accept a new explicit adapter connection only after original custody
      // settled. This does not retry any request or restore business authority.
      _pipe = WindowsLocalRelay.openApp();
    }
  }

  Future<void> _connection(WindowsLocalRelay pipe) async {
    var lastId = 0;
    final lost = pipe.disconnected.then((_) async {
      await _bridge?.close();
    });
    unawaited(lost.then((_) {}, onError: (Object _, StackTrace __) {
      _failed = true;
    }));
    try {
      while (!_closed && pipe.isCurrent) {
        // Idle expiry closes this connection; no approval/Session is revived.
        final message = await pipe.receive(const Duration(minutes: 10));
        final id = message['id'];
        final tool = message['tool'];
        final arguments = message['arguments'];
        if (message.length != 4 ||
            message['version'] != 1 ||
            id is! int ||
            id != lastId + 1 ||
            id > 0x7fffffff ||
            tool is! String ||
            !VnextMcpServer.inputSchemas.containsKey(tool) ||
            arguments is! Map<String, dynamic>) {
          throw const LocalRelayException();
        }
        lastId = id;
        if (_closed || !pipe.isCurrent) throw const LocalRelayException();
        Map<String, Object?> result;
        if (_bridge == null && !_OwnedBridge.packagePresent) {
          _report('bridgePackageUnavailable');
          result = vnextFailure('unavailable');
        } else {
          final bridge = _bridge ??= _OwnedBridge(onEvent: _report);
          try {
            await bridge.start();
            if (_closed || !pipe.isCurrent) throw const LocalRelayException();
            result = await bridge.client.call(tool, arguments);
          } catch (_) {
            // No repeated launch or request replay after an unknown effect.
            await bridge.close();
            rethrow;
          }
        }
        if (_closed || !pipe.isCurrent) throw const LocalRelayException();
        await pipe.send({'version': 1, 'id': id, 'result': result},
            const Duration(seconds: 5));
      }
    } finally {
      // Wake the observer even on App close/malformed input, then join it.
      await pipe.close();
      await lost;
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await Future.wait([
        if (_pipe != null) _pipe!.close(),
        if (_bridge != null) _bridge!.close(),
        if (_serving != null) _serving!,
      ]);
      if (_nativeUnsettled || (_failed && _bridge != null)) {
        throw StateError('Local relay unsettled');
      }
    }();
  }
}

/// Stable internal protocol output stays alive after the outer pipe breaks.
/// This keeps the original child's sole stdout consumer draining through EOF.
final class _OwnedBridge {
  _OwnedBridge({required this.onEvent}) {
    _toChild.onListen = () => _toListened = true;
    _fromChild.onListen = () => _fromListened = true;
    _output = IOSink(_ProtocolOutput(_fromChild));
    process =
        WindowsBridgeProcess.stdio(input: _toChild.stream, output: _output);
    client =
        VnextAppOwnedClient(input: _fromChild.stream, output: _toChild.sink);
  }
  static bool get packagePresent {
    final root = p.dirname(Platform.resolvedExecutable);
    return WindowsExternalReleaseCandidate.bridgeFiles
        .every((name) => File(p.join(root, name)).existsSync());
  }

  final _toChild = StreamController<List<int>>(sync: true);
  final void Function(String) onEvent;
  final _fromChild = StreamController<List<int>>(sync: true);
  late final IOSink _output;
  late final WindowsBridgeProcess process;
  late final VnextAppOwnedClient client;
  Future<void>? _starting, _closing;
  bool _closed = false, _toListened = false, _fromListened = false;

  Future<void> start() => _starting ??= () async {
        if (_closed) throw const LocalRelayException();
        await process.start();
        onEvent('originalBridgeStarted');
        if (_closed) throw const LocalRelayException();
        await client.connect();
      }();

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      onEvent('originalBridgeCloseEntered');
      // Invoke the original closer immediately, including during launch. It
      // owns stdin cancellation, original exit and both original output drains.
      await process.stopAndWait();
      // An interrupted launch may never have installed either subscription.
      // Drain those never-consumed controllers before joining their close.
      if (!_fromListened) unawaited(_fromChild.stream.drain<void>());
      if (!_toListened) unawaited(_toChild.stream.drain<void>());
      await _output.close();
      await _fromChild.close();
      await client.close();
      await _toChild.close();
      try {
        await _starting;
      } catch (_) {/* Original cleanup above is authoritative. */}
    }();
  }
}

final class _ProtocolOutput implements StreamConsumer<List<int>> {
  _ProtocolOutput(this.target);
  final StreamController<List<int>> target;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      target.add(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
