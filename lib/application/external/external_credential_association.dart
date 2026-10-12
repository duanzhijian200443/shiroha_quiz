/// Protected External association contracts only; no key/store format is chosen.
library;

enum ExternalCredentialFailure {
  unauthorized,
  invalidInput,
  conflict,
  staleRevision,
  dataCorrupt,
  temporarilyUnavailable,
  commitUnknown,
  verificationRejected,
  resourceLimit,
}

final class ExternalCredentialException implements Exception {
  const ExternalCredentialException(this.failure);
  final ExternalCredentialFailure failure;
  @override
  String toString() => 'ExternalCredentialException(${failure.name})';
}

Never credentialFail(ExternalCredentialFailure failure) =>
    throw ExternalCredentialException(failure);

/// Non-secret store data, never authentication evidence or a Principal factory.
final class ExternalCredentialAssociation {
  const ExternalCredentialAssociation({
    required this.profileId,
    required this.installationId,
    required this.credentialIdentity,
    required this.revision,
    required this.revoked,
  });
  final String profileId, installationId, credentialIdentity;
  final int revision;
  final bool revoked;
  @override
  String toString() => 'ExternalCredentialAssociation(REDACTED)';
}

/// Backend-owned integrity/currentness lease. Missing is a current null record.
/// Once invalid, this lease must never become valid again, including recovery
/// from store outage/corruption. No cached record can substitute for a read.
abstract interface class ExternalCredentialAssociationSnapshot {
  ExternalCredentialAssociation? get record;
  bool get isCurrent;
}

/// Dedicated authority, separate from SQLite policy and S0 engine.* keys.
/// Implementations serialize CAS/uniqueness and validate local management at
/// their commit boundary. Failures are typed; uncertain commit is never success.
/// Tombstones retain revisions; same active tuple/exact revision is idempotent.
/// No production backend is supplied by this offline stage.
abstract interface class ExternalCredentialAssociationStore {
  Future<ExternalCredentialAssociationSnapshot> read(String profileId);
  Future<ExternalCredentialAssociationSnapshot> register({
    required String profileId,
    required String installationId,
    required String credentialIdentity,
    required int expectedRevision,
    required Future<void> Function() validateManagement,
  });
  Future<ExternalCredentialAssociationSnapshot> revoke({
    required String profileId,
    required int expectedRevision,
    required Future<void> Function() validateManagement,
  });
}
