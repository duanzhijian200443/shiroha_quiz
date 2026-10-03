import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content_member.dart';
import 'ordinary_training_bank_policy.dart';
import 'sqflite_runtime.dart';
import 'training_content_v29_schema.dart';

/// Safe failure signal; callers roll back their complete durable mutation.
final class TrainingBindingLifecycleException implements Exception {
  const TrainingBindingLifecycleException();
  @override
  String toString() => 'TrainingBindingLifecycleException(unavailable)';
}

/// Invoke once, after ALL business writes, on the caller-owned transaction.
/// Supply the complete set of affected exact bank names; null scans all valid
/// relations (clear-all). Does not open a DB, start a transaction, repair data,
/// modify preference/weights, or restore an already-invalidated relation.
Future<void> invalidateTrainingBindingsAtFinalState(
  DatabaseExecutor db, {
  Iterable<String>? affectedBankNames,
}) async {
  try {
    final names = affectedBankNames?.toSet().toList();
    if (names != null && names.isEmpty) return;
    final rows = await db.rawQuery('''
      SELECT m.content_id, m.bank_name, c.category_key, c.revision
      FROM training_content_members m
      JOIN training_contents c ON c.content_id = m.content_id
      WHERE m.binding_status = 'valid'
      ${names == null ? '' : 'AND m.bank_name IN (${List.filled(names.length, '?').join(',')})'}
      ORDER BY m.bank_name, m.content_id
    ''', names);
    final states = <String, (bool, bool, CategoryKey?)>{};
    final changedContents = <String, int>{};
    final eligibility = DatabaseOrdinaryTrainingBankEligibility(db);
    const codec = CategoryKeyCodec();
    for (final row in rows) {
      final bank = row['bank_name'] as String;
      if (!states.containsKey(bank)) {
        final exists = (await db.rawQuery(
                'SELECT 1 FROM questions WHERE bank_name = ? LIMIT 1', [bank]))
            .isNotEmpty;
        var eligible = false;
        CategoryKey? category;
        if (exists) {
          final result =
              await eligibility.evaluate(OrdinaryTrainingBankInput(bank));
          eligible = switch (result) {
            HomeTrainingSuccess(:final value) =>
              value == OrdinaryTrainingBankEligibilityStatus.eligible,
            HomeTrainingFailed() =>
              throw const TrainingBindingLifecycleException(),
          };
          if (eligible) {
            final mappings = await db.query('bank_folders',
                columns: ['folder_name'],
                where: 'bank_name = ?',
                whereArgs: [bank]);
            category = mappings.isEmpty
                ? const UncategorizedCategoryKey()
                : FolderCategoryKey(mappings.single['folder_name'] as String);
          }
        }
        states[bank] = (exists, eligible, category);
      }
      final (exists, eligible, category) = states[bank]!;
      final encoded = row['category_key'] as String;
      final contentCategory = codec.decodeString(encoded);
      if (codec.encodeString(contentCategory) != encoded) {
        throw const TrainingBindingLifecycleException();
      }
      final reason = !exists
          ? TrainingBindingInvalidationReason.bankMissing
          : !eligible
              ? TrainingBindingInvalidationReason.bankIneligible
              : category != contentCategory
                  ? TrainingBindingInvalidationReason.categoryChanged
                  : null;
      if (reason == null) continue;
      final id = row['content_id'] as String;
      final changed = await db.update(
          trainingContentMembersTable,
          {
            'binding_status': 'invalidated',
            'invalidation_reason': reason.name,
          },
          where:
              "content_id = ? AND bank_name = ? AND binding_status = 'valid'",
          whereArgs: [id, bank]);
      if (changed != 1) {
        throw const TrainingBindingLifecycleException();
      }
      changedContents[id] = row['revision'] as int;
    }
    // Deduplicate by content, including multi-member clear-all invalidation.
    for (final entry in changedContents.entries) {
      final changed = await db.update(
          trainingContentsTable, {'revision': entry.value + 1},
          where: 'content_id = ? AND revision = ?',
          whereArgs: [entry.key, entry.value]);
      if (changed != 1) {
        throw const TrainingBindingLifecycleException();
      }
    }
  } catch (_) {
    throw const TrainingBindingLifecycleException();
  }
}
