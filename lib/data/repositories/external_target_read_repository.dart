import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_read_context.dart';
import '../../application/external/external_runtime_admission.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/external_authorization_schema.dart';
import 'external_authorization_repository.dart';

/// Read-only, scope-first SQL on the existing database authority. No new writer.
final class SqliteExternalTargetReadRepository
    implements ExternalTargetReadPort {
  SqliteExternalTargetReadRepository({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _helper;

  @override
  Future<ExternalReadSnapshot> query(ExternalRuntimeAccess access,
      int? expectedRevision, void Function() check) async {
    check();
    access.validate();
    final database = await _helper.database;
    check();
    return database.transaction((db) async {
      check();
      final record = await readExternalAuthorization(db, access.profileId);
      check();
      final grant = record.grant;
      if (record.profile.revokedAtUtcMs != null ||
          grant == null ||
          grant.revokedAtUtcMs != null ||
          !grant.policy.permissions.contains(CapabilityPermission.read) ||
          !grant.policy.categories
              .contains(ExternalContentCategory.questionContent)) {
        externalReadFail(ExternalReadFailure.denied);
      }
      if (expectedRevision != null && grant.revision != expectedRevision) {
        externalReadFail(ExternalReadFailure.stale);
      }
      // At most 128 explicit scopes. Never load global banks/projects/files.
      final scopes = grant.policy.scopes
          .where((s) => s.kind == ExternalTargetKind.bank)
          .toList()
        ..sort((a, b) {
          final project = (a.projectId ?? '').compareTo(b.projectId ?? '');
          return project == 0 ? a.targetId.compareTo(b.targetId) : project;
        });
      final targets = <ExternalReadTarget>[];
      for (final scope in scopes) {
        check();
        if (!await externalScopeExists(db, scope)) {
          check();
          continue;
        }
        check();
        // Transaction-local current policy and recipient check, shared with P3.
        await requireExternalGrant(
            db,
            access.profileId,
            grant.revision,
            CapabilityPermission.read,
            scope,
            ExternalContentCategory.questionContent,
            access.profileId);
        check();
        final rows = await db.query('bank_folders',
            columns: ['folder_name'],
            where: 'bank_name=?',
            whereArgs: [scope.targetId],
            limit: 1);
        check();
        final folder =
            rows.isEmpty ? null : rows.single['folder_name'] as String;
        if (!ExternalAuthLimits.text(scope.targetId, 256) ||
            (folder != null && !ExternalAuthLimits.text(folder, 256))) {
          externalReadFail(ExternalReadFailure.unavailable);
        }
        targets
            .add(ExternalReadTarget(scope.targetId, scope.projectId, folder));
      }
      check();
      access.validate();
      return ExternalReadSnapshot(grant, targets);
    });
  }
}
