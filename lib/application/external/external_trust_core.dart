/// Pure memory candidate. No credential implementation or production Host.
library;

enum PairingState {
  unpaired,
  requestPending,
  approvedPendingProof,
  pairedDisabled,
  enabledForCurrentRuntime,
  revoked,
  recoveryRequired,
}

enum ExternalFailure {
  invalidState,
  pairingConflict,
  authenticationRejected,
  unpaired,
  disabled,
  expired,
  revoked,
  recoveryRequired,
  staleGeneration,
  protocolVersion,
  installationMismatch,
  notReady,
  accessDenied,
  staleContext,
  cancelled,
  deadlineExceeded,
  responseLost,
  reconciliationRequired,
  resourceLimit,
  invalidRequest,
  handlerFailed,
}

final class ExternalCoreException implements Exception {
  const ExternalCoreException(this.failure);
  final ExternalFailure failure;
  @override
  String toString() => 'ExternalCoreException(${failure.name})';
}

abstract interface class ExternalClock {
  DateTime now();
}

/// Only a trusted authentication adapter supplies this, never a wire decoder.
/// This candidate does not prove TLS, SID or upstream process identity.
final class AuthenticatedPeerEvidence {
  const AuthenticatedPeerEvidence(this.credentialIdentity);
  final String credentialIdentity;
}

final class PairingProof {
  const PairingProof(this.requestId, this.credentialIdentity);
  final String requestId;
  final String credentialIdentity;
}

abstract interface class ExternalCredentialPort {
  AuthenticatedPeerEvidence? authenticate(Object authenticationAttempt);
  PairingProof? provePossession(Object proofAttempt);
}

/// App-minted object identity; equal display identifiers do not confer trust.
final class ExternalPrincipal {
  ExternalPrincipal._(this.profileId);
  final String profileId;
}

final class ExternalProfileSnapshot {
  const ExternalProfileSnapshot(this.state, this.disableReason, this.expiresAt);
  final PairingState state;
  final ExternalFailure? disableReason;
  final DateTime? expiresAt;
}

final class _Profile {
  _Profile(this.principal);
  final ExternalPrincipal principal;
  PairingState state = PairingState.unpaired;
  String? requestId;
  String? credential;
  DateTime? expiresAt;
  ExternalFailure? disableReason;
  int enableEpoch = 0;
}

/// Opaque authenticated mapping, bound to this authority and its generation.
final class ExternalPeer {
  ExternalPeer._(this._owner, this.principal, this.generation);
  final ExternalTrustCore _owner;
  final ExternalPrincipal principal;
  final int generation;
}

/// Minted only after current runtime admission. Not a business permission.
final class ExternalSession {
  ExternalSession._(this._peer, this._enableEpoch);
  final ExternalPeer _peer;
  final int _enableEpoch;
  ExternalPrincipal get principal => _peer.principal;
  int get generation => _peer.generation;
  ExternalFailure? get failure => _peer._owner.sessionFailure(this);
}

final class ExternalTrustCore {
  ExternalTrustCore({
    required this.credentials,
    required this.clock,
    required this.mintProfileId,
    this.maxProfiles = 16,
    this.maxEnableDuration = const Duration(minutes: 30),
  }) {
    if (maxProfiles < 1 || maxEnableDuration <= Duration.zero) {
      throw ArgumentError('Invalid candidate limits');
    }
  }

  final ExternalCredentialPort credentials;
  final ExternalClock clock;
  final String Function() mintProfileId;
  // Candidate limits, not measured production thresholds.
  final int maxProfiles;
  final Duration maxEnableDuration;
  final Map<String, _Profile> _profiles = {};
  int _generation = 1;
  int get generation => _generation;

  ExternalPrincipal createProfile() {
    if (_profiles.length >= maxProfiles) {
      throw const ExternalCoreException(ExternalFailure.resourceLimit);
    }
    final id = mintProfileId();
    if (id.isEmpty || id.length > 128 || _profiles.containsKey(id)) {
      throw const ExternalCoreException(ExternalFailure.pairingConflict);
    }
    final principal = ExternalPrincipal._(id);
    _profiles[id] = _Profile(principal);
    return principal;
  }

  _Profile _profile(ExternalPrincipal principal) {
    final profile = _profiles[principal.profileId];
    if (profile == null || !identical(profile.principal, principal)) {
      throw const ExternalCoreException(ExternalFailure.authenticationRejected);
    }
    return profile;
  }

  ExternalProfileSnapshot snapshot(ExternalPrincipal principal) {
    final profile = _profile(principal);
    _refresh(profile);
    return ExternalProfileSnapshot(
        profile.state, profile.disableReason, profile.expiresAt);
  }

  /// Called by trusted local pairing UI, not an external RPC event.
  void requestPairing(ExternalPrincipal principal,
      {required String requestId, required String credentialIdentity}) {
    final profile = _profile(principal);
    if (requestId.isEmpty ||
        requestId.length > 128 ||
        credentialIdentity.isEmpty ||
        credentialIdentity.length > 256) {
      throw const ExternalCoreException(ExternalFailure.invalidRequest);
    }
    if (profile.requestId == requestId &&
        profile.credential == credentialIdentity &&
        profile.state != PairingState.revoked &&
        profile.state != PairingState.recoveryRequired) {
      return;
    }
    if ((profile.state != PairingState.unpaired &&
            profile.state != PairingState.recoveryRequired) ||
        _profiles.values.any((p) =>
            p.credential == credentialIdentity || p.requestId == requestId)) {
      throw const ExternalCoreException(ExternalFailure.pairingConflict);
    }
    profile.requestId = requestId;
    profile.credential = credentialIdentity;
    profile.state = PairingState.requestPending;
  }

  void approvePairing(ExternalPrincipal principal) {
    final profile = _profile(principal);
    if (profile.state != PairingState.requestPending) {
      throw const ExternalCoreException(ExternalFailure.invalidState);
    }
    profile.state = PairingState.approvedPendingProof;
  }

  void completePairing(ExternalPrincipal principal, Object proofAttempt) {
    final profile = _profile(principal);
    if (profile.state != PairingState.approvedPendingProof) {
      throw const ExternalCoreException(ExternalFailure.invalidState);
    }
    PairingProof? proof;
    try {
      proof = credentials.provePossession(proofAttempt);
    } catch (_) {
      throw const ExternalCoreException(ExternalFailure.authenticationRejected);
    }
    if (proof == null ||
        proof.requestId != profile.requestId ||
        proof.credentialIdentity != profile.credential) {
      throw const ExternalCoreException(ExternalFailure.authenticationRejected);
    }
    profile.state = PairingState.pairedDisabled;
  }

  /// Trusted explicit local action; never adds capabilities, scope or grants.
  void enable(ExternalPrincipal principal, Duration duration) {
    final profile = _profile(principal);
    _refresh(profile);
    if (profile.state != PairingState.pairedDisabled) {
      throw ExternalCoreException(_stateFailure(profile));
    }
    if (duration <= Duration.zero || duration > maxEnableDuration) {
      throw const ExternalCoreException(ExternalFailure.invalidRequest);
    }
    profile.enableEpoch++;
    profile.expiresAt = clock.now().add(duration);
    profile.disableReason = null;
    profile.state = PairingState.enabledForCurrentRuntime;
  }

  void disable(ExternalPrincipal principal) {
    final profile = _profile(principal);
    if (profile.state != PairingState.enabledForCurrentRuntime &&
        profile.state != PairingState.pairedDisabled) {
      throw const ExternalCoreException(ExternalFailure.invalidState);
    }
    _disable(profile, ExternalFailure.disabled);
  }

  void revoke(ExternalPrincipal principal) {
    final profile = _profile(principal);
    _disable(profile, ExternalFailure.revoked);
    profile.state = PairingState.revoked;
  }

  void restart() {
    _generation++;
    for (final profile in _profiles.values) {
      if (profile.state == PairingState.enabledForCurrentRuntime) {
        _disable(profile, ExternalFailure.staleGeneration);
      }
    }
  }

  void restore() {
    _generation++;
    for (final profile in _profiles.values) {
      _disable(profile, ExternalFailure.recoveryRequired);
      profile.state = PairingState.recoveryRequired;
    }
  }

  ExternalPeer authenticate(Object authenticationAttempt) {
    AuthenticatedPeerEvidence? evidence;
    try {
      evidence = credentials.authenticate(authenticationAttempt);
    } catch (_) {
      throw const ExternalCoreException(ExternalFailure.authenticationRejected);
    }
    if (evidence != null) {
      for (final profile in _profiles.values) {
        if (profile.credential == evidence.credentialIdentity) {
          if (profile.state == PairingState.revoked ||
              profile.state == PairingState.recoveryRequired ||
              profile.state == PairingState.unpaired ||
              profile.state == PairingState.requestPending ||
              profile.state == PairingState.approvedPendingProof) {
            throw ExternalCoreException(_stateFailure(profile));
          }
          return ExternalPeer._(this, profile.principal, _generation);
        }
      }
    }
    throw const ExternalCoreException(ExternalFailure.authenticationRejected);
  }

  ExternalSession openSession(ExternalPeer peer) {
    if (!identical(peer._owner, this)) {
      throw const ExternalCoreException(ExternalFailure.authenticationRejected);
    }
    if (peer.generation != _generation) {
      throw const ExternalCoreException(ExternalFailure.staleGeneration);
    }
    final profile = _profile(peer.principal);
    _refresh(profile);
    if (profile.state != PairingState.enabledForCurrentRuntime) {
      throw ExternalCoreException(_stateFailure(profile));
    }
    return ExternalSession._(peer, profile.enableEpoch);
  }

  ExternalFailure? sessionFailure(ExternalSession session) {
    final peer = session._peer;
    if (!identical(peer._owner, this)) {
      return ExternalFailure.authenticationRejected;
    }
    if (peer.generation != _generation) return ExternalFailure.staleGeneration;
    final profile = _profile(peer.principal);
    _refresh(profile);
    if (profile.state != PairingState.enabledForCurrentRuntime) {
      return _stateFailure(profile);
    }
    if (profile.enableEpoch != session._enableEpoch) {
      return ExternalFailure.disabled;
    }
    return null;
  }

  void _refresh(_Profile profile) {
    if (profile.state == PairingState.enabledForCurrentRuntime &&
        !clock.now().isBefore(profile.expiresAt!)) {
      _disable(profile, ExternalFailure.expired);
    }
  }

  void _disable(_Profile profile, ExternalFailure reason) {
    profile.enableEpoch++;
    profile.expiresAt = null;
    profile.disableReason = reason;
    if (profile.state == PairingState.enabledForCurrentRuntime) {
      profile.state = PairingState.pairedDisabled;
    }
  }

  ExternalFailure _stateFailure(_Profile profile) => switch (profile.state) {
        PairingState.revoked => ExternalFailure.revoked,
        PairingState.recoveryRequired => ExternalFailure.recoveryRequired,
        PairingState.pairedDisabled =>
          profile.disableReason ?? ExternalFailure.disabled,
        PairingState.enabledForCurrentRuntime => ExternalFailure.invalidState,
        _ => ExternalFailure.unpaired,
      };
}
