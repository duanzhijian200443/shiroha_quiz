part of 'windows_tls_transport.dart';

/// P27 Pairing remains delegated; only this adapter owns TLS channel attempts.
/// Injected Native policy is a trusted infrastructure seam, never a boolean
/// provided by a caller/request. No public accepted-evidence constructor exists.
final class WindowsChannelVerification
    implements
        ExternalCredentialVerificationPort,
        ExternalExistingCredentialVerificationPort {
  WindowsChannelVerification(
      {required this.pairing,
      required this.associations,
      required this.management,
      required this.nativePolicy,
      required this.verifyDigest,
      required this.utcNow,
      required this.monotonicNow,
      this.admitBusinessConnection,
      required bool Function() compositionIsCurrent})
      : _current = compositionIsCurrent;
  final ExternalCredentialVerificationPort pairing;
  final ExternalCredentialIdentityLookup associations;
  final ExternalAuthorizationManagement management;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
  final CredentialDigestVerifier verifyDigest;
  final DateTime Function() utcNow;
  final Duration Function() monotonicNow;
  final Future<void Function()> Function(ExternalProfileReference, int)?
      admitBusinessConnection;
  final bool Function() _current;
  ExternalCredentialBoundary? _boundary;
  final _attempts = <_ChannelAttempt>{};
  final _channels = Set<TlsChannel>.identity();
  final _seenChannels = Set<TlsChannel>.identity();
  bool _closed = false;
  Completer<FirstPartyCredentialConnection>? _localOpening;
  ExternalProfileReference? _localProfile;
  _ExistingChannelConfirmation? _existing;
  bool _existingCleanupFailed = false;
  late final FirstPartyExistingCredentialPort existingCredential =
      _ExistingCredentialControl(this);
  bool get hasPendingLocalConnection => _localOpening != null;

  /// Acquires the server's original authenticated Session. The Bridge opens
  /// the socket; this local action neither borrows its client key nor invents
  /// another channel. Normal P9 deadlines and per-call policy remain in force.
  Future<FirstPartyCredentialConnection> openLocalConnection(
      ExternalProfileReference profile) async {
    if (!_available || _localOpening != null) _tlsReject();
    final opening = _localOpening = Completer<FirstPartyCredentialConnection>();
    // Close can interrupt the independent management read before it settles.
    unawaited(
        opening.future.then((_) {}, onError: (Object _, StackTrace __) {}));
    _localProfile = profile;
    try {
      await management.read(profile); // reject foreign/stale local references
      if (!_available) _tlsReject();
      for (final attempt in _attempts) {
        _offerLocal(attempt);
        if (opening.isCompleted) break;
      }
      final connection = await opening.future;
      if (!_available ||
          !identical(await connection.authenticate(), connection.session)) {
        _tlsReject();
      }
      return connection;
    } finally {
      if (identical(_localOpening, opening)) {
        _localOpening = null;
        _localProfile = null;
      }
    }
  }

  void _offerLocal(_ChannelAttempt attempt) {
    final opening = _localOpening;
    final session = attempt.session;
    if (opening != null &&
        !opening.isCompleted &&
        session != null &&
        attempt.reference.profileId == _localProfile?.profileId &&
        isLive(attempt)) {
      opening.complete(
          WindowsTlsSession._(this, attempt, session).firstPartyConnection);
    }
  }

  void attach(ExternalCredentialBoundary boundary) {
    if (_boundary != null || _closed) _tlsReject();
    _boundary = boundary;
  }

  bool get _available => !_closed && _current() && _boundary?.isCurrent == true;

  Future<WindowsTlsSession> authenticate(
          TlsChannel channel, TlsContextPlan plan) async =>
      (await _authenticate(channel, plan))!;

  Future<WindowsTlsSession?> authenticateForHost(
          TlsChannel channel, TlsContextPlan plan,
          {required Future<void> Function() connectionDone,
          required Future<void> Function() close,
          required bool Function() clean}) =>
      _authenticate(channel, plan,
          connectionDone: connectionDone, close: close, clean: clean);

  Future<WindowsTlsSession?> _authenticate(
      TlsChannel channel, TlsContextPlan plan,
      {Future<void> Function()? connectionDone,
      Future<void> Function()? close,
      bool Function()? clean}) async {
    if (!_available ||
        !channel.isOpen ||
        plan.role != TlsPeerRole.server ||
        !plan.isCurrent ||
        _channels.length >= 8 ||
        _seenChannels.length >= ExternalCredentialBoundary.maxVerifiedEvents ||
        !_seenChannels.add(channel) ||
        !_channels.add(channel)) {
      _tlsReject();
    }
    final confirmation =
        connectionDone != null && _existing?.channel == null ? _existing : null;
    if (confirmation != null) {
      confirmation.channel = channel;
      confirmation.close = close;
      confirmation.observer = () async {
        try {
          await channel
              .read(1); // EOF or any byte withdraws this proof-only channel.
        } catch (_) {/* Fixed refusal; never decode business input. */}
        _cancelExisting(confirmation);
      }();
      confirmation.settled = () async {
        await connectionDone!();
        if (!clean!()) {
          _existingCleanupFailed = true;
          _tlsReject();
        }
        _boundary!.releaseExistingConfirmation(confirmation.candidate);
        confirmation.timer.cancel();
        if (identical(_existing, confirmation)) _existing = null;
      }();
      unawaited(confirmation.settled!
          .then((_) {}, onError: (Object _, StackTrace __) {}));
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
      attempt.existingConfirmation = confirmation != null;
      _attempts.add(attempt);
      if (confirmation != null) {
        if (confirmation.cancelled ||
            reference.profileId != confirmation.reference.profileId) {
          _tlsReject();
        }
        confirmation.work = () async {
          final candidate = await _boundary!
              .prepareExistingConfirmation(confirmation.reference, attempt!);
          confirmation.candidate = candidate;
          if (confirmation.cancelled) {
            _boundary!.cancelExistingConfirmation(candidate);
            _tlsReject();
          }
          confirmation.display = FirstPartyExistingCredentialDisplay(
              profileId: candidate.profileId,
              credentialIdentity: candidate.credentialIdentity,
              installationId: candidate.installationId,
              revision: candidate.revision,
              remainingSeconds: confirmation.remaining(monotonicNow()));
          confirmation.poll = Timer.periodic(const Duration(seconds: 1), (_) {
            if (confirmation.cancelled ||
                confirmation.claimed ||
                confirmation.polling) {
              return;
            }
            confirmation.polling = true;
            final previous = confirmation.work;
            final checking = confirmation.work = () async {
              await previous;
              await _boundary!.validateExistingConfirmation(candidate);
            }();
            unawaited(checking.then((_) {
              confirmation.polling = false;
            }, onError: (Object _, StackTrace __) {
              confirmation.polling = false;
              _cancelExisting(confirmation);
            }));
          });
        }();
        await confirmation.work;
        await confirmation.decision.future;
        await confirmation.work;
        return null;
      }
      attempt.businessCurrent = await admitBusinessConnection?.call(
          reference, policy.profile.grantRevision);
      if (!isLive(attempt)) _tlsReject();
      final session = await _boundary!.openSession(reference, attempt);
      attempt.session = session;
      if (admitBusinessConnection != null) await _refresh(attempt);
      if (!isLive(attempt)) _tlsReject();
      _offerLocal(attempt);
      return WindowsTlsSession._(this, attempt, session);
    } catch (_) {
      if (confirmation != null) _cancelExisting(confirmation);
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
        event.existingConfirmation ||
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
  Future<bool> verifyExistingCredential(
      ExternalCredentialChallenge challenge, Object event) async {
    if (event is! _ChannelAttempt ||
        !identical(event.owner, this) ||
        !event.existingConfirmation ||
        event.used ||
        !isLive(event) ||
        challenge.requestId == null ||
        challenge.profileId != event.reference.profileId) {
      return false;
    }
    final record = event.snapshot.record!;
    if (challenge.installationId != record.installationId ||
        challenge.credentialIdentity != record.credentialIdentity ||
        challenge.revision != record.revision) {
      return false;
    }
    event.used = true;
    event.runtimeInstance = challenge.runtimeInstance;
    event.generation = challenge.generation;
    await _refresh(event);
    return isLive(event);
  }

  void _cancelExisting(_ExistingChannelConfirmation request) {
    if (request.cancelled) return;
    request.cancelled = true;
    request.poll?.cancel();
    _boundary?.cancelExistingConfirmation(request.candidate);
    if (!request.decision.isCompleted) request.decision.complete();
    final close = request.close;
    if (close != null) {
      scheduleMicrotask(() =>
          unawaited(close().then((_) {}, onError: (Object _, StackTrace __) {
            _existingCleanupFailed = true;
          })));
    } else {
      request.timer.cancel();
      if (identical(_existing, request)) _existing = null;
    }
  }

  Future<void> proofObservationSettled(TlsChannel? channel) async {
    final request = _existing;
    if (request != null && identical(request.channel, channel)) {
      await request.observer;
    }
  }

  @override
  bool isLive(Object event) {
    if (event is! _ChannelAttempt) return !_closed && pairing.isLive(event);
    if (!identical(event.owner, this) || !_attempts.contains(event)) {
      return false;
    }
    try {
      event.businessCurrent?.call();
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
    final pending = _existing;
    if (pending != null && identical(pending.channel, channel)) {
      _cancelExisting(pending);
    }
    for (final attempt
        in _attempts.where((a) => identical(a.channel, channel)).toList()) {
      attempt.invalid = true;
      _attempts.remove(attempt);
    }
    _channels.remove(channel);
  }

  /// Cancels local waiting only. Host retains accepted-channel/Session custody.
  /// Completion of the original open still owns its pending-slot release.
  void cancelLocalConnection() {
    final opening = _localOpening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(const ExternalCredentialException(
          ExternalCredentialFailure.temporarilyUnavailable));
    }
  }

  void close() {
    _closed = true;
    if (_existing case final pending?) _cancelExisting(pending);
    cancelLocalConnection();
    for (final event in _attempts) {
      event.invalid = true;
    }
  }
}

final class _ExistingChannelConfirmation {
  _ExistingChannelConfirmation(this.reference, this.started, this.startedUtc);
  final ExternalProfileReference reference;
  final Duration started;
  final DateTime startedUtc;
  late Timer timer;
  Timer? poll;
  TlsChannel? channel;
  ExternalExistingCredentialConfirmation? candidate;
  FirstPartyExistingCredentialDisplay? display;
  Future<void> work = Future<void>.value();
  Future<void>? settled;
  Future<void>? observer;
  Future<void> Function()? close;
  final decision = Completer<void>();
  bool cancelled = false, claimed = false, polling = false;
  int remaining(Duration now) => (30 - (now - started).inSeconds).clamp(0, 30);
}

final class _ExistingCredentialControl
    implements FirstPartyExistingCredentialPort {
  _ExistingCredentialControl(this.owner);
  final WindowsChannelVerification owner;
  @override
  void begin(ExternalProfileReference profile) {
    if (!owner._available ||
        owner._existing != null ||
        owner._existingCleanupFailed) {
      _tlsReject();
    }
    final request = owner._existing = _ExistingChannelConfirmation(
        profile, owner.monotonicNow(), owner.utcNow());
    request.timer = Timer(ExternalCredentialBoundary.evidenceLifetime,
        () => owner._cancelExisting(request));
  }

  bool _current(_ExistingChannelConfirmation request) {
    if (!owner._available ||
        request.cancelled ||
        request.remaining(owner.monotonicNow()) == 0 ||
        !owner.utcNow().isBefore(request.startedUtc
            .add(ExternalCredentialBoundary.evidenceLifetime))) {
      owner._cancelExisting(request);
      return false;
    }
    return identical(owner._existing, request);
  }

  @override
  FirstPartyExistingCredentialDisplay? display() {
    final request = owner._existing;
    if (request == null) return null;
    final live = _current(request);
    if (!live || request.claimed) {
      return FirstPartyExistingCredentialDisplay(
          profileId: request.reference.profileId,
          remainingSeconds: 0,
          settling: true);
    }
    final candidate = request.candidate;
    return request.display = FirstPartyExistingCredentialDisplay(
        profileId: request.reference.profileId,
        remainingSeconds: request.remaining(owner.monotonicNow()),
        credentialIdentity: candidate?.credentialIdentity,
        installationId: candidate?.installationId,
        revision: candidate?.revision);
  }

  @override
  Future<void> confirm(FirstPartyExistingCredentialDisplay displayed) async {
    final request = owner._existing;
    if (request == null ||
        !_current(request) ||
        request.claimed ||
        !identical(request.display, displayed) ||
        request.candidate == null) {
      _tlsReject();
    }
    request.claimed = true;
    request.poll?.cancel();
    // work never includes Host.done. Host joins this semantic operation first.
    final previous = request.work;
    final work = request.work = () async {
      await previous;
      if (!_current(request)) _tlsReject();
      await owner._boundary!.confirmExistingCredential(request.candidate!);
    }();
    try {
      await work;
    } finally {
      if (!request.decision.isCompleted) request.decision.complete();
      await request.settled;
    }
  }

  @override
  Future<void> cancel() async {
    final request = owner._existing;
    if (request == null) {
      if (owner._existingCleanupFailed) _tlsReject();
      return;
    }
    owner._cancelExisting(request);
    try {
      await request.work;
    } catch (_) {/* Original confirmation retains its semantic failure. */}
    await request.settled;
    if (owner._existingCleanupFailed) _tlsReject();
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
  bool existingConfirmation = false;
  void Function()? businessCurrent;
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

  /// Inactive first-party custody of this SAME P15-authenticated connection.
  ///
  /// No new authentication event or Session is minted by this projection.
  FirstPartyCredentialConnection get firstPartyConnection =>
      FirstPartyCredentialConnection(session, authenticate);
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
