/// Explicit inactive Bridge process composition. Construction performs no I/O.
library;

import 'dart:async';

import '../data/external/windows_tls_transport.dart';
import '../mcp/vnext_mcp_bridge_port.dart';
import '../mcp/vnext_mcp_protocol_projection.dart';
import '../mcp/vnext_mcp_server.dart';

/// Owns one connection per independently requested tool call, without replay.
/// The trusted factory captures credential/Discovery owners; it receives no
/// request or identity fields. EOF/close drains the active connection before the
/// caller may release those owners. Failed cleanup permanently closes admission.
final class McpVnextWindowsBridge implements VnextMcpPort {
  McpVnextWindowsBridge({
    required WindowsTlsBridge Function() createConnection,
    this.enableStageApprovalWait = false,
  }) : _createConnection = createConnection;

  final WindowsTlsBridge Function() _createConnection;
  final bool enableStageApprovalWait;
  VnextMcpBridgePort? _active;
  Completer<void>? _pending;
  Future<void>? _closing;
  bool _closed = false, _cleanupFailed = false;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || !available()) return vnextFailure('unavailable');
    if (_pending != null) return vnextFailure('busy');
    final VnextMcpCommand command;
    try {
      command = VnextMcpCommand.parse(tool, arguments);
    } catch (_) {
      return vnextFailure('invalidRequest');
    }
    if (command.bridgeStageBlocked && !enableStageApprovalWait) {
      return vnextFailure('capability.accessDenied');
    }
    final done = _pending = Completer<void>();
    final forwarded = StreamController<void>.broadcast(sync: true);
    var interrupted = false;
    final subscription = cancelled.listen((_) {
      interrupted = true;
      forwarded.add(null);
      unawaited(_active?.close().catchError((Object _) {}));
    });
    Map<String, Object?> result;
    var dispatched = false;
    try {
      final connection = _createConnection();
      final port = _active = VnextMcpBridgePort(connection);
      if (connection.enableStageApprovalWait != enableStageApprovalWait) {
        result = vnextFailure('unavailable');
      } else {
        await connection.connect();
        if (_closed || interrupted || !available()) {
          result = vnextFailure('cancelled');
        } else {
          dispatched = true;
          result = await port.call(tool, arguments,
              cancelled: forwarded.stream,
              available: () => !_closed && !interrupted && available());
        }
      }
    } catch (_) {
      // No business call is retried, including ambiguous connection failures.
      result = vnextFailure(dispatched
          ? 'outcome_unknown'
          : interrupted
              ? 'cancelled'
              : 'unavailable');
    } finally {
      try {
        await _active?.close();
      } catch (_) {
        _cleanupFailed = true;
        _closed = true;
      }
      await subscription.cancel();
      await forwarded.close();
      if (!_cleanupFailed) _active = null;
      _pending = null;
      done.complete();
    }
    return _cleanupFailed ? vnextFailure('outcome_unknown') : result;
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      final pending = _pending;
      try {
        await _active?.close();
      } catch (_) {
        _cleanupFailed = true;
      }
      await pending?.future;
      if (_cleanupFailed) throw StateError('Bridge cleanup unconfirmed');
    }();
  }
}
