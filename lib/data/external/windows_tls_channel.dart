part of 'windows_tls_transport.dart';

/// P27 Pairing remains delegated; only this adapter owns TLS channel attempts.
/// Injected Native policy is a trusted infrastructure seam, never a boolean
/// provided by a caller/request. No public accepted-evidence constructor exists.
final class WindowsChannelVerification
    implements ExternalCredentialVerificationPort {
  WindowsChannelVerification(
      {required this.pairing,
      required this.associations,
      required this.management,
      required this.nativePolicy,
      required this.verifyDigest,
      required this.utcNow,
      required this.monotonicNow,
      required bool Function() compositionIsCurrent})
      : _current = compositionIsCurrent;
  final ExternalCredentialVerificationPort pairing;
  final ExternalCredentialIdentityLookup associations;
  final ExternalAuthorizationManagement management;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
  final CredentialDigestVerifier verifyDigest;
  final DateTime Function() utcNow;
  final Duration Function() monotonicNow;
  final bool Function() _current;
  ExternalCredentialBoundary? _boundary;
  final _attempts = <_ChannelAttempt>{};
  final _channels = Set<TlsChannel>.identity();
  bool _closed = false;

  void attach(ExternalCredentialBoundary boundary) {
    if (_boundary != null || _closed) _tlsReject();
    _boundary = boundary;
  }

  bool get _available => !_closed && _current() && _boundary?.isCurrent == true;

  Future<WindowsTlsSession> authenticate(
      TlsChannel channel, TlsContextPlan plan) async {
    if (!_available ||
        !channel.isOpen ||
        plan.role != TlsPeerRole.server ||
        !plan.isCurrent ||
        _channels.length >= 8 ||
        !_channels.add(channel)) {
      _tlsReject();
    }
    _ChannelAttempt? attempt;
    try {
      final der = channel.peerDer;
      if (der.isEmpty || der.length > 16384) _tlsReject();
      nativePolicy(der, TlsPeerRole.client);
      final cert = _verifyPeer(
          der, plan.anchorDer, TlsPeerRole.client, utcNow(), verifyDigest);
      final identity = _tlsIdentity(der);
      final snapshot = await associations.findCredential(identity);
      final record = snapshot.record;
      if (!_available ||
          !channel.isOpen ||
          !snapshot.isCurrent ||
          record == null ||
          record.revoked ||
          record.credentialIdentity != identity) {
        _tlsReject();
      }
      // The protected inverse query selects the opaque local reference. Nothing
      // from CN, display strings, P9 or JSON participates in this selection.
      final reference = await management.selectProfile(record.profileId);
      final policy = await management.read(reference);
      if (policy.profile.revokedAtUtcMs != null) _tlsReject();
      attempt = _ChannelAttempt(this, channel, snapshot, reference,
          policy.profile.grantRevision, cert.notAfter, monotonicNow());
      _attempts.add(attempt);
      final session = await _boundary!.openSession(reference, attempt);
      attempt.session = session;
      if (!isLive(attempt)) _tlsReject();
      return WindowsTlsSession._(this, attempt, session);
    } catch (_) {
      if (attempt != null) {
        attempt.invalid = true;
        _attempts.remove(attempt);
      }
      _channels.remove(channel);
      rethrow;
    }
  }

  @override
  Future<bool> verifyPairing(
          ExternalCredentialChallenge challenge, Object attempt) =>
      pairing.verifyPairing(challenge, attempt);

  @override
  Future<bool> verifyAuthentication(
      ExternalCredentialChallenge challenge, Object event) async {
    if (event is! _ChannelAttempt ||
        !identical(event.owner, this) ||
        event.used ||
        !isLive(event)) {
      return false;
    }
    event.used = true;
    final record = event.snapshot.record!;
    if (challenge.requestId != null ||
        challenge.profileId != event.reference.profileId ||
        challenge.installationId != record.installationId ||
        challenge.credentialIdentity != record.credentialIdentity ||
        challenge.revision != record.revision) {
      event.invalid = true;
      return false;
    }
    event.runtimeInstance = challenge.runtimeInstance;
    event.generation = challenge.generation;
    final policy = await management.read(event.reference);
    if (policy.profile.grantRevision != event.policyRevision ||
        policy.profile.revokedAtUtcMs != null) {
      event.invalid = true;
    }
    return isLive(event);
  }

  @override
  bool isLive(Object event) {
    if (event is! _ChannelAttempt) return !_closed && pairing.isLive(event);
    if (!identical(event.owner, this) || !_attempts.contains(event)) {
      return false;
    }
    try {
      if (!_available ||
          !event.channel.isOpen ||
          !event.snapshot.isCurrent ||
          !utcNow().isBefore(event.expiresAt) ||
          // P15's verification window is bounded, but a successfully admitted
          // Session can continue on THIS channel under per-call current checks.
          (event.session == null &&
              monotonicNow() - event.created >=
                  ExternalCredentialBoundary.evidenceLifetime) ||
          (event.session != null &&
              (event.session!.failure != null ||
                  event.session!.generation != event.generation))) {
        event.invalid = true;
      }
    } catch (_) {
      event.invalid = true;
    }
    return !event.invalid;
  }

  Future<void> _refresh(_ChannelAttempt attempt) async {
    if (!isLive(attempt)) _tlsReject();
    final record = await management.read(attempt.reference);
    if (record.profile.grantRevision != attempt.policyRevision ||
        record.profile.revokedAtUtcMs != null) {
      attempt.invalid = true;
    }
    if (!isLive(attempt)) _tlsReject();
  }

  void invalidateChannel(TlsChannel channel) {
    for (final attempt
        in _attempts.where((a) => identical(a.channel, channel)).toList()) {
      attempt.invalid = true;
      _attempts.remove(attempt);
    }
    _channels.remove(channel);
  }

  void close() {
    _closed = true;
    for (final event in _attempts) {
      event.invalid = true;
    }
  }
}

final class _ChannelAttempt {
  _ChannelAttempt(this.owner, this.channel, this.snapshot, this.reference,
      this.policyRevision, this.expiresAt, this.created);
  final WindowsChannelVerification owner;
  final TlsChannel channel;
  final ExternalCredentialAssociationSnapshot snapshot;
  final ExternalProfileReference reference;
  final int policyRevision;
  final DateTime expiresAt;
  final Duration created;
  bool invalid = false, used = false;
  Object? runtimeInstance;
  int? generation;
  ExternalSession? session;
}

/// A bounded live channel binding, NOT a second Session registry or authority.
/// P0 owns the Session and P8/P7 recheck it before every parse/dispatch/release.
final class WindowsTlsSession implements OfflineIpcAuthenticationPort {
  WindowsTlsSession._(this._owner, this._event, this.session);
  final WindowsChannelVerification _owner;
  final _ChannelAttempt _event;
  final ExternalSession session;
  bool get isLive => _owner.isLive(_event);
  @override
  Future<ExternalSession?> authenticate() async {
    try {
      await _owner._refresh(_event);
      return isLive ? session : null;
    } catch (_) {
      _event.invalid = true;
      return null;
    }
  }
}

ExternalCertificateStructure _verifyPeer(Uint8List der, Uint8List anchorDer,
    TlsPeerRole role, DateTime now, CredentialDigestVerifier verify) {
  final issuer = ExternalCertificateDer.inspect(anchorDer,
      role: ExternalCertificateRole.issuer);
  final peer = ExternalCertificateDer.inspect(der,
      role: role == TlsPeerRole.server
          ? ExternalCertificateRole.server
          : ExternalCertificateRole.client);
  for (final cert in [issuer, peer]) {
    if (now.isBefore(cert.notBefore) || !now.isBefore(cert.notAfter)) {
      _tlsReject();
    }
    verify(
        publicPoint: issuer.publicKey,
        digest: _tlsHash(cert.tbs),
        rawSignature: cert.rawSignature);
  }
  if (peer.notBefore.isBefore(issuer.notBefore) ||
      peer.notAfter.isAfter(issuer.notAfter)) {
    _tlsReject();
  }
  return peer;
}
