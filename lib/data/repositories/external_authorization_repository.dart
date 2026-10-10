import '../../application/backup/backup_restore_gate.dart';
import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/external_authorization_schema.dart';
import '../../core/database/sqflite_runtime.dart';

/// All writes use the existing database and B0 mutation gate. No Host wiring.
final class SqliteExternalAuthorizationRepository
    implements ExternalAuthorizationRepository {
  SqliteExternalAuthorizationRepository({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _helper;
  Future<T> _transaction<T>(Future<T> Function(Transaction) body,
      {bool write = false}) async {
    Future<T> run() async {
      try {
        final db = await _helper.database;
        return await db.transaction((txn) async {
          await validateExternalAuthorizationSchema(txn);
          return body(txn);
        });
      } on ExternalAuthException {
        rethrow;
      } catch (_) {
        externalAuthFail(ExternalAuthFailure.persistenceFailed);
      }
    }

    return write ? BackupRestoreMutationGate.instance.runMutation(run) : run();
  }

  @override
  Future<ExternalAuthorizationRecord> create(
          ExternalClientProfile profile, void Function() validateManagement) =>
      _transaction((db) async {
        validateManagement();
        if (profile.grantRevision != 0 || profile.revokedAtUtcMs != null) {
          externalAuthFail(ExternalAuthFailure.invalidInput);
        }
        await db.insert('external_client_profiles', {
          'profile_id': profile.clientProfileId,
          'display_name': profile.displayName,
          'adapter': profile.adapter,
          'protocol': profile.protocol,
          'created_at': profile.createdAtUtcMs,
          'grant_revision': 0
        });
        final result =
            await readExternalAuthorization(db, profile.clientProfileId);
        validateManagement();
        return result;
      }, write: true);
  @override
  Future<ExternalAuthorizationRecord> read(String profileId) =>
      _transaction((db) => readExternalAuthorization(db, profileId));

  @override
  Future<ExternalAuthorizationRecord> change(
          String profileId,
          int expectedRevision,
          ExternalGrantPolicy? policy,
          int nowUtcMs,
          bool revokeProfile,
          void Function() validateManagement) =>
      _transaction((db) async {
        validateManagement();
        ExternalAuthLimits.time(nowUtcMs);
        if (expectedRevision < 0 ||
            expectedRevision >= ExternalAuthLimits.maxRevision ||
            (revokeProfile && policy != null)) {
          externalAuthFail(ExternalAuthFailure.invalidInput);
        }
        final before = await readExternalAuthorization(db, profileId);
        if (before.profile.revokedAtUtcMs != null) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        if (before.profile.grantRevision != expectedRevision) {
          externalAuthFail(ExternalAuthFailure.staleRevision);
        }
        if (nowUtcMs < before.profile.createdAtUtcMs ||
            (before.grant != null && nowUtcMs < before.grant!.updatedAtUtcMs)) {
          externalAuthFail(ExternalAuthFailure.invalidInput);
        }
        if (policy == null && before.grant == null && !revokeProfile) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        if (policy != null) {
          for (final scope in policy.scopes) {
            if (!await externalScopeExists(db, scope)) {
              externalAuthFail(ExternalAuthFailure.unauthorized);
            }
          }
        }
        final revision = expectedRevision + 1;
        final count = await db.update(
            'external_client_profiles',
            {
              'grant_revision': revision,
              if (revokeProfile) 'revoked_at': nowUtcMs
            },
            where: 'profile_id=? AND grant_revision=? AND revoked_at IS NULL',
            whereArgs: [profileId, expectedRevision]);
        if (count != 1) externalAuthFail(ExternalAuthFailure.staleRevision);
        if (policy != null) {
          final row = {
            'profile_id': profileId,
            'revision': revision,
            'allow_read':
                policy.permissions.contains(CapabilityPermission.read) ? 1 : 0,
            'allow_stage':
                policy.permissions.contains(CapabilityPermission.stage) ? 1 : 0,
            'updated_at': nowUtcMs,
            'revoked_at': null
          };
          if (before.grant == null) {
            await db.insert('external_grants', row);
          } else {
            await db.update('external_grants', row,
                where: 'profile_id=?', whereArgs: [profileId]);
          }
          await db.delete('external_grant_scopes',
              where: 'profile_id=?', whereArgs: [profileId]);
          await db.delete('external_grant_egress',
              where: 'profile_id=?', whereArgs: [profileId]);
          for (final scope in policy.scopes) {
            await db.insert('external_grant_scopes', {
              'profile_id': profileId,
              'project_id': scope.projectId ?? '',
              'target_kind': scope.kind.name,
              'target_id': scope.targetId
            });
          }
          for (final category in policy.categories) {
            await db.insert('external_grant_egress',
                {'profile_id': profileId, 'category': category.name});
          }
        } else if (before.grant != null) {
          await db.update('external_grants',
              {'updated_at': nowUtcMs, 'revoked_at': nowUtcMs},
              where: 'profile_id=?', whereArgs: [profileId]);
        }
        final result = await readExternalAuthorization(db, profileId);
        if (result.profile.grantRevision != revision) {
          externalAuthFail(ExternalAuthFailure.corruptState);
        }
        validateManagement();
        return result;
      }, write: true);

  @override
  Future<ExternalGrant> currentGrant(
          String profileId,
          int expectedRevision,
          CapabilityPermission permission,
          ExternalGrantScope scope,
          ExternalContentCategory category,
          String recipientProfileId) =>
      _transaction((db) async {
        return (await requireExternalGrant(db, profileId, expectedRevision,
                permission, scope, category, recipientProfileId))
            .grant!;
      });
}

Future<bool> externalScopeExists(
    DatabaseExecutor db, ExternalGrantScope scope) async {
  if (scope.projectId != null &&
      (await db.query('projects',
              columns: ['project_id'],
              where: 'project_id=?',
              whereArgs: [scope.projectId],
              limit: 1))
          .isEmpty) {
    return false;
  }
  final exists = scope.kind == ExternalTargetKind.bank
      ? (await db.rawQuery(
              'SELECT 1 FROM bank_folders WHERE bank_name=? UNION SELECT 1 FROM questions WHERE bank_name=? LIMIT 1',
              [
              scope.targetId,
              scope.targetId
            ]))
          .isNotEmpty
      : (await db.query('library_files',
              columns: ['file_id'],
              where: 'file_id=?',
              whereArgs: [scope.targetId],
              limit: 1))
          .isNotEmpty;
  if (!exists || scope.projectId == null) return exists;
  final table =
      scope.kind == ExternalTargetKind.bank ? 'project_banks' : 'project_files';
  final column =
      scope.kind == ExternalTargetKind.bank ? 'bank_name' : 'file_id';
  return (await db.rawQuery(
          'SELECT 1 FROM $table WHERE project_id=? AND $column=? LIMIT 1',
          [scope.projectId, scope.targetId]))
      .isNotEmpty;
}

/// Transaction-local policy check shared by policy inspection and publication.
Future<ExternalAuthorizationRecord> requireExternalGrant(
    DatabaseExecutor db,
    String profileId,
    int? expectedRevision,
    CapabilityPermission permission,
    ExternalGrantScope scope,
    ExternalContentCategory category,
    String recipientProfileId) async {
  final record = await readExternalAuthorization(db, profileId);
  final grant = record.grant;
  if (record.profile.revokedAtUtcMs != null ||
      grant == null ||
      grant.revokedAtUtcMs != null ||
      (expectedRevision != null && grant.revision != expectedRevision) ||
      profileId != recipientProfileId ||
      !grant.policy.permissions.contains(permission) ||
      !grant.policy.scopes.contains(scope) ||
      !grant.policy.categories.contains(category) ||
      (scope.kind == ExternalTargetKind.bank &&
          category == ExternalContentCategory.fileContent) ||
      (scope.kind == ExternalTargetKind.file &&
          category != ExternalContentCategory.fileContent) ||
      !await externalScopeExists(db, scope)) {
    externalAuthFail(ExternalAuthFailure.unauthorized);
  }
  return record;
}
