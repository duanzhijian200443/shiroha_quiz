import 'dart:async';

import '../backup/backup_restore_gate.dart';
import '../generated_question/generated_local_authority.dart';
import 'external_authorization.dart';
import 'external_credential_association.dart';
import 'external_generated_stage.dart';
import 'external_trust_coordinator.dart';
import 'external_trust_core.dart';
import 'first_party_external_credentials.dart';
import 'first_party_development_access.dart';
import 'first_party_stage_approval.dart';
import 'local_authorization_service.dart';

/// Local relay custody observation, independent of business authentication.
enum FirstPartyRelayPhase {
  unavailable,
  listening,
  connected,
  settling,
  closed,
  unsettled
}

final class FirstPartyRelayObservation {
  const FirstPartyRelayObservation(this.phase);
  final FirstPartyRelayPhase phase;
}

/// Safe local UI state. Policy selection is never evidence of a connection.
final class FirstPartyExternalStatus {
  const FirstPartyExternalStatus(
      {this.relay =
          const FirstPartyRelayObservation(FirstPartyRelayPhase.unavailable),
      this.profileId,
      this.pairing,
      this.pairingAvailable = false,
      this.publicPairingAvailable = false,
      this.pairingDisplay,
      this.pairingFailed = false,
      this.connected = false,
      this.enabled = false,
      this.connectionPending = false,
      this.connectionSettling = false,
      this.connectionCancellationAvailable = false,
      this.connectionFailed = false,
      this.expiresAt,
      this.remainingSeconds,
      this.approvedTargets = 0});
  final FirstPartyRelayObservation relay;
  final String? profileId;
  final PairingState? pairing;
  final bool pairingAvailable, publicPairingAvailable, pairingFailed;
  final FirstPartyPairingDisplay? pairingDisplay;
  final bool connected, enabled;
  final bool connectionPending,
      connectionSettling,
      connectionCancellationAvailable;
  final bool connectionFailed;
  final DateTime? expiresAt;
  final int? remainingSeconds;
  final int approvedTargets;

  FirstPartyExternalStatus _withRelay(FirstPartyRelayObservation observation) =>
      FirstPartyExternalStatus(
          relay: observation,
          profileId: profileId,
          pairing: pairing,
          pairingAvailable: pairingAvailable,
          publicPairingAvailable: publicPairingAvailable,
          pairingDisplay: pairingDisplay,
          pairingFailed: pairingFailed,
          connected: connected,
          enabled: enabled,
          connectionPending: connectionPending,
          connectionSettling: connectionSettling,
          connectionCancellationAvailable: connectionCancellationAvailable,
          connectionFailed: connectionFailed,
          expiresAt: expiresAt,
          remainingSeconds: remainingSeconds,
          approvedTargets: approvedTargets);
}

/// Supplied only by trusted composition after transport/credential admission.
/// The attempt is opaque and reauthenticated for each local control operation.
/// This object implements no identity, policy, pairing or persistence authority.
final class FirstPartyExternalBinding {
  const FirstPartyExternalBinding(
      {required this.management,
      required this.coordinator,
      required this.trust,
      required this.stages,
      required this.localOwner,
      required this.authenticationAttempt,
      this.credentials,
      this.stageApproval,
      this.enableWithoutRetainedChannel = false,
      required this.publishApprovals,
      required this.shutdown});
  final ExternalAuthorizationManagement management;
  final ExternalTrustCoordinator coordinator;
  final ExternalTrustCore trust;
  final ExternalGeneratedStageService stages;
  final GeneratedLocalAuthoritySession localOwner;
  final Object? Function() authenticationAttempt;
  final FirstPartyCredentialServices? credentials;
  final FirstPartyStageApproval? stageApproval;
  final bool enableWithoutRetainedChannel;
  final void Function(List<ExternalStageContext>) publishApprovals;
  final Future<void> Function() shutdown;
}

/// One local view's exact original association snapshot; never authentication.
final class FirstPartyAssociationRecoveryDisplay {
  FirstPartyAssociationRecoveryDisplay._(
      this._owner,
      this._binding,
      this._reference,
      this._snapshot,
      this._policy,
      this._version,
      this._generation);
  final FirstPartyExternalAccess _owner;
  final FirstPartyExternalBinding _binding;
  final ExternalProfileReference _reference;
  final ExternalCredentialAssociationSnapshot _snapshot;
  final ExternalAuthorizationRecord _policy;
  final int _version, _generation;
  bool _consumed = false;
  String get profileId => _reference.profileId;
  String get profileName => _policy.profile.displayName;
  String get credentialIdentity => _snapshot.record!.credentialIdentity;
  String get installationId => _snapshot.record!.installationId;
  int get revision => _snapshot.record!.revision;
  bool get revoked => _snapshot.record!.revoked;
}

/// First-party control only; never registered as a Capability or MCP tool.
final class FirstPartyExternalAccess {
  FirstPartyExternalAccess(
      {required this.policy,
      required bool Function() compositionIsCurrent,
      FirstPartyRelayObservation Function()? observeRelay})
      : _isCurrent = compositionIsCurrent,
        _observeRelay = observeRelay;
  final LocalAuthorizationService policy;
  final bool Function() _isCurrent;
  final FirstPartyRelayObservation Function()? _observeRelay;
  FirstPartyDevelopmentAccess? _development;
  FirstPartyDevelopmentAccess? get development => _development;
  FirstPartyPairingObservation? _pairingObservation;
  FirstPartyPairingObservation? get pairingObservation => _pairingObservation;
  FirstPartyAssociationRevocationObservation? _revocationObservation;
  FirstPartyAssociationRevocationObservation? get revocationObservation =>
      _revocationObservation;
  FirstPartyAssociationRecoveryDisplay? _recoveryDisplay;
  int _recoveryVersion = 0;
  bool _revocationDispatched = false;
  bool get associationRecoveryAvailable =>
      isCurrent &&
      !_revocationDispatched &&
      _binding?.credentials?.associationRecovery != null;

  Future<T> _observePairing<T>(
      FirstPartyAppPairingPhase phase, Future<T> Function() action) async {
    _pairingObservation = FirstPartyPairingObservation(phase,
        FirstPartyObservedResult.pending, _pairingObservation?.firstFailure);
    try {
      final result = await action();
      _pairingObservation = FirstPartyPairingObservation(phase,
          FirstPartyObservedResult.returned, _pairingObservation?.firstFailure);
      return result;
    } catch (error) {
      _pairingObservation = FirstPartyPairingObservation(
          phase,
          FirstPartyObservedResult.failed,
          _pairingObservation?.firstFailure ??
              FirstPartyAppPairingFailure(
                  phase, FirstPartyApplicationFailure.from(error)));
      rethrow;
    }
  }

  void cancelAssociationRecovery() {
    _recoveryVersion++;
    _recoveryDisplay = null;
  }

  FirstPartyAssociationRecoveryPort _recoveryPort(
      FirstPartyExternalBinding binding, int version) {
    _validate();
    final port = binding.credentials?.associationRecovery;
    if (!identical(binding, _binding) ||
        version != _recoveryVersion ||
        _revocationDispatched ||
        !binding.enableWithoutRetainedChannel ||
        port == null ||
        !port.isCurrent ||
        _development == null ||
        _profile == null ||
        _selectedId == null ||
        _pairingRequest != null ||
        _pairingFailed ||
        _session != null ||
        _enabling ||
        binding.credentials?.existingCredential?.display() != null ||
        binding.trust.snapshot(_profile!.principal).state !=
            PairingState.unpaired) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return port;
  }

  Future<void> _recoveryDevelopment(
      FirstPartyExternalBinding binding, int version) async {
    _recoveryPort(binding, version);
    final status = await _development!.status();
    _recoveryPort(binding, version);
    // Metadata is only an additional refusal condition. The later original
    // Bridge Native path alone establishes kind-4 Missing before initial save.
    if (status.phase != FirstPartyDevelopmentPhase.active ||
        status.pairingWindowOpen ||
        status.bridgePinMissing != true) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  bool _sameRecoveryPolicy(ExternalAuthorizationRecord first,
          ExternalAuthorizationRecord current) =>
      current.profile.clientProfileId == first.profile.clientProfileId &&
      current.profile.revokedAtUtcMs == null &&
      current.profile.grantRevision == first.profile.grantRevision &&
      current.grant?.profileId == first.grant?.profileId &&
      current.grant?.revision == first.grant?.revision &&
      current.grant?.revokedAtUtcMs == first.grant?.revokedAtUtcMs;

  Future<FirstPartyAssociationRecoveryDisplay>
      inspectAssociationForRevocation() => _run(() async {
            cancelAssociationRecovery();
            final binding = _binding;
            if (binding == null) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            final version = _recoveryVersion, selected = _selectedId;
            final port = _recoveryPort(binding, version);
            await _recoveryDevelopment(binding, version);
            final reference = await binding.management.selectProfile(selected!);
            _recoveryPort(binding, version);
            final policy = await binding.management.read(reference);
            _recoveryPort(binding, version);
            if (selected != _selectedId ||
                policy.profile.revokedAtUtcMs != null) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            final snapshot = await port.read(reference);
            _recoveryPort(binding, version);
            final current = await binding.management.read(reference);
            _recoveryPort(binding, version);
            final record = snapshot.record;
            if (selected != _selectedId ||
                !_sameRecoveryPolicy(policy, current) ||
                !snapshot.isCurrent ||
                record == null ||
                record.profileId != selected ||
                record.installationId != port.installationId) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            return _recoveryDisplay = FirstPartyAssociationRecoveryDisplay._(
                this,
                binding,
                reference,
                snapshot,
                policy,
                version,
                binding.trust.generation);
          });

  void _checkRecoveryDisplay(FirstPartyAssociationRecoveryDisplay display) {
    _recoveryPort(display._binding, display._version);
    if (!identical(display._owner, this) ||
        !identical(display, _recoveryDisplay) ||
        display.profileId != _selectedId ||
        display._generation != display._binding.trust.generation ||
        !display._snapshot.isCurrent ||
        display.revoked) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  Future<void> confirmAssociationRevocation(
      FirstPartyAssociationRecoveryDisplay display) async {
    _validate();
    if (_busy || display._consumed || !identical(display._owner, this)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    display._consumed = true;
    Object? failure;
    StackTrace? failureStack;
    var dispatched = false;
    _busy = true;
    final idle = _idle = Completer<void>();
    try {
      _checkRecoveryDisplay(display);
      final binding = display._binding;
      await _recoveryDevelopment(binding, display._version);
      _checkRecoveryDisplay(display);
      final policy = await binding.management.read(display._reference);
      _checkRecoveryDisplay(display);
      if (!_sameRecoveryPolicy(display._policy, policy)) {
        externalAuthFail(ExternalAuthFailure.staleRevision);
      }
      final port = binding.credentials!.associationRecovery!;
      final snapshot = await port.read(display._reference);
      _checkRecoveryDisplay(display);
      final record = snapshot.record;
      if (!snapshot.isCurrent ||
          record == null ||
          record.revoked ||
          record.profileId != display.profileId ||
          record.revision != display.revision ||
          record.installationId != display.installationId ||
          record.credentialIdentity != display.credentialIdentity) {
        externalAuthFail(ExternalAuthFailure.staleRevision);
      }
      final current = await binding.management.read(display._reference);
      _checkRecoveryDisplay(display);
      if (!_sameRecoveryPolicy(display._policy, current) ||
          !snapshot.isCurrent) {
        externalAuthFail(ExternalAuthFailure.staleRevision);
      }
      _revocationDispatched = dispatched = true;
      _revocationObservation = const FirstPartyAssociationRevocationObservation(
          revoke: FirstPartyObservedResult.pending);
      await port.revoke(display._reference, display.revision);
      // Terminal operation: Host shutdown intentionally invalidates this runtime.
      // Unlike ordinary _run, no old-runtime post-validation belongs here.
      _revocationObservation = const FirstPartyAssociationRevocationObservation(
          revoke: FirstPartyObservedResult.returned);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      if (dispatched) {
        _revocationObservation = FirstPartyAssociationRevocationObservation(
            revoke: FirstPartyObservedResult.failed,
            failure: FirstPartyApplicationFailure.from(error));
      }
    } finally {
      cancelAssociationRecovery();
      _busy = false;
      idle.complete();
      _idle = null;
    }
    if (dispatched) {
      final original = _revocationObservation!;
      _revocationObservation = FirstPartyAssociationRevocationObservation(
          revoke: original.revoke,
          failure: original.failure,
          close: FirstPartyObservedResult.pending);
      try {
        // Outside the busy/idle region: stop may join controls.shutdown/_idle.
        await _development!.stop();
        _revocationObservation = FirstPartyAssociationRevocationObservation(
            revoke: original.revoke,
            failure: original.failure,
            close: FirstPartyObservedResult.returned);
      } catch (error, stack) {
        _revocationObservation = FirstPartyAssociationRevocationObservation(
            revoke: original.revoke,
            failure: original.failure,
            close: FirstPartyObservedResult.failed,
            closeFailure: FirstPartyApplicationFailure.from(error));
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  bool get requestScopedStageApproval =>
      _binding?.enableWithoutRetainedChannel == true;
  FirstPartyExistingCredentialDisplay? get existingCredentialDisplay =>
      isCurrent ? _binding?.credentials?.existingCredential?.display() : null;

  Future<void> beginExistingCredentialConfirmation() => _run(() async {
        cancelAssociationRecovery();
        final version = _identityControlVersion;
        final b = _binding;
        final profile = _profile;
        final port = b?.credentials?.existingCredential;
        if (b == null ||
            profile == null ||
            port == null ||
            _pairingFailed ||
            b.trust.snapshot(profile.principal).state !=
                PairingState.unpaired) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        final reference = await b.management.selectProfile(_selectedId!);
        await b.management.read(reference);
        _validate();
        if (!identical(profile, _profile) ||
            version != _identityControlVersion) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        port.begin(reference);
      });

  Future<void> confirmExistingCredential(
          FirstPartyExistingCredentialDisplay display) =>
      _run(() async {
        final port = _binding?.credentials?.existingCredential;
        if (port == null || display.profileId != _selectedId) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        await port.confirm(display);
        await _development?.waitPairingWindowClosed();
      });

  Future<void> cancelExistingCredentialConfirmation() async {
    _identityControlVersion++;
    final port = _binding?.credentials?.existingCredential;
    final pending = port?.display() != null;
    await port?.cancel();
    if (pending) await _development?.waitPairingWindowClosed();
  }

  void installDevelopment(FirstPartyDevelopmentAccess development) {
    if (_closed || _development != null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _development = development;
  }

  /// Original outer adapter loss invalidates old Enable/approval immediately.
  /// This is not Host shutdown and never reauthenticates or replays work.
  Future<void> disconnectTransport() async {
    cancelAssociationRecovery();
    if (_closed) return;
    _configuredVersion++;
    _enableCancelled = true;
    _forgetAccess();
    _binding?.credentials?.cancelPendingConnection?.call();
    await Future.wait([
      cancelExistingCredentialConfirmation(),
      _idle?.future ?? Future<void>.value(),
      _configuredWork?.catchError((Object _) {}) ?? Future<void>.value(),
    ]);
  }

  FirstPartyExternalBinding? _binding;
  ExternalTrustProfile? _profile;
  String? _selectedId;
  ExternalSession? _session;
  FirstPartyCredentialConnection? _connection;
  FirstPartyPairingRequest? _pairingRequest;
  bool _pairingFailed = false, _requestingPairing = false;
  Future<void>? _cancellingPairing;
  int? _sessionRevision;
  int _accessVersion = 0;
  int _identityControlVersion = 0;
  final _approvals = <ExternalStageContext>[];
  List<GeneratedReviewTargetChoice> _choices = const [];
  bool _closed = false, _busy = false;
  bool _enabling = false, _enableCancelled = false, _connectionFailed = false;
  DateTime? _enableExpiresAt;
  Completer<void>? _idle;
  Future<void>? _shutdown, _disabling;
  int _configuredVersion = 0;
  String? _configuredProfile;
  Future<void>? _configuredWork;
  bool get isCurrent =>
      !_closed &&
      _isCurrent() &&
      policy.isCurrent &&
      !BackupRestoreMutationGate.instance.isMaintenance;

  void _validate() {
    if (!isCurrent) externalAuthFail(ExternalAuthFailure.unauthorized);
  }

  /// No startup call installs this. UI cannot supply authentication evidence.
  void installTrusted(FirstPartyExternalBinding binding) {
    _validate();
    if (_binding != null || _busy) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (binding.credentials != null &&
        !identical(binding.trust.credentials, binding.credentials!.boundary)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _selectedId = null;
    _binding = binding;
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _validate();
    if (_busy) externalAuthFail(ExternalAuthFailure.unauthorized);
    _busy = true;
    _idle = Completer<void>();
    try {
      final result = await action();
      _validate();
      return result;
    } finally {
      _busy = false;
      _idle!.complete();
      _idle = null;
    }
  }

  Future<ExternalProfilePage> profiles({String? afterId}) => _run(() async {
        final view = policy.openView();
        try {
          return await view.profiles(afterId: afterId);
        } finally {
          view.close();
        }
      });

  /// Prepares the existing owners for a first-party connection wizard. Identity
  /// confirmation and finite Enable remain separate explicit user decisions.
  Future<void> prepareExistingConnection(String profileId,
      {required bool Function() available}) async {
    final development = _development;
    if (!isCurrent || !available() || development == null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    var state = await development.status();
    if (!isCurrent || !available()) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (state.phase == FirstPartyDevelopmentPhase.inactive) {
      await development.start();
      if (!isCurrent || !available()) {
        externalAuthFail(ExternalAuthFailure.unauthorized);
      }
      state = await development.status();
    }
    if (!isCurrent ||
        !available() ||
        state.phase != FirstPartyDevelopmentPhase.active ||
        state.bridgePinMissing != false) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (_selectedId != profileId || _profile == null) await _select(profileId);
    final current = await status();
    if (!isCurrent || !available() || current.profileId != profileId) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (current.pairing == PairingState.unpaired) {
      await beginExistingCredentialConfirmation();
      try {
        if (!isCurrent || !available() || _selectedId != profileId) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        await development.openPairingWindow();
      } catch (_) {
        await cancelExistingCredentialConfirmation();
        rethrow;
      }
    }
  }

  /// One explicit local access decision. Reuses fresh live credential proof;
  /// no credential, Pin, Session or successful result is reconstructed by UI.
  Future<void> allowConfiguredAccess(String? profileId,
      {required bool Function() available,
      Future<void>? pendingStatus,
      Future<String?> Function(
              bool Function() current, Future<void> Function() withdraw)?
          prepare}) {
    _validate();
    if (_configuredWork != null) {
      if (_configuredProfile != profileId || prepare != null) {
        externalAuthFail(ExternalAuthFailure.unauthorized);
      }
      return _configuredWork!;
    }
    final token = ++_configuredVersion;
    final done = Completer<void>();
    _configuredProfile = profileId;
    FirstPartyExternalBinding? originalBinding;
    ExternalTrustProfile? originalProfile;
    bool current() =>
        isCurrent &&
        available() &&
        token == _configuredVersion &&
        identical(_configuredWork, done.future) &&
        (originalBinding == null || identical(originalBinding, _binding)) &&
        (originalProfile == null || identical(originalProfile, _profile));
    void check() {
      if (!current()) externalAuthFail(ExternalAuthFailure.unauthorized);
    }

    // The independent operation slot cannot use _run: each original owner
    // below already uses that serialization boundary.
    _configuredWork = done.future;
    unawaited(() async {
      try {
        check();
        // Own the user action before its first status/policy await. Preparation
        // may withdraw old access without cancelling or joining its own slot.
        await pendingStatus;
        check();
        final selectedProfile = prepare == null
            ? profileId
            : await prepare(current, () async {
                check();
                await _disable();
                check();
              });
        check();
        if (selectedProfile == null) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        _configuredProfile = selectedProfile;
        final before = await status();
        check();
        if (before.profileId == selectedProfile && before.enabled) return;
        await prepareExistingConnection(selectedProfile, available: current);
        check();
        originalBinding = _binding;
        originalProfile = _profile;
        final prepared = await status();
        check();
        if (prepared.pairing == PairingState.unpaired) {
          final elapsed = Stopwatch()..start();
          while (true) {
            check();
            final display = existingCredentialDisplay;
            if (display == null ||
                display.profileId != selectedProfile ||
                display.settling ||
                display.remainingSeconds <= 0 ||
                elapsed.elapsed >= const Duration(seconds: 30)) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            if (display.credentialIdentity != null &&
                display.installationId != null &&
                display.revision != null) {
              // No await between obtaining and consuming the exact candidate.
              await confirmExistingCredential(display);
              check();
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        final deployment = await _development!.status();
        check();
        await enable(deployment.maxAccessDuration);
        check();
      } catch (error, stack) {
        _forgetAccess();
        _binding?.credentials?.cancelPendingConnection?.call();
        try {
          await cancelExistingCredentialConfirmation();
        } catch (closeError, closeStack) {
          done.completeError(closeError, closeStack);
          return;
        }
        done.completeError(error, stack);
        return;
      } finally {
        _configuredProfile = null;
        _configuredWork = null;
        if (!done.isCompleted) done.complete();
      }
    }());
    return done.future;
  }

  void _forgetAccess() {
    _accessVersion++;
    _binding?.stageApproval?.cancel();
    final b = _binding;
    if (b != null &&
        _profile != null &&
        b.trust.snapshot(_profile!.principal).state ==
            PairingState.enabledForCurrentRuntime) {
      b.trust.disable(_profile!.principal);
    }
    _session = null;
    _connection = null;
    _sessionRevision = null;
    _choices = const [];
    _approvals.clear();
    _binding?.publishApprovals(const []);
  }

  Future<void> select(String profileId) async {
    if (_configuredWork != null) await disable();
    await _select(profileId);
  }

  Future<void> _select(String profileId) => _run(() async {
        cancelAssociationRecovery();
        final b = _binding;
        await cancelExistingCredentialConfirmation();
        _forgetAccess();
        _profile = null;
        _selectedId = null;
        _connectionFailed = false;
        _pairingRequest = null;
        if (b == null) {
          final view = policy.openView();
          try {
            await view.read(await view.select(profileId));
          } finally {
            view.close();
          }
        } else {
          final ref = await b.management.selectProfile(profileId);
          final selected = await b.coordinator.registerProfile(ref);
          _validate();
          _profile = selected;
        }
        _validate();
        _selectedId = profileId;
      });

  FirstPartyCredentialServices _credentials() {
    final services = _binding?.credentials;
    if (services == null || _profile == null || !services.boundary.isCurrent) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return services;
  }

  Future<void> requestPairing({String? submissionId}) => _observePairing(
      FirstPartyAppPairingPhase.request,
      () => _run(() async {
            cancelAssociationRecovery();
            final services = _credentials();
            final b = _binding!;
            if (_pairingFailed ||
                b.trust.snapshot(_profile!.principal).state !=
                    PairingState.unpaired) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            _requestingPairing = true;
            try {
              final ref = await b.management.selectProfile(_selectedId!);
              final port = services.pairing;
              if (submissionId != null) {
                if (port is! FirstPartyPublicPairingPort) {
                  externalAuthFail(ExternalAuthFailure.unauthorized);
                }
                _pairingRequest =
                    await port.requestSubmission(ref, submissionId);
              } else {
                _pairingRequest = await port.request(ref);
              }
              _validate();
              if (_pairingFailed) {
                externalAuthFail(ExternalAuthFailure.unauthorized);
              }
            } catch (_) {
              _pairingFailed = true;
              rethrow;
            } finally {
              _requestingPairing = false;
            }
          }));

  Future<String> exportPairingTrust() => _exportPairing(false);
  Future<String> exportPairingCompletion() => _exportPairing(true);

  Future<String> _exportPairing(bool completion) => _observePairing(
      completion
          ? FirstPartyAppPairingPhase.exportCompletion
          : FirstPartyAppPairingPhase.exportTrust,
      () => _run(() async {
            final port = _credentials().pairing;
            if (port is! FirstPartyPublicPairingPort ||
                _pairingRequest == null ||
                _pairingFailed) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            try {
              return completion
                  ? await port.exportPublicCompletion()
                  : await port.exportPublicTrust();
            } catch (_) {
              _pairingFailed = true;
              rethrow;
            }
          }));

  Future<void> cancelPairing() {
    if (_cancellingPairing != null) return _cancellingPairing!;
    _validate();
    final pairing = _credentials().pairing;
    _pairingFailed = true;
    _forgetAccess();
    // P27 close drains the original runtime; it is not a P0 cancel/reset.
    return _cancellingPairing = Future.wait([
      pairing.close(),
      _idle?.future ?? Future<void>.value(),
    ]);
  }

  Future<void> cancelPendingControls() async {
    cancelAssociationRecovery();
    if (_configuredWork != null) {
      await disable();
      return;
    }
    if (!isCurrent) return;
    final identityClosing = cancelExistingCredentialConfirmation();
    if (_enabling) {
      // Withdraw the pending decision synchronously, before joining any drain.
      final accessClosing =
          _binding?.credentials?.cancelPendingConnection != null
              ? disable()
              : shutdown();
      await Future.wait([identityClosing, accessClosing]);
      return;
    }
    await identityClosing;
    final state = _profile == null
        ? null
        : _binding?.trust.snapshot(_profile!.principal).state;
    if (_requestingPairing ||
        state == PairingState.requestPending ||
        state == PairingState.approvedPendingProof) {
      await cancelPairing();
    }
  }

  Future<void> _pairingAction(bool complete) => _observePairing(
      complete
          ? FirstPartyAppPairingPhase.complete
          : FirstPartyAppPairingPhase.approve,
      () => _run(() async {
            _credentials();
            final request = _pairingRequest;
            final expected = complete
                ? PairingState.approvedPendingProof
                : PairingState.requestPending;
            if (request == null ||
                _pairingFailed ||
                _binding!.trust.snapshot(_profile!.principal).state !=
                    expected) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            try {
              if (complete) {
                await request.complete();
              } else {
                await request.approve();
              }
            } catch (_) {
              // Preserve P0's actual pending state. Failed/unknown completion has no
              // automatic retry, reset, success projection or enablement.
              _pairingFailed = true;
              _forgetAccess();
              rethrow;
            }
          }));

  Future<void> approvePairing() => _pairingAction(false);
  Future<void> completePairing() => _pairingAction(true);

  Object _authenticate(FirstPartyExternalBinding b) {
    _validate();
    final attempt = b.authenticationAttempt();
    if (attempt == null || _profile == null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    final peer = b.trust.authenticate(attempt);
    if (!identical(peer.principal, _profile!.principal) ||
        peer.generation != b.trust.generation) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return attempt;
  }

  Future<FirstPartyExternalStatus> status() async {
    final business = await _businessStatus();
    var observation =
        const FirstPartyRelayObservation(FirstPartyRelayPhase.unavailable);
    try {
      observation = _observeRelay?.call() ?? observation;
    } catch (_) {/* Observation cannot change business authority. */}
    return business._withRelay(observation);
  }

  Future<FirstPartyExternalStatus> _businessStatus() async {
    if (!_enabling) return _readStatus();
    _validate();
    final b = _binding!;
    try {
      final record = await b.management
          .read(await b.management.selectProfile(_selectedId!));
      _validate();
      if (record.profile.revokedAtUtcMs != null ||
          record.grant == null ||
          record.grant!.revokedAtUtcMs != null) {
        _expireEnable();
      }
    } catch (_) {
      _expireEnable();
    }
    _validate();
    if (!_enabling) return _readStatus();
    final expiry = _enableExpiresAt;
    if (expiry != null && !b.trust.clock.now().isBefore(expiry)) {
      _expireEnable();
    }
    // Observation neither authenticates nor publishes an unsettled Session.
    return FirstPartyExternalStatus(
        profileId: _selectedId,
        pairing: b.trust.snapshot(_profile!.principal).state,
        pairingAvailable: b.credentials?.boundary.isCurrent == true,
        connectionPending: !_enableCancelled,
        connectionSettling: _enableCancelled,
        connectionCancellationAvailable:
            b.credentials?.cancelPendingConnection != null,
        connectionFailed: _connectionFailed,
        expiresAt: expiry,
        remainingSeconds: _remaining(expiry));
  }

  int? _remaining(DateTime? expiry) {
    if (expiry == null) return null;
    final milliseconds =
        expiry.difference(_binding!.trust.clock.now()).inMilliseconds;
    return milliseconds <= 0 ? 0 : (milliseconds + 999) ~/ 1000;
  }

  Future<FirstPartyExternalStatus> _readStatus() => _run(() async {
        final b = _binding;
        if (b == null || _profile == null) {
          return FirstPartyExternalStatus(profileId: _selectedId);
        }
        try {
          final ref = await b.management.selectProfile(_selectedId!);
          final record = await b.management.read(ref);
          if (record.profile.revokedAtUtcMs != null ||
              record.grant == null ||
              record.grant!.revokedAtUtcMs != null ||
              (_sessionRevision != null &&
                  record.grant!.revision != _sessionRevision)) {
            _forgetAccess();
            if (record.profile.revokedAtUtcMs != null ||
                b.credentials == null) {
              return FirstPartyExternalStatus(
                  profileId: _selectedId,
                  pairing: b.trust.snapshot(_profile!.principal).state);
            }
          }
          if (b.credentials != null) {
            final services = _credentials();
            var snapshot = b.trust.snapshot(_profile!.principal);
            FirstPartyPairingDisplay? display;
            if (_pairingRequest != null &&
                !_pairingFailed &&
                snapshot.state != PairingState.enabledForCurrentRuntime) {
              try {
                display = await _observePairing(
                    FirstPartyAppPairingPhase.display,
                    () => _pairingRequest!.display());
              } catch (_) {
                _pairingFailed = true;
              }
            }
            // A request owns its own independently authenticated S. Do not
            // substitute the UI's auxiliary connection or disable that live
            // request because the auxiliary connection has already closed.
            final requestConnected =
                b.stageApproval?.hasLiveRequestFor(_selectedId) == true;
            final session =
                requestConnected ? null : await authenticatedSession();
            snapshot = b.trust.snapshot(_profile!.principal);
            return FirstPartyExternalStatus(
                profileId: _selectedId,
                pairing: snapshot.state,
                pairingAvailable: services.boundary.isCurrent,
                publicPairingAvailable:
                    services.pairing is FirstPartyPublicPairingPort,
                pairingDisplay: _pairingFailed ? null : display,
                pairingFailed: _pairingFailed,
                connectionFailed: _connectionFailed,
                connected: requestConnected || session != null,
                enabled: requestConnected ||
                    session != null ||
                    (b.enableWithoutRetainedChannel &&
                        _sessionRevision != null &&
                        snapshot.state ==
                            PairingState.enabledForCurrentRuntime),
                expiresAt: snapshot.expiresAt,
                remainingSeconds: _remaining(snapshot.expiresAt),
                approvedTargets: _approvals.length);
          }
          _authenticate(b);
          final snapshot = b.trust.snapshot(_profile!.principal);
          if (_session?.failure != null) _forgetAccess();
          return FirstPartyExternalStatus(
              profileId: _selectedId,
              pairing: snapshot.state,
              connected: true,
              enabled: _session != null,
              expiresAt: snapshot.expiresAt,
              remainingSeconds: _remaining(snapshot.expiresAt),
              approvedTargets: _approvals.length);
        } catch (_) {
          _forgetAccess();
          return FirstPartyExternalStatus(
              profileId: _selectedId,
              pairingFailed: _pairingFailed,
              connectionFailed: _connectionFailed);
        }
      });

  Future<void> enable(Duration duration) => _run(() async {
        final b = _binding;
        if (b == null) externalAuthFail(ExternalAuthFailure.unauthorized);
        // Preflight belongs to this same cancellable operation: a disconnect or
        // departing view during status I/O must not be reset by its continuation.
        _forgetAccess();
        _enabling = true;
        _enableCancelled = false;
        _connectionFailed = false;
        Timer? deadline;
        try {
          final services = b.credentials;
          if (services != null) _credentials();
          if (_pairingFailed) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          final attempt = services == null ? _authenticate(b) : null;
          // One visible access deadline must never outlive the admitted deployment.
          // Generic/offline callers retain their original P0 duration limit.
          DateTime? deploymentDeadline;
          if (b.enableWithoutRetainedChannel && _development != null) {
            final deployment = await _development!.status();
            _validateEnable();
            final expiresAt = deployment.expiresAt;
            if (deployment.phase != FirstPartyDevelopmentPhase.active ||
                expiresAt == null ||
                duration <= Duration.zero ||
                duration > deployment.maxAccessDuration ||
                !b.trust.clock.now().isBefore(expiresAt)) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            deploymentDeadline = expiresAt;
          }
          _validateEnable();
          await b.coordinator
              .enable(_profile!, duration, notAfter: deploymentDeadline);
          _validateEnable();
          final snapshot = b.trust.snapshot(_profile!.principal);
          final expiry = snapshot.expiresAt;
          final now = b.trust.clock.now();
          if (snapshot.state != PairingState.enabledForCurrentRuntime ||
              expiry == null ||
              !now.isBefore(expiry)) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          _enableExpiresAt = expiry;
          deadline = Timer(expiry.difference(now), _expireEnable);
          if (b.enableWithoutRetainedChannel) {
            if (services == null) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            final reference = await b.management.selectProfile(_selectedId!);
            _validateEnable();
            final record = await b.management.read(reference);
            _validateEnable();
            if (record.profile.revokedAtUtcMs != null ||
                record.grant == null ||
                record.grant!.revokedAtUtcMs != null ||
                b.trust.snapshot(_profile!.principal).state !=
                    PairingState.enabledForCurrentRuntime) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
            // Enable is finite local policy. Each request must independently
            // authenticate through P15; no Session is manufactured or retained.
            _sessionRevision = record.grant!.revision;
            return;
          }
          FirstPartyCredentialConnection? connection;
          if (services != null) {
            final reference = await b.management.selectProfile(_selectedId!);
            _validateEnable();
            connection = await services.openConnection(reference);
            _validateEnable();
          }
          final session = connection?.session ??
              await b.coordinator.openSession(_profile!, attempt!);
          if (!identical(session.principal, _profile!.principal) ||
              session.generation != b.trust.generation ||
              (connection != null &&
                  !identical(await connection.authenticate(), session))) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          final access = await b.stages.runtimeAdmission.admit(session);
          if (access.grantSnapshot == null ||
              access.grantSnapshot!.revokedAtUtcMs != null) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          if (services == null) _authenticate(b);
          if (connection != null &&
              !identical(await connection.authenticate(), session)) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          _validateEnable();
          if (session.failure != null) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          _session = session;
          _connection = connection;
          _sessionRevision = access.grantSnapshot?.revision;
        } catch (_) {
          // Failed authentication/admission must never leave a hidden enablement.
          _connectionFailed = _connectionFailed || !_enableCancelled;
          _forgetAccess();
          rethrow;
        } finally {
          deadline?.cancel();
          _enableExpiresAt = null;
          _enabling = false;
        }
      });

  void _expireEnable() {
    if (!_enabling || _enableCancelled || _closed) return;
    _enableCancelled = true;
    _connectionFailed = true;
    _forgetAccess();
    _binding?.credentials?.cancelPendingConnection?.call();
  }

  void _validateEnable() {
    _validate();
    if (_enableCancelled) externalAuthFail(ExternalAuthFailure.unauthorized);
  }

  Future<void> disable() {
    if (_configuredWork case final pending?) {
      _configuredVersion++;
      _enableCancelled = true;
      _forgetAccess();
      _binding?.credentials?.cancelPendingConnection?.call();
      return Future.wait<void>([
        cancelExistingCredentialConfirmation(),
        pending.catchError((Object _) {}),
      ]);
    }
    return _disable();
  }

  Future<void> _disable() {
    if (_busy) {
      _validate();
      if (_disabling != null) return _disabling!;
      _enableCancelled = true;
      _forgetAccess(); // deny immediately; cancellation alone is not settlement
      _binding?.credentials?.cancelPendingConnection?.call();
      final idle = _idle!.future;
      return _disabling = idle.whenComplete(() => _disabling = null);
    }
    return _run(() async {
      _forgetAccess();
      final b = _binding;
      if (b != null &&
          _profile != null &&
          b.trust.snapshot(_profile!.principal).state ==
              PairingState.pairedDisabled) {
        await b.coordinator.disable(_profile!);
      }
    });
  }

  /// Refusal-only preflight before the App-owned raw Bridge can be created.
  /// A live deployment or saved Pin is not completed business Enablement.
  /// P15 authentication and current policy checks still run on every channel.
  void requireBusinessEnablement() {
    _validate();
    _credentials();
    final b = _binding;
    final profile = _profile;
    if (b == null ||
        !b.enableWithoutRetainedChannel ||
        profile == null ||
        _selectedId != profile.principal.profileId ||
        _sessionRevision == null ||
        _enabling ||
        _configuredWork != null ||
        b.trust.snapshot(profile.principal).state !=
            PairingState.enabledForCurrentRuntime) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  /// Trusted port rechecks the current Session and owning policy at every call.
  /// App-owned channels call this after verified association lookup, before P15.
  Future<void Function()> admitBusinessConnection(
      ExternalProfileReference reference, int observedRevision) async {
    final b = _binding;
    final profile = _profile;
    final version = _accessVersion;
    final revision = _sessionRevision;
    void current() {
      _validate();
      if (b == null ||
          !b.enableWithoutRetainedChannel ||
          profile == null ||
          !identical(b, _binding) ||
          !identical(profile, _profile) ||
          version != _accessVersion ||
          revision == null ||
          revision != _sessionRevision ||
          revision != observedRevision ||
          reference.profileId != _selectedId ||
          reference.profileId != profile.principal.profileId ||
          b.trust.snapshot(profile.principal).state !=
              PairingState.enabledForCurrentRuntime) {
        externalAuthFail(ExternalAuthFailure.unauthorized);
      }
    }

    try {
      current();
      final record = await b!.management.read(reference);
      current();
      if (record.profile.revokedAtUtcMs != null ||
          record.profile.grantRevision != revision ||
          record.grant == null ||
          record.grant!.revokedAtUtcMs != null ||
          record.grant!.revision != revision) {
        externalAuthFail(ExternalAuthFailure.unauthorized);
      }
      return current;
    } catch (_) {
      // A stale channel cannot withdraw a newer explicit user enablement.
      if (version == _accessVersion && reference.profileId == _selectedId) {
        _forgetAccess();
      }
      rethrow;
    }
  }

  Future<ExternalSession?> authenticatedSession() async {
    try {
      _validate();
      final b = _binding!;
      if (b.enableWithoutRetainedChannel && _session == null) {
        _credentials();
        final reference = await b.management.selectProfile(_selectedId!);
        final record = await b.management.read(reference);
        _validate();
        if (record.profile.revokedAtUtcMs != null ||
            record.grant == null ||
            record.grant!.revokedAtUtcMs != null ||
            record.grant!.revision != _sessionRevision ||
            b.trust.snapshot(_profile!.principal).state !=
                PairingState.enabledForCurrentRuntime) {
          _forgetAccess();
        }
        return null;
      }
      if (b.credentials == null) {
        _authenticate(b);
      } else {
        _credentials();
        final connection = _connection;
        if (connection == null ||
            !identical(await connection.authenticate(), _session)) {
          _forgetAccess();
          return null;
        }
      }
      final session = _session;
      if (session == null || session.failure != null) return null;
      final access = await b.stages.runtimeAdmission.admit(session);
      if (access.grantSnapshot == null ||
          access.grantSnapshot!.revokedAtUtcMs != null ||
          access.grantSnapshot!.revision != _sessionRevision) {
        _forgetAccess();
        return null;
      }
      _validate();
      if (!identical(session, _session)) return null;
      if (b.credentials == null) {
        _authenticate(b);
      } else if (!identical(await _connection?.authenticate(), session)) {
        _forgetAccess();
        return null;
      }
      _validate();
      if (!identical(session, _session) || session.failure != null) return null;
      return session;
    } catch (_) {
      _forgetAccess();
      return null;
    }
  }

  Future<List<GeneratedReviewTargetChoice>> targets() => _run(() async {
        final session = await authenticatedSession();
        if (session == null) externalAuthFail(ExternalAuthFailure.unauthorized);
        final choices = await _binding!.localOwner.targets();
        _validate();
        _choices = List.unmodifiable(choices);
        return _choices;
      });

  FirstPartyStageApprovalView? openStageApprovalView() {
    _validate();
    final approval = _binding?.stageApproval;
    return approval?.host.isReady == true ? approval!.openView() : null;
  }

  /// Only the local confirmation of a displayed App choice invokes P3 approval.
  /// READ Contexts and client-supplied target names never enter this method.
  Future<void> approveTarget(GeneratedReviewTargetChoice choice) =>
      _run(() async {
        final session = await authenticatedSession();
        if (session == null || !_choices.any((c) => identical(c, choice))) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        final approved = await _binding!.stages
            .approveTarget(session, choice.target, const []);
        _validate();
        if (!identical(session, _session) ||
            await authenticatedSession() == null) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        _approvals.removeWhere((a) =>
            a.target.bankName == choice.target.bankName &&
            a.target.projectId == choice.target.projectId &&
            a.target.folderName == choice.target.folderName);
        if (_approvals.length >= 128) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        _approvals.add(approved);
        _binding!.publishApprovals(List.unmodifiable(_approvals));
      });

  /// Blocks synchronously, then awaits local work and owning Host/port drain.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    cancelAssociationRecovery();
    _configuredVersion++;
    _closed = true;
    _forgetAccess();
    final proofClosing = cancelExistingCredentialConfirmation();
    final owning = _binding?.shutdown() ?? Future<void>.value();
    return _shutdown = Future.wait([
      owning,
      proofClosing,
      _idle?.future ?? Future<void>.value(),
      _configuredWork?.catchError((Object _) {}) ?? Future<void>.value(),
    ]);
  }
}
