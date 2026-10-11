import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_file_read.dart';
import '../../application/external/external_read_context.dart';
import '../../application/retrieval/retrieval.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/external_authorization_schema.dart';
import 'external_authorization_repository.dart';

/// Exact current scopes only. No global files query, new policy or writer.
final class SqliteExternalFileReadRepository implements ExternalFileReadPort {
  SqliteExternalFileReadRepository({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _helper;

  @override
  Future<List<RetrievalArtifactSnapshot>> query(
      ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot>? selected,
      void Function() check) async {
    check();
    access.validate();
    final database = await _helper.database;
    check();
    try {
      return await database.transaction((db) async {
        await requireExternalGrant(
            db,
            access.runtime.profileId,
            access.revision,
            CapabilityPermission.read,
            access.target.scope,
            ExternalContentCategory.questionContent,
            access.runtime.profileId);
        check();
        final folders = await db.query('bank_folders',
            columns: ['folder_name'],
            where: 'bank_name=?',
            whereArgs: [access.target.bankName],
            limit: 1);
        if ((folders.isEmpty ? null : folders.single['folder_name']) !=
            access.target.folderName) {
          externalReadFail(ExternalReadFailure.stale);
        }
        final record =
            await readExternalAuthorization(db, access.runtime.profileId);
        check();
        final grant = record.grant!;
        if (!grant.policy.categories
            .contains(ExternalContentCategory.fileContent)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final scopes = grant.policy.scopes
            .where((s) =>
                s.kind == ExternalTargetKind.file &&
                s.projectId == access.target.projectId)
            .toList()
          ..sort((a, b) => a.targetId.compareTo(b.targetId));
        if (selected != null &&
            (selected.isEmpty ||
                selected.length > 64 ||
                selected.map((f) => f.fileId).toSet().length !=
                    selected.length ||
                !selected
                    .every((f) => scopes.any((s) => s.targetId == f.fileId)))) {
          externalReadFail(ExternalReadFailure.denied);
        }
        if (scopes.isEmpty) externalReadFail(ExternalReadFailure.denied);
        final result = <RetrievalArtifactSnapshot>[];
        for (final scope in scopes.where((s) =>
            selected == null || selected.any((f) => f.fileId == s.targetId))) {
          check();
          await requireExternalGrant(
              db,
              access.runtime.profileId,
              access.revision,
              CapabilityPermission.read,
              scope,
              ExternalContentCategory.fileContent,
              access.runtime.profileId);
          check();
          final rows = await db.rawQuery('''
            SELECT p.artifact_id, p.revision, p.payload_sha256,
              p.source_sha256, f.sha256 AS file_sha256
            FROM parsed_artifacts p JOIN library_files f ON f.file_id=p.file_id
            WHERE p.file_id=? LIMIT 1
          ''', [scope.targetId]);
          check();
          if (rows.isEmpty) {
            externalReadFail(ExternalReadFailure.sourceNotReady);
          }
          final row = rows.single;
          if (row['source_sha256'] != row['file_sha256']) {
            externalReadFail(ExternalReadFailure.stale);
          }
          final snapshot = RetrievalArtifactSnapshot(
              fileId: scope.targetId,
              artifactId: row['artifact_id'] as String,
              revision: row['revision'] as int,
              payloadDigest: row['payload_sha256'] as String);
          if (selected != null &&
              !selected.any((f) => f.sameGeneration(snapshot))) {
            externalReadFail(ExternalReadFailure.stale);
          }
          result.add(snapshot);
        }
        check();
        access.validate();
        return result;
      });
    } on ExternalReadException {
      rethrow;
    } on ExternalAuthException {
      externalReadFail(ExternalReadFailure.denied);
    } catch (_) {
      externalReadFail(ExternalReadFailure.dataCorrupt);
    }
  }
}
