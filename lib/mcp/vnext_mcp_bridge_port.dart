/// Explicit inactive Bridge adapter. No startup, connection or App authority.
library;

import 'dart:async';
import '../data/external/windows_tls_transport.dart';
import 'vnext_mcp_protocol_projection.dart';
import 'vnext_mcp_server.dart';

/// Trusted composition supplies ONE already verified connection. A fresh Port
/// requires another explicitly authenticated connection; no reconnect is done.
final class VnextMcpBridgePort implements VnextMcpPort {
  VnextMcpBridgePort(this.bridge);
  final WindowsTlsBridge bridge;
  bool _closed = false, _attempted = false;
  Future<void>? _closing;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || _attempted) {
      return vnextFailure('unavailable');
    }
    if (!available()) {
      unawaited(close().catchError((Object _) {}));
      return vnextFailure('unavailable');
    }
    final VnextMcpCommand command;
    try {
      command = VnextMcpCommand.parse(tool, arguments);
    } catch (_) {
      return vnextFailure('invalidRequest');
    }
    // v3 carries untrusted READ/key selectors to the original App authority.
    // STAGE needs the explicit same-connection first-party waiting profile.
    if (command.bridgeStageBlocked && !bridge.enableStageApprovalWait) {
      return vnextFailure('capability.accessDenied');
    }
    _attempted = true;
    var interrupted = false;
    final subscription = cancelled.listen((_) {
      interrupted = true;
      unawaited(close().catchError((Object _) {}));
    });
    try {
      if (_closed || interrupted || !available()) {
        await close();
        return vnextFailure('cancelled');
      }
      const id = 'mcp_bridge_1'; // Correlation only; never a submission key.
      final response = command.bridgeStageBlocked
          ? await bridge.requestStageApproval(
              requestId: id, buildPayload: () => command.payload)
          : await bridge.request(requestId: id, payload: command.payload);
      if (_closed || interrupted || !available()) {
        return vnextFailure('cancelled');
      }
      try {
        return command.response(response, id);
      } catch (_) {
        return vnextFailure('invalidResult');
      }
    } on TlsBridgeException catch (error) {
      return vnextFailure(
          error.executionUnknown ? 'outcome_unknown' : error.failure.name);
    } catch (_) {
      return vnextFailure('outcome_unknown');
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= bridge.close();
  }
}
