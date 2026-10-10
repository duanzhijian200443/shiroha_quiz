import '../capabilities/capability.dart';
import '../backup/backup_restore_gate.dart';

enum ExternalAuthFailure {
  invalidInput,
  unauthorized,
  staleRevision,
  corruptState,
  persistenceFailed
}

final class ExternalAuthException implements Exception {
  const ExternalAuthException(this.failure);
  final ExternalAuthFailure failure;
  @override
  String toString() => 'ExternalAuthException(${failure.name})';
}

Never externalAuthFail(ExternalAuthFailure failure) =>
    throw ExternalAuthException(failure);

abstract final class ExternalAuthLimits {
  static const maxRevision = 2147483647;
  static const maxTime = 9007199254740991;
  static const maxScopes = 128;
  static bool validId(String id) => RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
      .hasMatch(id);
  static bool text(String value, int max) =>
      value.isNotEmpty &&
      value.length <= max &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  static bool token(String value) =>
      RegExp(r'^[a-z][a-z0-9._-]{0,31}$').hasMatch(value);
  static void time(int value) {
    if (value < 0 || value > maxTime) {
      externalAuthFail(ExternalAuthFailure.invalidInput);
    }
  }
}

/// Non-secret metadata only. This value proves neither authentication nor pairing.
final class ExternalClientProfile {
  ExternalClientProfile(
      {required this.clientProfileId,
      required this.displayName,
      required this.adapter,
      required this.protocol,
      required this.createdAtUtcMs,
      required this.grantRevision,
      this.revokedAtUtcMs}) {
    if (!ExternalAuthLimits.validId(clientProfileId) ||
        !ExternalAuthLimits.text(displayName, 80) ||
        displayName.trim() != displayName ||
        !ExternalAuthLimits.token(adapter) ||
        !ExternalAuthLimits.token(protocol) ||
        grantRevision < 0 ||
        grantRevision > ExternalAuthLimits.maxRevision) {
      externalAuthFail(ExternalAuthFailure.invalidInput);
    }
    ExternalAuthLimits.time(createdAtUtcMs);
    if (revokedAtUtcMs != null) {
      ExternalAuthLimits.time(revokedAtUtcMs!);
      if (revokedAtUtcMs! < createdAtUtcMs) {
        externalAuthFail(ExternalAuthFailure.invalidInput);
      }
    }
  }
  final String clientProfileId, displayName, adapter, protocol;
  final int createdAtUtcMs, grantRevision;
  final int? revokedAtUtcMs;
}

enum ExternalTargetKind { bank, file }

enum ExternalContentCategory { questionContent, fileContent, proposalMetadata }

/// A named target in one Learning Space, or an explicit local target (null).
/// Empty scopes deny everything; null never grants all banks/files.
final class ExternalGrantScope {
  ExternalGrantScope(
      {required this.kind, required this.targetId, this.projectId}) {
    if (!ExternalAuthLimits.text(targetId, 256) ||
        (projectId != null && !ExternalAuthLimits.text(projectId!, 128))) {
      externalAuthFail(ExternalAuthFailure.invalidInput);
    }
  }
  final ExternalTargetKind kind;
  final String targetId;
  final String? projectId;
  @override
  bool operator ==(Object other) =>
      other is ExternalGrantScope &&
      other.kind == kind &&
      other.targetId == targetId &&
      other.projectId == projectId;
  @override
  int get hashCode => Object.hash(kind, targetId, projectId);
}

final class ExternalGrantPolicy {
  ExternalGrantPolicy(
      {required Iterable<CapabilityPermission> permissions,
      required Iterable<ExternalGrantScope> scopes,
      required Iterable<ExternalContentCategory> categories})
      : permissions = Set.unmodifiable(permissions),
        scopes = List.unmodifiable(scopes),
        categories = Set.unmodifiable(categories) {
    if (this.permissions.isEmpty ||
        this.permissions.any((p) =>
            p != CapabilityPermission.read &&
            p != CapabilityPermission.stage) ||
        this.scopes.length > ExternalAuthLimits.maxScopes ||
        this.scopes.toSet().length != this.scopes.length) {
      externalAuthFail(ExternalAuthFailure.invalidInput);
    }
  }
  final Set<CapabilityPermission> permissions;
  final List<ExternalGrantScope> scopes;
  final Set<ExternalContentCategory> categories;
}

/// Recipient is the owning Profile, never a client-supplied provider/brand.
final class ExternalGrant {
  const ExternalGrant(
      {required this.profileId,
      required this.revision,
      required this.updatedAtUtcMs,
      required this.policy,
      this.revokedAtUtcMs});
  final String profileId;
  final int revision, updatedAtUtcMs;
  final int? revokedAtUtcMs;
  final ExternalGrantPolicy policy;
}

final class ExternalAuthorizationRecord {
  const ExternalAuthorizationRecord(this.profile, this.grant);
  final ExternalClientProfile profile;
  final ExternalGrant? grant;
}

/// Owning Data port. validateManagement must be checked inside write transactions.
abstract interface class ExternalAuthorizationRepository {
  Future<ExternalAuthorizationRecord> create(
      ExternalClientProfile profile, void Function() validateManagement);
  Future<ExternalAuthorizationRecord> read(String profileId);
  Future<ExternalAuthorizationRecord> change(
      String profileId,
      int expectedRevision,
      ExternalGrantPolicy? policy,
      int nowUtcMs,
      bool revokeProfile,
      void Function() validateManagement);
  Future<ExternalGrant> currentGrant(
      String profileId,
      int expectedRevision,
      CapabilityPermission permission,
      ExternalGrantScope scope,
      ExternalContentCategory category,
      String recipientProfileId);
}

/// Opaque local management reference; an arbitrary Profile id is not authority.
final class ExternalProfileReference {
  ExternalProfileReference._(this._owner, this.profileId);
  final ExternalAuthorizationManagement _owner;
  final String profileId;
}

/// Construct only at trusted first-party Application composition. No RPC route.
/// The Profile id factory belongs to that composition, never to a request.
/// This manages durable policy, not the trust state machine or a Dispatcher.
final class ExternalAuthorizationManagement {
  ExternalAuthorizationManagement(
      {required ExternalAuthorizationRepository repository,
      required bool Function() compositionIsCurrent,
      required String Function() mintProfileId,
      DateTime Function()? clock})
      : _repository = repository,
        _isCurrent = compositionIsCurrent,
        _mintProfileId = mintProfileId,
        _clock = clock ?? DateTime.now;
  final ExternalAuthorizationRepository _repository;
  final bool Function() _isCurrent;
  final String Function() _mintProfileId;
  final DateTime Function() _clock;
  bool _invalidated = false;
  void invalidate() => _invalidated = true;
  void _validate() {
    BackupRestoreMutationGate.instance.ensureMutationAllowed();
    if (_invalidated || !_isCurrent()) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  void _reference(ExternalProfileReference ref) {
    _validate();
    if (!identical(ref._owner, this)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
  }

  Future<ExternalProfileReference> createProfile(
      {required String displayName,
      required String adapter,
      required String protocol}) async {
    _validate();
    final profile = ExternalClientProfile(
        clientProfileId: _mintProfileId(),
        displayName: displayName,
        adapter: adapter,
        protocol: protocol,
        createdAtUtcMs: _clock().toUtc().millisecondsSinceEpoch,
        grantRevision: 0);
    await _repository.create(profile, _validate);
    _validate();
    return ExternalProfileReference._(this, profile.clientProfileId);
  }

  /// Local UI selection only. Future credential mapping requires its own proof.
  Future<ExternalProfileReference> selectProfile(String profileId) async {
    _validate();
    await _repository.read(profileId);
    _validate();
    return ExternalProfileReference._(this, profileId);
  }

  Future<ExternalAuthorizationRecord> read(ExternalProfileReference ref) async {
    _reference(ref);
    final result = await _repository.read(ref.profileId);
    _reference(ref);
    return result;
  }

  Future<ExternalAuthorizationRecord> replaceGrant(ExternalProfileReference ref,
          int expectedRevision, ExternalGrantPolicy policy) =>
      _change(ref, expectedRevision, policy, false);
  Future<ExternalAuthorizationRecord> revokeGrant(
          ExternalProfileReference ref, int expectedRevision) =>
      _change(ref, expectedRevision, null, false);
  Future<ExternalAuthorizationRecord> revokeProfile(
          ExternalProfileReference ref, int expectedRevision) =>
      _change(ref, expectedRevision, null, true);
  Future<ExternalAuthorizationRecord> _change(ExternalProfileReference ref,
      int revision, ExternalGrantPolicy? policy, bool revokeProfile) async {
    _reference(ref);
    final result = await _repository.change(
        ref.profileId,
        revision,
        policy,
        _clock().toUtc().millisecondsSinceEpoch,
        revokeProfile,
        () => _reference(ref));
    _reference(ref);
    return result;
  }

  /// Current durable policy inspection only: does not authenticate or enable use.
  Future<ExternalGrant> inspectGrant(ExternalProfileReference ref,
      {required int expectedRevision,
      required CapabilityPermission permission,
      required ExternalGrantScope scope,
      required ExternalContentCategory category,
      required String recipientProfileId}) async {
    _reference(ref);
    final grant = await _repository.currentGrant(ref.profileId,
        expectedRevision, permission, scope, category, recipientProfileId);
    _reference(ref);
    return grant;
  }
}
