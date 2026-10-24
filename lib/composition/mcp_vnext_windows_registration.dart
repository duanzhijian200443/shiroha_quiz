/// First-party lifetime registration over the original App integration.
library;

import 'dart:async';
import 'dart:io';

import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/windows_bridge_process.dart';
import '../data/external/windows_tls_transport.dart';
import 'mcp_vnext_app_integration.dart';
import 'mcp_vnext_windows_acquisition.dart';
import 'mcp_vnext_windows_startup.dart';

/// Owns the same startup and integration barrier used by App close and B0.
/// Default registration is unavailable. Trusted registration does not Pair,
/// Enable, approve a target or reconnect; those remain explicit App actions.
final class McpVnextWindowsAppRegistration {
  McpVnextWindowsAppRegistration.unavailable(this.integration);

  McpVnextWindowsAppRegistration.directClient({
    required this.integration,
    required McpVnextWindowsProtectedAcquirer acquirer,
    required Future<void> Function() requireSecurityAdmission,
    required ExternalClock clock,
    required LocalHostReadinessPort readiness,
    required int port,
    TlsListenerIo? listener,
    bool enableStageApprovalWait = false,
  }) {
    _install(acquirer, requireSecurityAdmission, clock, readiness, port,
        listener, null, enableStageApprovalWait);
  }

  McpVnextWindowsAppRegistration.hostedClient({
    required this.integration,
    required McpVnextWindowsProtectedAcquirer acquirer,
    required Future<void> Function() requireSecurityAdmission,
    required ExternalClock clock,
    required LocalHostReadinessPort readiness,
    required int port,
    required Stream<List<int>> input,
    required IOSink output,
    bool enableStageApprovalWait = false,
  }) {
    _install(
        acquirer,
        requireSecurityAdmission,
        clock,
        readiness,
        port,
        null,
        WindowsBridgeProcess.stdio(input: input, output: output),
        enableStageApprovalWait);
  }

  final McpVnextAppIntegration integration;
  McpVnextWindowsAppStartup? _startup;
  McpVnextWindowsProtectedAcquirer? _acquirer;
  Future<void>? _starting, _closing;
  bool _closed = false;

  /// The existing host/control state remains authoritative for connections.
  McpVnextWindowsAppStartup? get startup => _startup;
  bool get registered => _startup != null;

  void _install(
      McpVnextWindowsProtectedAcquirer acquirer,
      Future<void> Function() requireSecurityAdmission,
      ExternalClock clock,
      LocalHostReadinessPort readiness,
      int port,
      TlsListenerIo? listener,
      WindowsBridgeProcess? child,
      bool enableStageApprovalWait) {
    _acquirer = acquirer;
    _startup = McpVnextWindowsAppStartup(
        integration: integration,
        enableStageApprovalWait: enableStageApprovalWait,
        acquire: () async {
          await requireSecurityAdmission();
          if (_closed) throw StateError('Windows registration unavailable');
          return acquirer.acquireAppRuntime(
              clock: clock,
              readiness: readiness,
              port: port,
              listener: listener,
              process: child,
              clientOwnsBridge: child == null);
        });
  }

  Future<void> start() {
    if (_starting != null || _closed) {
      throw StateError('Windows registration unavailable');
    }
    return _starting = () async {
      try {
        await _startup?.start();
      } catch (_) {
        await close();
        throw StateError('Windows registration unavailable');
      }
    }();
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      try {
        await Future.wait([
          if (_startup != null) _startup!.close(),
          integration.close(),
        ]);
      } finally {
        // A failing closer must not skip joining original acquisition cleanup.
        await _acquirer?.whenAcquisitionSettled;
      }
    }();
  }
}
