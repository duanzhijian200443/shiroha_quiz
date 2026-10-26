import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../application/external/first_party_development_access.dart';
import '../application/external/first_party_external_access.dart';
import '../application/external/external_credential_association.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/native/windows_external_native.dart';
import '../data/external/windows_credential_initialization.dart';
import '../data/external/windows_development_bootstrap.dart';
import '../services/backup/sha256.dart';
import 'mcp_vnext_app_integration.dart';
import 'mcp_vnext_app_owned_relay.dart';
import 'mcp_vnext_development_lifetime.dart';
import 'mcp_vnext_windows_acquisition.dart';
import 'mcp_vnext_windows_startup.dart';

/// Terminal observations survive loss of their former runtime admission.
FirstPartyDevelopmentPhase developmentStatusPhase({
  required FirstPartyDevelopmentPhase phase,
  required bool localAvailable,
}) =>
    switch (phase) {
      FirstPartyDevelopmentPhase.closed ||
      FirstPartyDevelopmentPhase.failed =>
        phase,
      _ => localAvailable ? phase : FirstPartyDevelopmentPhase.unavailable,
    };

/// Observes the fixed synchronous initialization chain. The normal root still
/// supplies the original Native/P25 operations and owns every custody latch.
/// No diagnostic value is used to authorize work or declare rollback.
final class DevelopmentCredentialInitialization {
  FirstPartyInitializationStage _stage = FirstPartyInitializationStage.load;
  bool _ownerReturned = false;
  FirstPartyInitializationCloseResult _closeResult =
      FirstPartyInitializationCloseResult.notAttempted;
  FirstPartyInitializationFailure? _primaryFailure, _cleanupFailure;

  FirstPartyInitializationObservation get observation =>
      FirstPartyInitializationObservation(
          stage: _stage,
          ownerReturned: _ownerReturned,
          closeResult: _closeResult,
          primaryFailure: _primaryFailure,
          cleanupFailure: _cleanupFailure);

  void run({
    required void Function() load,
    required void Function() acquire,
    required ExternalInitializationState Function() initializeP25,
    required void Function() postAdmission,
    required void Function() close,
  }) {
    try {
      load();
      _stage = FirstPartyInitializationStage.acquire;
      acquire();
      _ownerReturned = true;
      _stage = FirstPartyInitializationStage.p25;
      if (initializeP25() == ExternalInitializationState.incomplete) {
        _primaryFailure = FirstPartyInitializationFailure(
            _stage, FirstPartyInitializationFailureCode.incompleteCredentials);
        throw StateError('Incomplete App credentials');
      }
      _stage = FirstPartyInitializationStage.postAdmission;
      postAdmission();
    } catch (error) {
      _primaryFailure ??= FirstPartyInitializationFailure(_stage, _code(error));
      rethrow;
    } finally {
      if (_ownerReturned) {
        _stage = FirstPartyInitializationStage.close;
        _closeResult = FirstPartyInitializationCloseResult.pending;
        try {
          close();
          _closeResult = FirstPartyInitializationCloseResult.returned;
        } catch (error) {
          _cleanupFailure =
              FirstPartyInitializationFailure(_stage, _code(error));
          _closeResult = FirstPartyInitializationCloseResult.failed;
          rethrow;
        }
      }
    }
  }

  static FirstPartyInitializationFailureCode _code(Object error) =>
      switch (error) {
        ExternalNativeException(:final failure) => switch (failure) {
            ExternalNativeFailure.unsupportedPlatform =>
              FirstPartyInitializationFailureCode.nativeUnsupportedPlatform,
            ExternalNativeFailure.libraryUnavailable =>
              FirstPartyInitializationFailureCode.nativeLibraryUnavailable,
            ExternalNativeFailure.abiMismatch =>
              FirstPartyInitializationFailureCode.nativeAbiMismatch,
            ExternalNativeFailure.invalidInput =>
              FirstPartyInitializationFailureCode.nativeInvalidInput,
            ExternalNativeFailure.resourceLimit =>
              FirstPartyInitializationFailureCode.nativeResourceLimit,
            ExternalNativeFailure.temporarilyUnavailable =>
              FirstPartyInitializationFailureCode.nativeTemporarilyUnavailable,
            ExternalNativeFailure.dataCorrupt =>
              FirstPartyInitializationFailureCode.nativeDataCorrupt,
            ExternalNativeFailure.invalidNativeResult =>
              FirstPartyInitializationFailureCode.nativeInvalidNativeResult,
            ExternalNativeFailure.commitUnknown =>
              FirstPartyInitializationFailureCode.nativeCommitUnknown,
            ExternalNativeFailure.verificationRejected =>
              FirstPartyInitializationFailureCode.nativeVerificationRejected,
          },
        ExternalCredentialException(:final failure) => switch (failure) {
            ExternalCredentialFailure.unauthorized =>
              FirstPartyInitializationFailureCode.credentialUnauthorized,
            ExternalCredentialFailure.invalidInput =>
              FirstPartyInitializationFailureCode.credentialInvalidInput,
            ExternalCredentialFailure.conflict =>
              FirstPartyInitializationFailureCode.credentialConflict,
            ExternalCredentialFailure.staleRevision =>
              FirstPartyInitializationFailureCode.credentialStaleRevision,
            ExternalCredentialFailure.dataCorrupt =>
              FirstPartyInitializationFailureCode.credentialDataCorrupt,
            ExternalCredentialFailure.temporarilyUnavailable =>
              FirstPartyInitializationFailureCode
                  .credentialTemporarilyUnavailable,
            ExternalCredentialFailure.commitUnknown =>
              FirstPartyInitializationFailureCode.credentialCommitUnknown,
            ExternalCredentialFailure.verificationRejected =>
              FirstPartyInitializationFailureCode
                  .credentialVerificationRejected,
            ExternalCredentialFailure.resourceLimit =>
              FirstPartyInitializationFailureCode.credentialResourceLimit,
          },
        _ => FirstPartyInitializationFailureCode.unknown,
      };
}

/// One explicitly enabled development runtime over the original App integration.
/// Expiry/stop is terminal; neither credentials nor a live runtime are repaired.
final class McpVnextDevelopmentApp implements FirstPartyDevelopmentAccess {
  McpVnextDevelopmentApp({required this.integration, required this.relay});
  final McpVnextAppIntegration integration;
  final McpVnextAppOwnedRelay relay;
  FirstPartyDevelopmentPhase _phase = FirstPartyDevelopmentPhase.inactive;
  McpVnextWindowsAppStartup? startup;
  McpVnextWindowsProtectedAcquirer? _acquirer;
  ExternalProtectedObjects? _initialOwner;
  DevelopmentCredentialInitialization? _initialization;
  bool _busy = false, _closed = false;
  bool _initialAcquisitionUnsettled = false;
  DateTime? _expiry;
  final _elapsed = Stopwatch();
  Timer? _monitor;
  Future<void>? _closing, _work;
  FirstPartyDevelopmentStopObservation? _stopObservation;
  bool get _local =>
      kDebugMode &&
      Platform.isWindows &&
      relay.launchCurrent &&
      integration.controls.isCurrent &&
      !_closed;
  bool get _current =>
      _local &&
      _expiry != null &&
      DateTime.now().toUtc().isBefore(_expiry!) &&
      _elapsed.elapsed < WindowsDevelopmentBootstrap.lifetime;
  void _requireLocal() {
    if (!_local) throw StateError('Development connection unavailable');
  }

  void _requireCurrent() {
    if (!_current) throw StateError('Development connection unavailable');
  }

  Future<void> _run(Future<void> Function() action) {
    _requireLocal();
    if (_busy) throw StateError('Development connection busy');
    _busy = true;
    return _work = Future<void>.sync(action).whenComplete(() => _busy = false);
  }

  @override
  Future<FirstPartyDevelopmentStatus> status() async {
    bool? issuerMissing, serverMissing, pinMissing;
    if (_local) {
      try {
        // Fixed Known Folder metadata only. Existence never authenticates an
        // object, reads a key, selects an alternate root or grants admission.
        final root = p.join(
            WindowsExternalNative.open().resolveLocalAppData().value,
            'Shiroha',
            'external');
        issuerMissing =
            !await File(p.join(root, 'app', 'trust', 'issuer.bin')).exists();
        serverMissing =
            !await File(p.join(root, 'app', 'trust', 'server.bin')).exists();
        pinMissing = !await File(p.join(root, 'bridge', 'client.bin')).exists();
      } catch (_) {/* Fixed unavailable metadata; no secret/error body. */}
    }
    return FirstPartyDevelopmentStatus(
        phase: developmentStatusPhase(phase: _phase, localAvailable: _local),
        issuerMissing: issuerMissing,
        serverMissing: serverMissing,
        bridgePinMissing: pinMissing,
        pairingWindowOpen: relay.hasPairingChild,
        initialization: _initialization?.observation,
        pairingChild: relay.pairingObservation,
        businessChild: relay.businessObservation,
        stopObservation: _stopObservation);
  }

  @override
  Future<void> initializeCredentials() => _run(() async {
        if (_phase != FirstPartyDevelopmentPhase.inactive || startup != null) {
          throw StateError('Credential initialization unavailable');
        }
        final operation =
            _initialization = DevelopmentCredentialInitialization();
        late WindowsExternalNative native;
        late ExternalProtectedObjects owner;
        try {
          operation.run(
              load: () => native = WindowsExternalNative.open(),
              acquire: () {
                _initialAcquisitionUnsettled = true;
                owner = _initialOwner = native.acquireAppObjects();
                _initialAcquisitionUnsettled = false;
              },
              initializeP25: () => WindowsCredentialInitialization(
                      owner: owner, crypto: native.crypto)
                  .initialize()
                  .state,
              postAdmission: _requireLocal,
              close: () {
                _initialOwner?.close();
                _initialOwner = null;
              });
        } catch (_) {
          _phase = FirstPartyDevelopmentPhase.failed;
          rethrow;
        }
      });

  @override
  Future<void> start() => _run(() async {
        if (_phase != FirstPartyDevelopmentPhase.inactive ||
            startup != null ||
            relay.hasChild) {
          throw StateError('Development runtime requires normal App restart');
        }
        _phase = FirstPartyDevelopmentPhase.starting;
        _expiry =
            DateTime.now().toUtc().add(WindowsDevelopmentBootstrap.lifetime);
        _elapsed.start();
        final random = Random.secure();
        final acquirer = _acquirer = McpVnextWindowsProtectedAcquirer(
            utcNow: () => DateTime.now().toUtc(),
            monotonicNow: () => _elapsed.elapsed,
            compositionIsCurrent: () => _current,
            randomBytes: (count) => Uint8List.fromList(
                List<int>.generate(count, (_) => random.nextInt(256))));
        final candidate = startup = McpVnextWindowsAppStartup(
            integration: integration,
            enableStageApprovalWait: true,
            enableWithoutRetainedChannel: true,
            associationRecoveryAvailable: () =>
                _current &&
                !relay.hasChild &&
                relay.observation.phase == FirstPartyRelayPhase.listening,
            acquire: () async {
              _requireCurrent();
              return acquirer.acquireAppRuntime(
                  clock: const _DevelopmentClock(),
                  readiness: _DevelopmentReadiness(() => _current),
                  port: 48763,
                  process: relay);
            });
        try {
          await candidate.start();
          _requireCurrent();
          relay.businessBootstrap = () => _packet(pairingUi: false);
          relay.onDisconnected = integration.controls.disconnectTransport;
          _phase = FirstPartyDevelopmentPhase.active;
          _monitor = monitorWindowsDevelopmentLifetime(
              isCurrent: () => _current,
              isExpired: () =>
                  _expiry != null &&
                  (!DateTime.now().toUtc().isBefore(_expiry!) ||
                      _elapsed.elapsed >= WindowsDevelopmentBootstrap.lifetime),
              launchIsCurrent: () => relay.launchCurrent,
              stop: stopFor);
        } catch (_) {
          _phase = FirstPartyDevelopmentPhase.failed;
          await candidate.close();
          await acquirer.whenAcquisitionSettled;
          rethrow;
        }
      });

  WindowsDevelopmentBootstrap _packet({required bool pairingUi}) {
    _requireCurrent();
    if (!pairingUi) {
      final root = WindowsExternalNative.open().resolveLocalAppData().value;
      if (!File(p.join(root, 'Shiroha', 'external', 'bridge', 'client.bin'))
          .existsSync()) {
        throw StateError('Bridge Pin missing');
      }
    }
    final material = startup!.currentPublicMaterial();
    final server = material.serverLeafDer;
    if (server == null) throw StateError('App credentials unavailable');
    final digest = StreamingSha256()..update(server);
    final hex = digest.digestHex();
    return WindowsDevelopmentBootstrap(
        pairingUi: pairingUi,
        expiresAtUtcMs: _expiry!.millisecondsSinceEpoch,
        issuerDer: material.issuerCertificateDer,
        installationId: material.installationId,
        serverLeafDigest: List<int>.generate(
            32,
            (index) =>
                int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16)),
        epoch: material.publicationEpoch);
  }

  @override
  Future<void> openPairingWindow() => _run(() async {
        if (_phase != FirstPartyDevelopmentPhase.active) {
          throw StateError('Development runtime unavailable');
        }
        await relay.openPairing(_packet(pairingUi: true));
      });

  @override
  Future<void> waitPairingWindowClosed() => relay.waitPairingWindowClosed();

  @override
  Future<void> stop() => stopFor(FirstPartyDevelopmentStopCause.user);

  Future<void> stopFor(FirstPartyDevelopmentStopCause cause) {
    _closed = true;
    _monitor?.cancel();
    _stopObservation ??= FirstPartyDevelopmentStopObservation(
        cause, FirstPartyObservedResult.pending);
    return _closing ??= () async {
      try {
        await Future.wait([
          if (startup != null) startup!.close(),
          if (_work != null)
            _work!.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        ]);
        await _acquirer?.whenAcquisitionSettled;
        if (_initialOwner != null || _initialAcquisitionUnsettled) {
          throw StateError('Credential owner unsettled');
        }
        _phase = FirstPartyDevelopmentPhase.closed;
        _stopObservation = FirstPartyDevelopmentStopObservation(
            _stopObservation!.cause, FirstPartyObservedResult.returned);
      } catch (error) {
        _phase = FirstPartyDevelopmentPhase.failed;
        _stopObservation = FirstPartyDevelopmentStopObservation(
            _stopObservation!.cause,
            FirstPartyObservedResult.failed,
            DevelopmentCredentialInitialization._code(error));
        rethrow;
      }
    }();
  }
}

final class _DevelopmentClock implements ExternalClock {
  const _DevelopmentClock();
  @override
  DateTime now() => DateTime.now().toUtc();
}

/// This root is installed only after the normal App completed its database,
/// recovery and module composition. Each check retains that current App lifetime.
final class _DevelopmentReadiness implements LocalHostReadinessPort {
  const _DevelopmentReadiness(this._current);
  final bool Function() _current;
  @override
  bool get isCurrent => _current();
  void _check() {
    if (!isCurrent) throw StateError('App readiness unavailable');
  }

  @override
  Future<void> ensureDatabaseReady() async => _check();
  @override
  Future<void> ensureRecoveryComplete() async => _check();
  @override
  Future<void> ensureModulesAndRoutesReady() async => _check();
}
