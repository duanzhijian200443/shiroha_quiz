import '../backup/backup_restore_gate.dart';
import 'external_authorization.dart';
import 'external_trust_core.dart';

/// App-owned binding extracted from P3. This adds no pairing or Grant authority.
final class ExternalRuntimeAdmission {
  ExternalRuntimeAdmission({
    required this.trust,
    required ExternalAuthorizationManagement management,
    required bool Function() compositionIsCurrent,
  })  : _management = management,
        _isCurrent = compositionIsCurrent;

  final ExternalTrustCore trust;
  final ExternalAuthorizationManagement _management;
  final bool Function() _isCurrent;
  final _bindings = <ExternalPrincipal, (ExternalProfileReference, int)>{};
  final _onClose = <void Function()>{};
  bool _closed = false;

  void validate() {
    try {
      BackupRestoreMutationGate.instance.ensureMutationAllowed();
    } catch (_) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (_closed || !_isCurrent()) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  /// Trusted App selection only; strings and credential claims cannot bind.
  /// [validateSelection] may reject a withdrawn selection before binding.
  Future<void> bindIdentity(
      ExternalProfileReference reference, ExternalPrincipal principal,
      {void Function()? validateSelection}) async {
    validate();
    final generation = trust.generation;
    trust.snapshot(principal);
    final record = await _management.read(reference);
    validate();
    if (generation != trust.generation ||
        principal.profileId != record.profile.clientProfileId ||
        reference.profileId != principal.profileId ||
        (record.grant != null &&
            record.grant!.profileId != principal.profileId)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    validateSelection?.call();
    if (trust.snapshot(principal).state == PairingState.revoked ||
        record.profile.revokedAtUtcMs != null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _bindings[principal] = (reference, generation);
  }

  /// Releases the binding and P0 slot after the credential owner settles its
  /// association and the current P1 owner confirms durable revocation.
  Future<void> releaseRevokedIdentity(
      ExternalProfileReference reference, ExternalPrincipal principal) async {
    validate();
    final generation = trust.generation;
    final record = await _management.read(reference);
    validate();
    if (generation != trust.generation ||
        reference.profileId != principal.profileId ||
        record.profile.clientProfileId != principal.profileId ||
        record.profile.revokedAtUtcMs == null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    trust.releaseRevokedProfile(principal);
    _bindings.remove(principal);
  }

  void validateSession(ExternalSession session) {
    validate();
    if (trust.sessionFailure(session) != null ||
        _bindings[session.principal]?.$2 != session.generation) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  /// Reloads the management-bound Profile; current policy remains Data-owned.
  Future<ExternalRuntimeAccess> admit(ExternalSession session) async {
    validateSession(session);
    final record = await _management.read(_bindings[session.principal]!.$1);
    validateSession(session);
    if (record.profile.clientProfileId != session.principal.profileId ||
        record.profile.revokedAtUtcMs != null ||
        (record.grant != null &&
            record.grant!.profileId != session.principal.profileId)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return ExternalRuntimeAccess._(this, session, record.grant);
  }

  void onClose(void Function() callback) {
    validate();
    _onClose.add(callback);
  }

  void removeOnClose(void Function() callback) => _onClose.remove(callback);

  void close() {
    if (_closed) return;
    _closed = true;
    _bindings.clear();
    for (final callback in _onClose.toList()) {
      callback();
    }
    _onClose.clear();
  }
}

/// Private constructor, no JSON decoder. This proves runtime admission only.
final class ExternalRuntimeAccess {
  ExternalRuntimeAccess._(this._owner, this.session, this.grantSnapshot);
  final ExternalRuntimeAdmission _owner;
  final ExternalSession session;

  /// Admission snapshot only; owning Data ports still authorize business access.
  final ExternalGrant? grantSnapshot;
  String get profileId => session.principal.profileId;
  int get generation => session.generation;
  void validate() => _owner.validateSession(session);

  Future<bool> revisionIsCurrent(int revision) async {
    final current = await _owner.admit(session);
    final grant = current.grantSnapshot;
    return grant != null &&
        grant.revokedAtUtcMs == null &&
        grant.revision == revision;
  }
}
