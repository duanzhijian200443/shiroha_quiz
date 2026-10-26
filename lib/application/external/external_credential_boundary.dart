import 'dart:async';

import '../backup/backup_restore_gate.dart';
import 'external_authorization.dart';
import 'external_credential_association.dart';
import 'external_trust_coordinator.dart';
import 'external_trust_core.dart';

/// Expected verification inputs, not a verified result. No wire decoder/factory.
final class ExternalCredentialChallenge {
  ExternalCredentialChallenge._(
      this.profileId,
      this.installationId,
      this.generation,
      this.credentialIdentity,
      this.revision,
      this.expiresAt,
      this.runtimeInstance,
      this._expiresElapsed,
      [this.requestId]);
  final String profileId, installationId, credentialIdentity;
  final String? requestId;
  final int generation, revision;
  final DateTime expiresAt;
  final Duration _expiresElapsed;
  bool _expired = false;

  /// Expected private runtime binding, not a cryptographic wire nonce or proof.
  /// Future verification must bind the actual challenge/channel to this instance.
  final Object runtimeInstance;
  @override
  String toString() => 'ExternalCredentialChallenge(REDACTED)';
}

/// Injected only by trusted composition. Real implementations must verify
/// possession/chain/role/validity and exact challenge/event/channel binding.
/// These are distinct events. A caller's boolean/DTO/digest is not verification.
/// isLive must monotonically reject closed, revoked or invalid verification
/// events. All asynchronous crypto/TLS work stays outside P0's synchronous port.
abstract interface class ExternalCredentialVerificationPort {
  Future<bool> verifyPairing(
      ExternalCredentialChallenge challenge, Object attempt);
  Future<bool> verifyAuthentication(
      ExternalCredentialChallenge challenge, Object attempt);
  bool isLive(Object attempt);
}

/// Optional trusted verifier capability; ordinary authentication is not proof
/// for this separately approved, first-party existing-credential purpose.
abstract interface class ExternalExistingCredentialVerificationPort {
  Future<bool> verifyExistingCredential(
      ExternalCredentialChallenge challenge, Object event);
}

/// Private-constructor, one-use evidence owned by the original P15 boundary.
/// Transport retains the candidate until its original connection has settled.
final class ExternalExistingCredentialConfirmation {
  ExternalExistingCredentialConfirmation._(
      this._owner,
      this._reference,
      this._profile,
      this._challenge,
      this._event,
      this._snapshot,
      this._policyRevision);
  final ExternalCredentialBoundary _owner;
  final ExternalProfileReference _reference;
  final ExternalTrustProfile _profile;
  final ExternalCredentialChallenge _challenge;
  final Object _event;
  final ExternalCredentialAssociationSnapshot _snapshot;
  final int _policyRevision;
  bool _invalid = false, _claimed = false;
  String get profileId => _challenge.profileId;
  String get credentialIdentity => _challenge.credentialIdentity;
  String get installationId => _challenge.installationId;
  int get revision => _challenge.revision;
  DateTime get expiresAt => _challenge.expiresAt;
}

enum _CredentialUse { pairing, authentication, existingConfirmation }

/// One local request handle, never proof. P0 alone owns its pairing state.
final class ExternalCredentialRegistration {
  ExternalCredentialRegistration._(
      this._owner, this._reference, this._profile, this._challenge);
  final ExternalCredentialBoundary _owner;
  final ExternalProfileReference _reference;
  final ExternalTrustProfile _profile;
  final ExternalCredentialChallenge _challenge;
  bool _completed = false;

  /// Read-only local correlation, never verification evidence or wire authority.
  ExternalCredentialChallenge get challenge => _challenge;
}

/// Offline trusted seam. No default accepting verifier or production backend.
/// Accepted evidence is private, one-use and available only during a P12 call.
final class ExternalCredentialBoundary implements ExternalCredentialPort {
  ExternalCredentialBoundary.offline({
    required ExternalCredentialAssociationStore associations,
    required ExternalCredentialVerificationPort verification,
    required ExternalAuthorizationManagement management,
    required ExternalClock clock,
    required String installationId,
    required bool Function() compositionIsCurrent,
    Duration pairingRequestLifetime = evidenceLifetime,
    Duration Function()? monotonicNow,
  })  : _associations = associations,
        _verification = verification,
        _management = management,
        _clock = clock,
        _installationId = installationId,
        _isCurrent = compositionIsCurrent,
        _pairingRequestLifetime = pairingRequestLifetime,
        _elapsed = monotonicNow ?? _monotonicClock() {
    if (!ExternalAuthLimits.text(installationId, 128) ||
        pairingRequestLifetime <= Duration.zero ||
        pairingRequestLifetime > const Duration(seconds: 600)) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
  }

  static const evidenceLifetime = Duration(seconds: 30);
  static const maxPending = 16;
  static const maxVerifiedEvents = 1024;
  final ExternalCredentialAssociationStore _associations;
  final ExternalCredentialVerificationPort _verification;
  final ExternalAuthorizationManagement _management;
  final ExternalClock _clock;
  final String _installationId;
  final bool Function() _isCurrent;
  final Duration _pairingRequestLifetime;
  final Duration Function() _elapsed;
  final Object _runtimeInstance = Object();
  ExternalTrustCoordinator? _coordinator;
  ExternalTrustCore? _trust;
  int? _generation;
  bool _closed = false;
  int _pending = 0;
  Completer<void>? _idle;
  Future<void>? _shutdown;
  final _requests = <ExternalCredentialRegistration>{};
  final _events = Set<Object>.identity();
  final _windows = <_VerifiedAttempt>{};
  ExternalExistingCredentialConfirmation? _existing;
  bool _preparingExisting = false;
  int _existingSequence = 0;

  /// One trusted composition attachment; cannot replace this port's authority.
  void attach(ExternalTrustCoordinator coordinator, ExternalTrustCore trust) {
    if (_closed || _trust != null || !identical(trust.credentials, this)) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
    _coordinator = coordinator;
    _trust = trust;
    _generation = trust.generation;
  }

  /// Local liveness only, never proof or permission. Infrastructure events use
  /// this guard to observe shutdown, Restore and generation changes monotonically.
  bool get isCurrent {
    try {
      _check();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Read-only identity check for trusted lifecycle composition. No authority is
  /// created, attached or reopened by this check.
  bool usesComposition(
          ExternalTrustCoordinator coordinator,
          ExternalCredentialAssociationStore associations,
          ExternalCredentialVerificationPort verification,
          BigInt generation) =>
      identical(_coordinator, coordinator) &&
      identical(_associations, associations) &&
      identical(_verification, verification) &&
      _generation != null &&
      BigInt.from(_generation!) == generation;

  void _check([ExternalCredentialChallenge? challenge]) {
    BackupRestoreMutationGate.instance.ensureMutationAllowed();
    if (challenge != null &&
        (!_clock.now().isBefore(challenge.expiresAt) ||
            _elapsed() >= challenge._expiresElapsed)) {
      challenge._expired = true;
    }
    if (_closed ||
        !_isCurrent() ||
        _trust == null ||
        _generation != _trust!.generation ||
        (challenge != null &&
            (challenge._expired ||
                challenge.installationId != _installationId ||
                challenge.generation != _generation ||
                !identical(challenge.runtimeInstance, _runtimeInstance) ||
                !_clock.now().isBefore(challenge.expiresAt)))) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
  }

  Future<T> _track<T>(Future<T> Function() work) async {
    _check();
    if (_pending >= maxPending) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    if (_pending++ == 0) _idle = Completer<void>();
    try {
      final result = await work();
      _check();
      return result;
    } finally {
      if (--_pending == 0) {
        _idle!.complete();
        _idle = null;
      }
    }
  }

  Future<void> _profile(ExternalProfileReference reference,
      {bool allowRevoked = false}) async {
    final record = await _management.read(reference);
    if (record.profile.clientProfileId != reference.profileId ||
        (!allowRevoked && record.profile.revokedAtUtcMs != null) ||
        (record.grant != null &&
            record.grant!.profileId != reference.profileId)) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
  }

  Future<ExternalCredentialAssociationSnapshot> _read(String profileId) async {
    try {
      final snapshot = await _associations.read(profileId);
      _record(snapshot, profileId);
      return snapshot;
    } on ExternalCredentialException {
      rethrow;
    } catch (_) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    }
  }

  ExternalCredentialAssociation? _record(
      ExternalCredentialAssociationSnapshot snapshot, String profileId) {
    if (!snapshot.isCurrent) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
    final record = snapshot.record;
    if (record != null &&
        (record.profileId != profileId ||
            !ExternalAuthLimits.validId(record.profileId) ||
            !ExternalAuthLimits.text(record.installationId, 128) ||
            !ExternalAuthLimits.text(record.credentialIdentity, 256) ||
            record.revision < 1 ||
            record.revision > ExternalAuthLimits.maxRevision)) {
      credentialFail(ExternalCredentialFailure.dataCorrupt);
    }
    return record;
  }

  ExternalCredentialChallenge _challenge(
          String profileId, String identity, int revision,
          [String? requestId]) =>
      ExternalCredentialChallenge._(
          profileId,
          _installationId,
          _generation!,
          identity,
          revision,
          _clock.now().add(
              requestId == null ? evidenceLifetime : _pairingRequestLifetime),
          _runtimeInstance,
          _elapsed() +
              (requestId == null ? evidenceLifetime : _pairingRequestLifetime),
          requestId);

  Future<ExternalCredentialRegistration> requestPairing(
          ExternalProfileReference reference,
          {required String requestId,
          required String credentialIdentity,
          required int expectedRevision}) =>
      _track(() async {
        if (!ExternalAuthLimits.text(requestId, 128) ||
            !ExternalAuthLimits.text(credentialIdentity, 256) ||
            expectedRevision < 0) {
          credentialFail(ExternalCredentialFailure.invalidInput);
        }
        _requests
            .removeWhere((r) => !_clock.now().isBefore(r._challenge.expiresAt));
        if (_requests.length >= maxPending) {
          credentialFail(ExternalCredentialFailure.resourceLimit);
        }
        await _profile(reference);
        final snapshot = await _read(reference.profileId);
        _check();
        final old = _record(snapshot, reference.profileId);
        if ((old?.revision ?? 0) != expectedRevision) {
          credentialFail(ExternalCredentialFailure.staleRevision);
        }
        if (old != null &&
            !old.revoked &&
            (old.installationId != _installationId ||
                old.credentialIdentity != credentialIdentity)) {
          credentialFail(ExternalCredentialFailure.conflict);
        }
        final profile = await _coordinator!.registerProfile(reference);
        _trust!.snapshot(profile.principal);
        await _coordinator!.requestPairing(profile,
            requestId: requestId, credentialIdentity: credentialIdentity);
        _check();
        final request = ExternalCredentialRegistration._(
            this,
            reference,
            profile,
            _challenge(reference.profileId, credentialIdentity,
                expectedRevision, requestId));
        _requests.add(request);
        return request;
      });

  void _request(ExternalCredentialRegistration request) {
    _check(request._challenge);
    if (!identical(request._owner, this) || !_requests.contains(request)) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
  }

  Future<void> approvePairing(ExternalCredentialRegistration request) =>
      _track(() async {
        _request(request);
        await _coordinator!.approvePairing(request._profile);
        _request(request);
      });

  /// Local coordination guard; grants neither approval nor proof.
  Future<void> validatePairingRequest(ExternalCredentialRegistration request,
          {bool requireApproval = false}) =>
      _track(() async {
        _request(request);
        await _profile(request._reference);
        _request(request);
        if (requireApproval &&
            _trust!.snapshot(request._profile.principal).state !=
                PairingState.approvedPendingProof) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
      });

  void _live(ExternalCredentialChallenge challenge, Object event) {
    _check(challenge);
    if (!_verification.isLive(event)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
  }

  Future<void> _verify(ExternalCredentialChallenge challenge, Object event,
      {required _CredentialUse use}) async {
    _live(challenge, event);
    if (_events.contains(event)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    if (_events.length >= maxVerifiedEvents) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    bool verified;
    try {
      verified = switch (use) {
        _CredentialUse.pairing =>
          await _verification.verifyPairing(challenge, event),
        _CredentialUse.authentication =>
          await _verification.verifyAuthentication(challenge, event),
        _CredentialUse.existingConfirmation => _verification
                is ExternalExistingCredentialVerificationPort &&
            await (_verification as ExternalExistingCredentialVerificationPort)
                .verifyExistingCredential(challenge, event),
      };
    } catch (_) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    _live(challenge, event);
    // Recheck after awaits: two simultaneous uses cannot both claim an event.
    if (_events.length >= maxVerifiedEvents) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    if (!verified || !_events.add(event)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
  }

  Future<T> _window<T>(
      ExternalCredentialChallenge challenge,
      Object event,
      ExternalCredentialAssociationSnapshot snapshot,
      _CredentialUse use,
      Future<T> Function(Object) call) async {
    _live(challenge, event);
    final record = _record(snapshot, challenge.profileId);
    if (record == null ||
        record.revoked ||
        record.installationId != _installationId ||
        record.credentialIdentity != challenge.credentialIdentity) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
    final attempt = _VerifiedAttempt(challenge, event, snapshot, use);
    _windows.add(attempt);
    try {
      final result = await call(attempt);
      _live(challenge, event);
      _record(snapshot, challenge.profileId);
      return result;
    } finally {
      _windows.remove(attempt);
    }
  }

  Future<void> completePairing(
          ExternalCredentialRegistration request, Object proof) =>
      BackupRestoreMutationGate.instance.runMutation(() => _track(() async {
            _request(request);
            if (_trust!.snapshot(request._profile.principal).state !=
                PairingState.approvedPendingProof) {
              credentialFail(ExternalCredentialFailure.unauthorized);
            }
            _requests.remove(
                request); // Every completion attempt consumes its local challenge.
            final challenge = request._challenge;
            await _verify(challenge, proof, use: _CredentialUse.pairing);
            await _profile(request._reference);
            final snapshot = await _associations.register(
                profileId: challenge.profileId,
                installationId: _installationId,
                credentialIdentity: challenge.credentialIdentity,
                expectedRevision: challenge.revision,
                validateManagement: () async {
                  _live(challenge, proof);
                  await _profile(request._reference);
                  _live(challenge, proof);
                });
            // A committed record alone is not pairing. No cross-store atomicity.
            _live(challenge, proof);
            await _profile(request._reference);
            final record = _record(snapshot, challenge.profileId);
            if (record == null ||
                (record.revision != challenge.revision &&
                    record.revision != challenge.revision + 1)) {
              credentialFail(ExternalCredentialFailure.dataCorrupt);
            }
            await _window(
                challenge,
                proof,
                snapshot,
                _CredentialUse.pairing,
                (attempt) =>
                    _coordinator!.completePairing(request._profile, attempt));
            request._completed = true;
          }));

  /// Fresh persisted fact after acknowledged P0 completion. This is not an
  /// authorization token. A display must re-query it while visible.
  Future<ExternalCredentialAssociation> confirmedPairing(
          ExternalCredentialRegistration request) =>
      _track(() async {
        if (!identical(request._owner, this) || !request._completed) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        await _profile(request._reference);
        final snapshot = await _read(request._challenge.profileId);
        await _profile(request._reference);
        _check();
        final record = _record(snapshot, request._challenge.profileId);
        if (record == null ||
            record.revoked ||
            record.installationId != _installationId ||
            record.credentialIdentity !=
                request._challenge.credentialIdentity ||
            _trust!.snapshot(request._profile.principal).state !=
                PairingState.pairedDisabled) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        return record;
      });

  Future<ExternalSession> openSession(
          ExternalProfileReference reference, Object authentication) =>
      _track(() async {
        await _profile(reference);
        final profile = await _coordinator!.registerProfile(reference);
        _trust!.snapshot(profile.principal);
        final first = await _read(reference.profileId);
        final record = _record(first, reference.profileId);
        if (record == null ||
            record.revoked ||
            record.installationId != _installationId) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        final challenge = _challenge(
            reference.profileId, record.credentialIdentity, record.revision);
        await _verify(challenge, authentication,
            use: _CredentialUse.authentication);
        await _profile(reference);
        final current = await _read(reference.profileId);
        if (!first.isCurrent ||
            _record(current, reference.profileId)?.revision !=
                record.revision) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        return _window(
            challenge,
            authentication,
            current,
            _CredentialUse.authentication,
            (attempt) => _coordinator!.openSession(profile, attempt));
      });

  /// Preparation performs no P0 transition and no association write.
  Future<ExternalExistingCredentialConfirmation> prepareExistingConfirmation(
      ExternalProfileReference reference, Object event) async {
    _check();
    if (_preparingExisting || _existing != null) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    _preparingExisting = true;
    try {
      return await _track(() async {
        await _profile(reference);
        _check();
        final policy = await _management.read(reference);
        _check();
        final profile = await _coordinator!.registerProfile(reference);
        _check();
        if (_trust!.snapshot(profile.principal).state !=
            PairingState.unpaired) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        final snapshot = await _read(reference.profileId);
        _check();
        final record = _record(snapshot, reference.profileId);
        if (record == null ||
            record.revoked ||
            record.installationId != _installationId) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        final challenge = _challenge(
            reference.profileId, record.credentialIdentity, record.revision);
        // Correlation is local only. Its lifetime is always the original 30 s,
        // independently of the longer first-enrollment request window.
        final bound = ExternalCredentialChallenge._(
            challenge.profileId,
            challenge.installationId,
            challenge.generation,
            challenge.credentialIdentity,
            challenge.revision,
            challenge.expiresAt,
            challenge.runtimeInstance,
            challenge._expiresElapsed,
            'existing-${++_existingSequence}');
        await _verify(bound, event, use: _CredentialUse.existingConfirmation);
        final candidate = _existing = ExternalExistingCredentialConfirmation._(
            this,
            reference,
            profile,
            bound,
            event,
            snapshot,
            policy.profile.grantRevision);
        await validateExistingConfirmation(candidate);
        return candidate;
      });
    } catch (_) {
      final candidate = _existing;
      if (candidate != null && identical(candidate._event, event)) {
        cancelExistingConfirmation(candidate);
        _existing = null;
      }
      rethrow;
    } finally {
      _preparingExisting = false;
    }
  }

  void _existingCurrent(ExternalExistingCredentialConfirmation candidate) {
    if (!identical(candidate._owner, this) ||
        !identical(_existing, candidate) ||
        candidate._invalid) {
      credentialFail(ExternalCredentialFailure.unauthorized);
    }
    _live(candidate._challenge, candidate._event);
    _record(candidate._snapshot, candidate.profileId);
  }

  Future<void> validateExistingConfirmation(
          ExternalExistingCredentialConfirmation candidate) =>
      _track(() async {
        _existingCurrent(candidate);
        await _profile(candidate._reference);
        _existingCurrent(candidate);
        final policy = await _management.read(candidate._reference);
        _existingCurrent(candidate);
        if (policy.profile.grantRevision != candidate._policyRevision) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
        final current = await _read(candidate.profileId);
        _existingCurrent(candidate);
        final record = _record(current, candidate.profileId);
        if (record == null ||
            record.revoked ||
            record.installationId != candidate.installationId ||
            record.credentialIdentity != candidate.credentialIdentity ||
            record.revision != candidate.revision) {
          credentialFail(ExternalCredentialFailure.unauthorized);
        }
      });

  /// Explicit local confirmation only. No association register/CAS occurs here.
  Future<void> confirmExistingCredential(
          ExternalExistingCredentialConfirmation candidate) =>
      BackupRestoreMutationGate.instance.runMutation(() => _track(() async {
            _existingCurrent(candidate);
            if (candidate._claimed) {
              credentialFail(ExternalCredentialFailure.unauthorized);
            }
            candidate._claimed = true;
            await validateExistingConfirmation(candidate);
            _existingCurrent(candidate);
            await _coordinator!.requestPairing(candidate._profile,
                requestId: candidate._challenge.requestId!,
                credentialIdentity: candidate.credentialIdentity);
            await validateExistingConfirmation(candidate);
            await _coordinator!.approvePairing(candidate._profile);
            await validateExistingConfirmation(candidate);
            await _window(
                candidate._challenge,
                candidate._event,
                candidate._snapshot,
                _CredentialUse.existingConfirmation,
                (attempt) =>
                    _coordinator!.completePairing(candidate._profile, attempt));
            await validateExistingConfirmation(candidate);
          }));

  void cancelExistingConfirmation(
      ExternalExistingCredentialConfirmation? candidate) {
    if (candidate != null && identical(candidate._owner, this)) {
      candidate._invalid = true;
    }
  }

  /// Trusted Host calls this only after the original proof channel has settled.
  void releaseExistingConfirmation(
      ExternalExistingCredentialConfirmation? candidate) {
    cancelExistingConfirmation(candidate);
    if (identical(_existing, candidate)) _existing = null;
  }

  _VerifiedAttempt? _consume(Object attempt, _CredentialUse use) {
    if (attempt is! _VerifiedAttempt ||
        !_windows.contains(attempt) ||
        attempt.used ||
        attempt.use != use) {
      return null;
    }
    attempt.used = true;
    try {
      _live(attempt.challenge, attempt.event);
      _record(attempt.snapshot, attempt.challenge.profileId);
      return attempt;
    } catch (_) {
      return null;
    }
  }

  @override
  PairingProof? provePossession(Object proofAttempt) {
    final use = proofAttempt is _VerifiedAttempt &&
            proofAttempt.use == _CredentialUse.existingConfirmation
        ? _CredentialUse.existingConfirmation
        : _CredentialUse.pairing;
    final attempt = _consume(proofAttempt, use);
    return attempt == null
        ? null
        : PairingProof(
            attempt.challenge.requestId!, attempt.challenge.credentialIdentity);
  }

  @override
  AuthenticatedPeerEvidence? authenticate(Object authenticationAttempt) {
    final attempt =
        _consume(authenticationAttempt, _CredentialUse.authentication);
    return attempt == null
        ? null
        : AuthenticatedPeerEvidence(attempt.challenge.credentialIdentity);
  }

  /// Evidence closes immediately; P8 owning work and pending boundary work drain
  /// before P12 advances generation. No STAGE rollback or new receipt authority.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _closed = true;
    cancelExistingConfirmation(_existing);
    _windows.clear();
    _requests.clear();
    return _shutdown = Future.wait([
      _coordinator?.host.shutdown() ?? Future<void>.value(),
      _idle?.future ?? Future<void>.value(),
    ]).then((_) async {
      await _coordinator?.shutdown();
    });
  }

  /// Whole offline runtime closes, even if the durable revoke CAS fails.
  Future<void> revoke(
          ExternalProfileReference reference, int expectedRevision) =>
      BackupRestoreMutationGate.instance.runMutation(() async {
        _check();
        await _profile(reference, allowRevoked: true);
        _check();
        await shutdown();
        await _associations.revoke(
            profileId: reference.profileId,
            expectedRevision: expectedRevision,
            validateManagement: () => _profile(reference, allowRevoked: true));
      });
}

final class _VerifiedAttempt {
  _VerifiedAttempt(this.challenge, this.event, this.snapshot, this.use);
  final ExternalCredentialChallenge challenge;
  final Object event;
  final ExternalCredentialAssociationSnapshot snapshot;
  final _CredentialUse use;
  bool used = false;
}

Duration Function() _monotonicClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}
