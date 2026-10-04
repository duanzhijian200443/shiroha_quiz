import 'dart:math';

import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import '../../core/database/ordinary_training_bank_policy.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_allocation.dart';
import '../../domain/training/training_content.dart';
import '../models/persisted_question.dart';
import 'exact_question_materializer.dart';

sealed class TrainingQuestionSelectionResult {
  const TrainingQuestionSelectionResult();
}

final class TrainingQuestionSelectionSuccess
    extends TrainingQuestionSelectionResult {
  TrainingQuestionSelectionSuccess(List<PersistedQuestion> questions)
      : questions = List.unmodifiable(questions) {
    if (questions.isEmpty || questions.length > 100) {
      throw const FormatException('Invalid training question batch.');
    }
  }
  final List<PersistedQuestion> questions;
}

final class TrainingQuestionSelectionEmpty
    extends TrainingQuestionSelectionResult {
  const TrainingQuestionSelectionEmpty();
}

/// Safe whole failure; never carries SQL, raw causes or a partial batch.
final class TrainingQuestionSelectionUnavailable
    extends TrainingQuestionSelectionResult {
  const TrainingQuestionSelectionUnavailable();
}

/// Read-only bounded training preparation. No configuration CAS or queue write.
final class TrainingQuestionSelection {
  const TrainingQuestionSelection({required this.database});
  final Future<Database> Function() database;

  // Count and windows deliberately never read question content or sidecars.
  static const newCountSql = '''
    SELECT COUNT(*) AS candidate_count FROM questions q
    JOIN review_states r ON r.question_id = q.id
    WHERE q.bank_name = ? AND r.state = 0
  ''';
  static const newWindowSql = '''
    SELECT q.id FROM questions q
    JOIN review_states r ON r.question_id = q.id
    WHERE q.bank_name = ? AND r.state = 0
    ORDER BY q.id ASC LIMIT ? OFFSET ?
  ''';

  Future<TrainingQuestionSelectionResult> _read(
    Future<TrainingQuestionSelectionResult> Function(DatabaseExecutor) read,
  ) async {
    try {
      final db = await database();
      return await db.transaction(read);
    } catch (_) {
      return const TrainingQuestionSelectionUnavailable();
    }
  }

  CategoryKey _category(Object? folder) => folder == null
      ? const UncategorizedCategoryKey()
      : FolderCategoryKey(folder as String);

  Future<bool> _eligibleInCategory(
      DatabaseExecutor db, String bank, CategoryKey category) async {
    final eligibility = await DatabaseOrdinaryTrainingBankEligibility(db)
        .evaluate(OrdinaryTrainingBankInput(bank));
    if (eligibility is HomeTrainingFailed) {
      throw const FormatException('Unavailable training eligibility.');
    }
    if ((eligibility
                as HomeTrainingSuccess<OrdinaryTrainingBankEligibilityStatus>)
            .value !=
        OrdinaryTrainingBankEligibilityStatus.eligible) {
      return false;
    }
    final mapping = await db.query('bank_folders',
        columns: ['folder_name'], where: 'bank_name = ?', whereArgs: [bank]);
    return _category(mapping.isEmpty ? null : mapping.single['folder_name']) ==
        category;
  }

  Future<void> _admit(DatabaseExecutor db, TrainingContent content) async {
    if (!content.hasValidBindings) {
      throw const FormatException('Unavailable training bindings.');
    }
    for (final member in content.members) {
      if (!await _eligibleInCategory(
          db, member.bankName, content.categoryKey)) {
        throw const FormatException('Unavailable training member.');
      }
    }
  }

  Future<TrainingQuestionSelectionResult> selectNew(TrainingContent content,
          {required Random random}) =>
      _read((db) async {
        await _admit(db, content);
        final positive =
            content.members.where((m) => m.weightPercent > 0).toList()
              ..sort((a, b) {
                final order = a.position.compareTo(b.position);
                return order != 0 ? order : a.bankName.compareTo(b.bankName);
              });
        final counts = <String, int>{};
        for (final member in positive) {
          final rows = await db.rawQuery(newCountSql, [member.bankName]);
          counts[member.bankName] = rows.single['candidate_count'] as int;
        }
        final takes = TrainingAllocation.newQuestionTakes(
            questionLimit: content.questionLimit,
            members: content.members,
            availableNewCounts: counts);
        final selected = <String, String>{};
        for (final member in positive) {
          final take = takes[member.bankName]!;
          if (take == 0) continue;
          final offset = random.nextInt(counts[member.bankName]!);
          final first =
              await db.rawQuery(newWindowSql, [member.bankName, take, offset]);
          final rows = [...first];
          if (rows.length < take) {
            rows.addAll(await db.rawQuery(
                newWindowSql, [member.bankName, take - rows.length, 0]));
          }
          if (rows.length != take) {
            throw const FormatException('Unavailable training window.');
          }
          for (final row in rows) {
            final id = row['id'] as String;
            if (selected.containsKey(id)) {
              throw const FormatException('Duplicate training candidate.');
            }
            selected[id] = member.bankName;
          }
        }
        // Defend the final set even though storage IDs have a single bank owner.
        final ids = selected.keys.toSet().toList()..shuffle(random);
        if (ids.isEmpty) return const TrainingQuestionSelectionEmpty();
        await _admit(db, content);
        final questions = await materializeExactQuestions(db, ids,
            maxIds: 100,
            requireReviewState: true,
            acceptsRow: (row) =>
                row['selected_state'] == 0 &&
                selected[row['id']] == row['bank_name'] &&
                _category(row['selected_folder']) == content.categoryKey);
        return TrainingQuestionSelectionSuccess(questions);
      });

  Future<TrainingQuestionSelectionResult> selectCategoryReview(
          CategoryKey category,
          {required int nowUnixSeconds}) =>
      _read((db) async {
        final banks = <String>[];
        final categoryWhere = switch (category) {
          FolderCategoryKey() => 'b.folder_name = ?',
          UncategorizedCategoryKey() => 'b.bank_name IS NULL',
        };
        final categoryArgs = switch (category) {
          FolderCategoryKey(:final exactFolderName) => <Object?>[
              exactFolderName
            ],
          UncategorizedCategoryKey() => <Object?>[],
        };
        for (final row in await db.rawQuery('''
      SELECT DISTINCT q.bank_name FROM questions q
      LEFT JOIN bank_folders b ON b.bank_name = q.bank_name
      WHERE $categoryWhere AND q.bank_name IS NOT NULL ORDER BY q.bank_name
    ''', categoryArgs)) {
          final bank = row['bank_name'] as String;
          if (await _eligibleInCategory(db, bank, category)) banks.add(bank);
        }
        if (banks.isEmpty) return const TrainingQuestionSelectionEmpty();
        // Admission uses the one eligibility authority. Select due identities
        // only; no TrainingContent data or typed payload is loaded here.
        final rows = <Map<String, Object?>>[];
        // Stay below historical SQLite's bind-variable ceiling. The global
        // top 40 is necessarily within the top 40 of each disjoint bank chunk;
        // keep only that global prefix while merging bounded identity rows.
        for (var start = 0; start < banks.length; start += 400) {
          final chunk = banks.sublist(start, min(start + 400, banks.length));
          final values = chunk.map((_) => '(?)').join(',');
          rows.addAll(await db.rawQuery('''
      WITH eligible_banks(bank_name) AS (VALUES $values)
      SELECT DISTINCT q.id, q.bank_name, r.next_review_time FROM questions q
      JOIN review_states r ON r.question_id = q.id
      JOIN eligible_banks e ON e.bank_name = q.bank_name
      WHERE r.state > 0 AND r.next_review_time <= ?
      ORDER BY r.next_review_time ASC, q.id ASC LIMIT 40
    ''', [...chunk, nowUnixSeconds]));
          if (start > 0 && rows.isNotEmpty) {
            // Let SQLite order the at-most-80 captured identities. Dart's
            // UTF-16 String order differs from SQLite BINARY for some legacy
            // Unicode storage IDs; no question/payload row is read here.
            final ordered = await db.rawQuery('''
              WITH selected(id, bank_name, next_review_time) AS
                (VALUES ${List.filled(rows.length, '(?, ?, ?)').join(',')})
              SELECT id, bank_name, next_review_time FROM selected
              ORDER BY next_review_time ASC, id ASC LIMIT 40
            ''', [
              for (final row in rows) ...[
                row['id'],
                row['bank_name'],
                row['next_review_time'],
              ]
            ]);
            rows
              ..clear()
              ..addAll(ordered);
          }
        }
        final ids = [for (final row in rows) row['id'] as String];
        if (ids.isEmpty) return const TrainingQuestionSelectionEmpty();
        final expectedDue = {
          for (final row in rows) row['id']: row['next_review_time']
        };
        final expectedBank = {
          for (final row in rows) row['id']: row['bank_name']
        };
        final admitted = banks.toSet();
        for (final bank in {
          for (final row in await db.rawQuery(
              'SELECT DISTINCT bank_name FROM questions WHERE id IN (${List.filled(ids.length, '?').join(',')})',
              ids))
            row['bank_name'] as String
        }) {
          if (!await _eligibleInCategory(db, bank, category)) {
            throw const FormatException('Unavailable review bank.');
          }
        }
        final questions = await materializeExactQuestions(db, ids,
            maxIds: 40,
            requireReviewState: true,
            acceptsRow: (row) =>
                row['selected_state'] is int &&
                (row['selected_state'] as int) > 0 &&
                row['selected_due'] is int &&
                (row['selected_due'] as int) <= nowUnixSeconds &&
                row['selected_due'] == expectedDue[row['id']] &&
                admitted.contains(row['bank_name']) &&
                row['bank_name'] == expectedBank[row['id']] &&
                _category(row['selected_folder']) == category);
        return TrainingQuestionSelectionSuccess(questions);
      });
}
