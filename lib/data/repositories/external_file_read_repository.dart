import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import '../../application/external/external_file_read.dart';
import '../../application/external/external_read_context.dart';
import '../../application/retrieval/retrieval.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/external_authorization_schema.dart';
import 'external_authorization_repository.dart';

/// Current explicit policy and Project relationships; never parses source files.
final class SqliteExternalFileReadRepository implements ExternalFileReadPort {
  SqliteExternalFileReadRepository({DatabaseHelper? databaseHelper})
      : _helper = databaseHelper ?? DatabaseHelper.instance;
  final DatabaseHelper _helper;

  @override
  Future<List<RetrievalArtifactSnapshot>> query(
          ExternalQuestionReadAccess access,
          List<RetrievalArtifactSnapshot>? selected,
          void Function() check) async =>
      (await _query(access, selected, check)).files;

  @override
  Future<ExternalFileChoicePage> listChoices(ExternalQuestionReadAccess access,
          int pageSize, String? afterFileId, void Function() check) =>
      _query(access, null, check, pageSize: pageSize, afterFileId: afterFileId);

  Future<ExternalFileChoicePage> _query(ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot>? selected, void Function() check,
      {int? pageSize, String? afterFileId}) async {
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
        final allScopes = <ExternalGrantScope>[];
        if (grant.policy.allContent) {
          final selectedIds = selected?.map((f) => f.fileId).toList();
          final constraints = <String>[
            if (access.target.projectId != null) 'project_id=?',
            if (afterFileId != null) 'file_id>?',
            if (selectedIds != null)
              'file_id IN (${List.filled(selectedIds.length, '?').join(',')})',
          ];
          final files = await db.rawQuery(
              'SELECT file_id FROM ${access.target.projectId == null ? 'library_files' : 'project_files'} '
              '${constraints.isEmpty ? '' : 'WHERE ${constraints.join(' AND ')}'} '
              'ORDER BY file_id ${pageSize == null ? '' : 'LIMIT ?'}',
              [
                if (access.target.projectId != null) access.target.projectId,
                if (afterFileId != null) afterFileId,
                ...?selectedIds,
                if (pageSize != null) pageSize + 1
              ]);
          check();
          for (final file in files) {
            allScopes.add(ExternalGrantScope(
                kind: ExternalTargetKind.file,
                targetId: file['file_id'] as String,
                projectId: access.target.projectId));
          }
        }
        final scopes = (grant.policy.allContent
                ? allScopes
                : grant.policy.scopes)
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
        if (scopes.isEmpty && pageSize == null)
          externalReadFail(ExternalReadFailure.denied);
        if (scopes.isEmpty && !grant.policy.allContent)
          externalReadFail(ExternalReadFailure.denied);
        final remaining = scopes
            .where((s) =>
                afterFileId == null || s.targetId.compareTo(afterFileId) > 0)
            .toList();
        final page =
            pageSize == null ? remaining : remaining.take(pageSize).toList();
        final hasMore = pageSize != null && remaining.length > pageSize;
        var excluded = false;
        final result = <RetrievalArtifactSnapshot>[];
        for (final scope in page.where((s) =>
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
            if (pageSize != null && grant.policy.allContent) {
              excluded = true;
              continue;
            }
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
        return ExternalFileChoicePage(result,
            nextFileId: hasMore ? page.last.targetId : null,
            unsupportedExcluded: excluded);
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
