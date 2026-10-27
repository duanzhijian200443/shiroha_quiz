import 'dart:async';

import '../capabilities/capability.dart';
import 'external_authorization.dart';
import 'external_trust_core.dart';
import 'local_host_dispatch.dart';

/// Local management selection bound to one offline composition, not a credential.
final class ExternalTrustProfile {
  ExternalTrustProfile._(this._owner, this._reference, this.principal);
  final ExternalTrustCoordinator _owner;
  final ExternalProfileReference _reference;
  final ExternalPrincipal principal;
}

/// App-owned offline orchestration over the existing P0/P4/P7/P8 authorities.
/// No production composition, credential implementation or listener is provided.
final class ExternalTrustCoordinator {
  ExternalTrustCoordinator.offline({
    required ExternalCapabilityGateway gateway,
    required ExternalAuthorizationManagement management,
    required LocalHostReadinessPort readiness,
    required bool Function() compositionIsCurrent,
  })  : _gateway = gateway,
        _management = management,
        _isCurrent = compositionIsCurrent,
        _generation = gateway.admission.trust.generation {
    host = LocalHostDispatchCore(
        gateway: gateway,
        readiness: _TrustReadiness(
            readiness,
            () =>
                !_closed && _isCurrent() && _generation == _trust.generation));
  }

  final ExternalCapabilityGateway _gateway;
  final ExternalAuthorizationManagement _management;
  final bool Function() _isCurrent;
  final int _generation;
  late final LocalHostDispatchCore host;
  ExternalTrustCore get _trust => _gateway.admission.trust;
  bool _closed = false;
  int _pending = 0;
  Completer<void>? _idle;
  Future<void>? _shutdown;

  void _validate() {
    if (_closed || !_isCurrent() || _generation != _trust.generation) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _gateway.admission.validate();
  }

  Future<T> _track<T>(Future<T> Function() work) async {
    _validate();
    if (_pending++ == 0) _idle = Completer<void>();
    try {
      final result = await work();
      _validate();
      return result;
    } finally {
      if (--_pending == 0) {
        _idle!.complete();
        _idle = null;
      }
    }
  }

  Future<ExternalTrustProfile> registerProfile(ExternalProfileReference ref) =>
      _track(() async {
        final principal =
            await _trust.registerExistingProfile(ref, _management);
        _validate();
        await _gateway.admission.bindIdentity(ref, principal);
        return ExternalTrustProfile._(this, ref, principal);
      });

  Future<void> _checkProfile(ExternalTrustProfile profile) async {
    _validate();
    if (!identical(profile._owner, this)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    final record = await _management.read(profile._reference);
    _validate();
    if (record.profile.clientProfileId != profile.principal.profileId ||
        record.profile.revokedAtUtcMs != null ||
        (record.grant != null &&
            record.grant!.profileId != profile.principal.profileId)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _trust.snapshot(profile.principal);
  }

  Future<void> _local(ExternalTrustProfile profile, void Function() action) =>
      _track(() async {
        await _checkProfile(profile);
        action();
      });

  Future<void> requestPairing(ExternalTrustProfile profile,
          {required String requestId, required String credentialIdentity}) =>
      _local(
          profile,
          () => _trust.requestPairing(profile.principal,
              requestId: requestId, credentialIdentity: credentialIdentity));
  Future<void> approvePairing(ExternalTrustProfile profile) =>
      _local(profile, () => _trust.approvePairing(profile.principal));
  Future<void> completePairing(ExternalTrustProfile profile, Object proof) =>
      _local(profile, () => _trust.completePairing(profile.principal, proof));
  Future<void> enable(ExternalTrustProfile profile, Duration duration,
          {DateTime? notAfter}) =>
      _local(profile,
          () => _trust.enable(profile.principal, duration, notAfter: notAfter));
  Future<void> disable(ExternalTrustProfile profile) =>
      _local(profile, () => _trust.disable(profile.principal));

  /// Authentication adds no Grant/Scope/Egress. P8/P7 still admit every call.
  Future<ExternalSession> openSession(
          ExternalTrustProfile profile, Object authenticationAttempt) =>
      _track(() async {
        await _checkProfile(profile);
        final peer = _trust.authenticate(authenticationAttempt);
        if (!identical(peer.principal, profile.principal)) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        final session = _trust.openSession(peer);
        await _gateway.admission.admit(session);
        return session;
      });

  Future<void> startOffline() => _track(host.startOffline);

  /// Blocks immediately, drains P8 owning work and pending local operations,
  /// then invalidates old P0 Sessions. Await before B0/restart/recomposition.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _closed = true;
    final owning = host.shutdown();
    return _shutdown = Future.wait([
      owning,
      _idle?.future ?? Future<void>.value(),
    ]).then((_) => _trust.restart());
  }
}

/// Keeps P8 admission/release closed when this local composition is replaced.
final class _TrustReadiness implements LocalHostReadinessPort {
  const _TrustReadiness(this._inner, this._isCurrent);
  final LocalHostReadinessPort _inner;
  final bool Function() _isCurrent;
  @override
  bool get isCurrent => _isCurrent() && _inner.isCurrent;
  @override
  Future<void> ensureDatabaseReady() => _inner.ensureDatabaseReady();
  @override
  Future<void> ensureRecoveryComplete() => _inner.ensureRecoveryComplete();
  @override
  Future<void> ensureModulesAndRoutesReady() =>
      _inner.ensureModulesAndRoutesReady();
}
