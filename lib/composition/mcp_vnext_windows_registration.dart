/// First-party lifetime registration over the original App integration.
library;

import 'dart:async';
import 'dart:io';

import '../application/external/external_trust_core.dart';
import '../application/external/first_party_external_access.dart';
import '../application/external/external_device_connection.dart';
import '../data/external/windows_android_adapter_layout.dart';
import '../application/external/first_party_development_access.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/windows_bridge_process.dart';
import '../data/external/windows_codex_client.dart';
import '../data/external/windows_tls_transport.dart';
import 'mcp_vnext_app_integration.dart';
import 'mcp_vnext_app_owned_relay.dart';
import 'mcp_vnext_windows_acquisition.dart';
import 'mcp_vnext_windows_startup.dart';
import 'mcp_vnext_development_app.dart';

/// Owns the same startup and integration barrier used by App close and B0.
/// Default registration is unavailable. Trusted registration does not Pair,
/// Enable, approve a target or reconnect; those remain explicit App actions.
final class McpVnextWindowsAppRegistration {
  McpVnextWindowsAppRegistration.unavailable(this.integration);

  /// Normal App owns the original adjacent Bridge outside the Codex Job.
  /// The local hop grants no protected Bootstrap/business admission.
  McpVnextWindowsAppRegistration.appOwnedRelay(this.integration,
      {void Function(String, int)? onRelayEvent,
      ExternalDeviceSelectionStore? deviceSelectionStore}) {
    _onRecoveryEvent = onRelayEvent;
    if (deviceSelectionStore != null) {
      _devices = ExternalDeviceConnection(
          store: deviceSelectionStore,
          availableTargets: () async {
            final layout = WindowsAndroidAdapterLayout.resolve(
                Platform.resolvedExecutable);
            return [
              const ExternalDeviceTarget.windows(),
              if (layout?.paired == true && layout?.packagePresent == true)
                ExternalDeviceTarget.android(
                    WindowsAndroidAdapterLayout.reference)
            ];
          },
          endConnection: () => _relay!.endCurrentConnection(),
          verifyRecovery: _recoverAndroid);
      integration.controls.installDeviceConnection(_devices!);
    }
    _relay = McpVnextAppOwnedRelay(
        onEvent: onRelayEvent,
        requireBusinessBootstrap: true,
        devices: _devices);
    _development =
        McpVnextDevelopmentApp(integration: integration, relay: _relay!);
    integration.controls.installDevelopment(_development!);
  }

  McpVnextWindowsAppRegistration.directClient({
    required this.integration,
    required McpVnextWindowsProtectedAcquirer acquirer,
    required Future<void> Function() requireSecurityAdmission,
    required ExternalClock clock,
    required LocalHostReadinessPort readiness,
    required int port,
    TlsListenerIo? listener,
    WindowsCodexClientSelection? clientSelection,
    bool enableStageApprovalWait = false,
  }) {
    _install(
        acquirer,
        requireSecurityAdmission,
        clock,
        readiness,
        port,
        listener,
        null,
        enableStageApprovalWait,
        clientSelection,
        WindowsCodexConnectionMode.direct);
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
    WindowsCodexClientSelection? clientSelection,
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
        enableStageApprovalWait,
        clientSelection,
        WindowsCodexConnectionMode.hosted);
  }

  final McpVnextAppIntegration integration;
  McpVnextAppOwnedRelay? _relay;
  ExternalDeviceConnection? _devices;
  WindowsBridgeProcess? _recoveryChild;
  void Function(String, int)? _onRecoveryEvent;
  FirstPartyChildObservation? _lastRecoveryObservation;
  FirstPartyChildObservation? get recoveryObservation =>
      _recoveryChild?.observation ?? _lastRecoveryObservation;

  void _reportRecovery(String event) {
    try {
      _onRecoveryEvent?.call(event, 0);
    } catch (_) {/* Observation only. */}
  }

  Future<void> _recoverAndroid(ExternalDeviceTarget target) async {
    if (_closed ||
        _recoveryChild != null ||
        target.kind != ExternalDeviceKind.android ||
        target.reference != WindowsAndroidAdapterLayout.reference) {
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
    final child = _recoveryChild = WindowsBridgeProcess.androidRecovery(
        onDiagnostic: (stage, failure) => _reportRecovery(failure == null
            ? 'androidRecoveryStage:$stage'
            : 'androidRecoveryFailure:$stage:$failure'));
    _reportRecovery('androidRecoveryStarting');
    try {
      await child.start();
      await child.exited;
      await child.stopAndWait();
      if (_closed) {
        throw const ExternalDeviceException(
            ExternalDeviceFailure.needsAttention);
      }
      _reportRecovery('androidRecoverySettled');
    } catch (_) {
      _reportRecovery('androidRecoveryFailed');
      rethrow;
    } finally {
      try {
        await child.stopAndWait();
      } finally {
        _lastRecoveryObservation = child.observation;
        _recoveryChild = null;
      }
    }
  }

  bool get localRelayAvailable => _relay?.available == true;
  FirstPartyRelayObservation get relayObservation =>
      _relay?.observation ??
      const FirstPartyRelayObservation(FirstPartyRelayPhase.unavailable);
  FirstPartyChildObservation? get businessObservation =>
      _relay?.businessObservation;
  ({String stage, String code})? get androidLinkFailure =>
      _relay?.androidLinkFailure;
  McpVnextWindowsAppStartup? _startup;
  McpVnextDevelopmentApp? _development;
  McpVnextWindowsProtectedAcquirer? _acquirer;
  Future<void>? _starting, _closing;
  bool _closed = false;

  /// The existing host/control state remains authoritative for connections.
  McpVnextWindowsAppStartup? get startup => _startup ?? _development?.startup;
  bool get registered => startup != null;

  void _install(
      McpVnextWindowsProtectedAcquirer acquirer,
      Future<void> Function() requireSecurityAdmission,
      ExternalClock clock,
      LocalHostReadinessPort readiness,
      int port,
      TlsListenerIo? listener,
      WindowsBridgeProcess? child,
      bool enableStageApprovalWait,
      WindowsCodexClientSelection? clientSelection,
      WindowsCodexConnectionMode mode) {
    _acquirer = acquirer;
    _startup = McpVnextWindowsAppStartup(
        integration: integration,
        enableStageApprovalWait: enableStageApprovalWait,
        acquire: () async {
          if (clientSelection == null) {
            throw StateError('Codex client unsupported');
          }
          await clientSelection.claim(mode);
          if (_closed) throw StateError('Windows registration unavailable');
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
        try {
          await _devices?.load();
        } catch (_) {/* The selector retains needsAttention. */}
        _relay?.start();
        await _startup?.start();
      } catch (_) {
        await close();
        throw StateError('Windows registration unavailable');
      }
    }();
  }

  Future<void> close() {
    _closed = true;
    _devices?.withdraw();
    return _closing ??= () async {
      try {
        await Future.wait([
          if (_relay != null) _relay!.close(),
          if (_recoveryChild != null) _recoveryChild!.stopAndWait(),
          if (_startup != null) _startup!.close(),
          if (_development != null)
            _development!.stopFor(FirstPartyDevelopmentStopCause.appClose),
          integration.close(),
        ]);
      } finally {
        // A failing closer must not skip joining original acquisition cleanup.
        try {
          await _devices?.close();
        } finally {
          await _acquirer?.whenAcquisitionSettled;
        }
      }
    }();
  }
}
