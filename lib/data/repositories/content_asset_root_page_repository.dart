import '../../application/content/content_asset_maintenance.dart';
import '../../core/database/database_helper.dart';
import '../../domain/question/question_draft_v2.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';

final class SqliteContentAssetRootPageRepository
    implements ContentAssetRootPagePort {
  SqliteContentAssetRootPageRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;
  static const QuestionV2PersistenceMapper _mapper =
      QuestionV2PersistenceMapper();

  @override
  Future<List<QuestionDraftV2?>> questionPage({
    required int offset,
    required int limit,
  }) async {
    final db = await _databaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT q.*, p.payload_schema_version AS
        ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
        p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      LEFT JOIN question_v2_payloads p ON p.question_id = q.id
      ORDER BY q.id LIMIT ? OFFSET ?
    ''', <Object?>[limit, offset]);
    return List<QuestionDraftV2?>.unmodifiable(<QuestionDraftV2?>[
      for (final row in rows)
        switch (_mapper.decodeJoinedRow(row)) {
          TypedPersistedQuestion(:final draft) => draft,
          _ => null,
        },
    ]);
  }

  @override
  Future<List<String>> currentArtifactFileIdsPage({
    required int offset,
    required int limit,
  }) async {
    final db = await _databaseHelper.database;
    final rows = await db.query('parsed_artifacts',
        columns: const <String>['file_id'],
        orderBy: 'file_id',
        limit: limit,
        offset: offset);
    return List<String>.unmodifiable(<String>[
      for (final row in rows) row['file_id'] as String,
    ]);
  }

  @override
  Future<List<ContentAssetTaskRootRow>> importTaskPage({
    required int offset,
    required int limit,
  }) async {
    final db = await _databaseHelper.database;
    final rows = await db.query('import_tasks',
        columns: const <String>['status', 'diagnostics', 'parsed_data'],
        orderBy: 'id',
        limit: limit,
        offset: offset);
    return List<ContentAssetTaskRootRow>.unmodifiable(<ContentAssetTaskRootRow>[
      for (final row in rows)
        ContentAssetTaskRootRow(
          status: row['status'] as int,
          diagnostics: row['diagnostics'] as String?,
          parsedData: row['parsed_data'] as String?,
        ),
    ]);
  }
}
