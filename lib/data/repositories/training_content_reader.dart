import '../../core/database/sqflite_runtime.dart';
import '../../core/database/training_content_v29_schema.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/training_content_member.dart';

/// Internal admission signal; callers map it to their safe result boundary.
final class TrainingContentRevisionMismatch implements Exception {
  const TrainingContentRevisionMismatch();
}

/// Reads one authoritative configuration through the caller's transaction.
/// When provided, revision admission precedes member decoding and selection.
/// Missing content is null; malformed persisted data throws and is never healed.
Future<TrainingContent?> readTrainingContent(
  DatabaseExecutor db,
  String id, {
  int? expectedRevision,
}) async {
  final rows = await db
      .query(trainingContentsTable, where: 'content_id = ?', whereArgs: [id]);
  if (rows.isEmpty) return null;
  final row = rows.single;
  final revision = row['revision'] as int;
  if (revision <= 0) {
    throw const FormatException('Invalid training revision.');
  }
  if (expectedRevision != null && revision != expectedRevision) {
    throw const TrainingContentRevisionMismatch();
  }
  const codec = CategoryKeyCodec();
  final encoded = row['category_key'] as String;
  final category = codec.decodeString(encoded);
  if (codec.encodeString(category) != encoded) {
    throw const FormatException('Invalid training category.');
  }
  final members = await db.query(trainingContentMembersTable,
      where: 'content_id = ?',
      whereArgs: [id],
      orderBy: 'position ASC, bank_name ASC');
  return TrainingContent(
    contentId: row['content_id'] as String,
    categoryKey: category,
    name: row['name'] as String,
    questionLimit: row['question_limit'] as int,
    sortOrder: row['sort_order'] as int,
    revision: revision,
    members: [
      for (final member in members)
        TrainingContentMember(
          bankName: member['bank_name'] as String,
          weightPercent: member['weight_percent'] as int,
          position: member['position'] as int,
          bindingStatus: TrainingBindingStatus.values
              .byName(member['binding_status'] as String),
          invalidationReason: member['invalidation_reason'] == null
              ? null
              : TrainingBindingInvalidationReason.values
                  .byName(member['invalidation_reason'] as String),
        )
    ],
  );
}
