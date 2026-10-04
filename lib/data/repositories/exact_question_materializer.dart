import '../../core/database/sqflite_runtime.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';

/// Internal Data seam: caller owns the snapshot and the selection predicate.
/// It reads only the bounded exact IDs, union-decodes through the existing
/// mapper, and either reconstructs the whole caller order or throws safely.
Future<List<PersistedQuestion>> materializeExactQuestions(
  DatabaseExecutor db,
  List<String> storageIds, {
  required int maxIds,
  bool requireReviewState = false,
  bool Function(Map<String, Object?> row)? acceptsRow,
}) async {
  storageIds = List<String>.of(storageIds);
  if (storageIds.isEmpty ||
      storageIds.length > maxIds ||
      storageIds.toSet().length != storageIds.length) {
    throw const FormatException('Invalid exact question selection.');
  }
  final placeholders = List.filled(storageIds.length, '?').join(',');
  final reviewColumns = requireReviewState
      ? '''
    , r.question_id AS selected_review_id, r.state AS selected_state,
      r.next_review_time AS selected_due, b.folder_name AS selected_folder
  '''
      : '';
  final reviewJoins = requireReviewState
      ? '''
    LEFT JOIN review_states r ON r.question_id = q.id
    LEFT JOIN bank_folders b ON b.bank_name = q.bank_name
  '''
      : '';
  final rows = await db.rawQuery('''
    SELECT q.*,
      p.question_id AS selected_payload_id,
      p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
      p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      $reviewColumns
    FROM questions q
    LEFT JOIN question_v2_payloads p ON p.question_id = q.id
    $reviewJoins
    WHERE q.id IN ($placeholders)
  ''', storageIds);
  const mapper = QuestionV2PersistenceMapper();
  final byId = <String, PersistedQuestion>{};
  for (final row in rows) {
    if ((requireReviewState && row['selected_review_id'] != row['id']) ||
        (acceptsRow != null && !acceptsRow(row)) ||
        (row['selected_payload_id'] != null &&
            (row[QuestionV2PersistenceMapper.payloadSchemaVersionAlias] ==
                    null ||
                row[QuestionV2PersistenceMapper.payloadJsonAlias] == null))) {
      throw const FormatException('Unavailable exact question selection.');
    }
    final decoded = mapper.decodeJoinedRow(row);
    if (byId.containsKey(decoded.storageId)) {
      throw const FormatException('Ambiguous exact question selection.');
    }
    byId[decoded.storageId] = decoded;
  }
  return List.unmodifiable([
    for (final id in storageIds)
      byId[id] ?? (throw const FormatException('Missing selected question.')),
  ]);
}
