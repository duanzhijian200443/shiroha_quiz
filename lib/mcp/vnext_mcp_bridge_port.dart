/// Explicit inactive Bridge adapter. No startup, connection or App authority.
library;

import 'dart:async';
import '../data/external/windows_tls_transport.dart';
import 'vnext_mcp_protocol_projection.dart';
import 'vnext_mcp_server.dart';

/// Trusted composition supplies ONE already verified connection. A fresh Port
/// requires another explicitly authenticated connection; no reconnect is done.
final class VnextMcpBridgePort implements VnextMcpPort {
  VnextMcpBridgePort(this.bridge, {this.profileVersion = 2});
  final WindowsTlsBridge bridge;
  final int profileVersion;
  Map<String, Object?> _failure(String code) => vnextFailure(code,
      profileVersion: profileVersion,
      source: const VnextDataSource('windows', 'local'));
  bool _closed = false, _attempted = false;
  Future<void>? _closing;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || _attempted) {
      return _failure('unavailable');
    }
    if (!available()) {
      unawaited(close().catchError((Object _) {}));
      return _failure('unavailable');
    }
    final VnextMcpCommand command;
    try {
      command = profileVersion == 3
          ? VnextMcpCommand.parseUnified(tool, arguments)
          : VnextMcpCommand.parse(tool, arguments);
    } catch (_) {
      return _failure('invalidRequest');
    }
    // v3 carries untrusted READ/key selectors to the original App authority.
    // STAGE needs the explicit same-connection first-party waiting profile.
    if (command.bridgeStageBlocked && !bridge.enableStageApprovalWait) {
      return _failure('capability.accessDenied');
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
        return _failure('cancelled');
      }
      const id = 'mcp_bridge_1'; // Correlation only; never a submission key.
      final response = command.bridgeStageBlocked
          ? await bridge.requestStageApproval(
              requestId: id, buildPayload: () => command.payload)
          : await bridge.request(requestId: id, payload: command.payload);
      if (_closed || interrupted || !available()) {
        return _failure('cancelled');
      }
      try {
        return {
          ...command.response(response, id),
          if (profileVersion == 3)
            'source': const VnextDataSource('windows', 'local').toJson()
        };
      } catch (_) {
        return _failure('invalidResult');
      }
    } on TlsBridgeException catch (error) {
      return _failure(
          error.executionUnknown ? 'outcome_unknown' : error.failure.name);
    } catch (_) {
      return _failure('outcome_unknown');
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
