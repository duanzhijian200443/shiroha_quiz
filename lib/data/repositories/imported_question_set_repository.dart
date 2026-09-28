import '../../application/answer_completion/answer_completion_query.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/answer_completion/imported_question_set.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';

/// Query-only adapter. All reads use the same transaction executor, including
/// soft source provenance and the global membership exclusion for ungrouped.
final class ImportedQuestionSetRepository implements AnswerCompletionQuery {
  ImportedQuestionSetRepository(
      {DatabaseHelper? databaseHelper, Future<Database> Function()? database})
      : _database = database ??
            (() => (databaseHelper ?? DatabaseHelper.instance).database);

  final Future<Database> Function() _database;
  static const _mapper = QuestionV2PersistenceMapper();
  static const _payloadColumns = '''
    p.question_id AS sidecar_id,
    p.payload_schema_version AS v2_payload_schema_version,
    p.payload_json AS v2_payload_json
  ''';

  @override
  Future<AnswerCompletionRead> readBank(String bankName) async {
    try {
      final db = await _database();
      return await db.transaction((txn) async {
        final sets = await txn.rawQuery('''
          SELECT s.*, f.file_id AS available_source
          FROM imported_question_sets s
          LEFT JOIN library_files f ON f.file_id = s.source_file_id
          WHERE s.bank_name = ? ORDER BY s.created_at DESC, s.set_id
        ''', [bankName]);
        final rows = await txn.rawQuery('''
          SELECT q.*, i.set_id, i.question_storage_id, $_payloadColumns
          FROM imported_question_set_items i
          JOIN imported_question_sets s ON s.set_id = i.set_id
          LEFT JOIN questions q ON q.id = i.question_storage_id
          LEFT JOIN question_v2_payloads p ON p.question_id = q.id
          WHERE s.bank_name = ? ORDER BY i.set_id, i.position
        ''', [bankName]);
        final ungrouped = await txn.rawQuery('''
          SELECT q.*, $_payloadColumns FROM questions q
          LEFT JOIN question_v2_payloads p ON p.question_id = q.id
          WHERE q.bank_name = ? AND NOT EXISTS (
            SELECT 1 FROM imported_question_set_items i
            WHERE i.question_storage_id = q.id
          ) ORDER BY q.created_at, q.id
        ''', [bankName]);
        final members = <String, List<AnswerCompletionMember>>{};
        for (final row in rows) {
          final id = row['question_storage_id'] as String;
          members.putIfAbsent(row['set_id'] as String, () => []).add(
                row['id'] == null || row['bank_name'] != bankName
                    ? AnswerCompletionMember.corrupt(id)
                    : _member(row, id),
              );
        }
        return AnswerCompletionSnapshot(
          sets: [
            for (final row in sets)
              AnswerCompletionSet(
                set: ImportedQuestionSet(
                  setId: row['set_id'] as String,
                  bankName: row['bank_name'] as String,
                  displayName: row['display_name'] as String,
                  createdAt: row['created_at'] as int,
                  sourceFileId: row['source_file_id'] as String?,
                ),
                provenance: row['source_file_id'] == null
                    ? AnswerCompletionProvenance.none
                    : row['available_source'] == null
                        ? AnswerCompletionProvenance.unavailable
                        : AnswerCompletionProvenance.available,
                members: members[row['set_id']] ?? const [],
              )
          ],
          ungrouped: [
            for (final row in ungrouped) _member(row, row['id'] as String)
          ].where((m) => m.eligibility == AnswerCompletionEligibility.missing),
        );
      });
    } catch (_) {
      return const AnswerCompletionQueryUnavailable();
    }
  }

  AnswerCompletionMember _member(Map<String, Object?> row, String id) {
    // A present but malformed sidecar must never be decoded as legacy,
    // including databases whose nullability constraints were corrupted.
    if (row['sidecar_id'] == null) return AnswerCompletionMember.legacy(id);
    if (row['v2_payload_schema_version'] == null ||
        row['v2_payload_json'] == null) {
      return AnswerCompletionMember.corrupt(id);
    }
    try {
      final question = _mapper.decodeJoinedRow(row);
      return switch (question) {
        TypedPersistedQuestion(:final draft) =>
          AnswerCompletionMember.typed(storageId: id, typedDraft: draft),
        LegacyPersistedQuestion() => AnswerCompletionMember.corrupt(id),
      };
    } on QuestionV2PayloadException {
      return AnswerCompletionMember.corrupt(id);
    }
  }
}
