/// Read-only SQLite implementation of the SPL-1 planning and candidate
/// seams.
///
/// Reads only: this repository never writes, never changes settings, and
/// performs no schema mutation (runtime schema is v22, from the additive
/// SPL-1-D1 `study_plans` table). Every query is parameterized; bank names
/// and project ids are never interpolated. Database errors map to the
/// bounded [StudyPlanReadException]; raw causes never escape the Application
/// boundary.
library;

import 'package:sqflite/sqflite.dart';

import '../../application/study_plan/study_plan_ports.dart';
import '../../core/database/database_helper.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/study_plan_values.dart';

class StudyPlanReadRepository
    implements StudyPlanPlanningPort, StudyPlanCandidateQueryPort {
  StudyPlanReadRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final StudyPlanReadRepository instance = StudyPlanReadRepository();

  final DatabaseHelper _databaseHelper;

  /// Frozen candidate read bound. `dailyTarget` is capped at 200 and
  /// selection consumes the ordered pools with mandatory storageId dedup,
  /// so every possible final session of at most 200 distinct candidates is
  /// a prefix of the top-200 of each pool; reading more can never change the
  /// selection. This keeps candidate reads bounded without a full-bank dump.
  static const int maxPerPoolLimit = 200;

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    final trimmed = bankName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Bank name is required.');
    }
    final nowUnixSeconds = now.millisecondsSinceEpoch ~/ 1000;
    try {
      final db = await _databaseHelper.database;
      return await db.transaction((txn) async {
        if (!await _scopeAdmits(txn, sourceScope, trimmed)) {
          return const StudyPlanPlanningUnavailable();
        }
        final countRows = await txn.rawQuery(
          'SELECT COUNT(*) AS c FROM questions WHERE bank_name = ?',
          <Object?>[trimmed],
        );
        if (((countRows.single['c'] as num?)?.toInt() ?? 0) < 1) {
          return const StudyPlanPlanningUnavailable();
        }
        // Canonical aggregate semantics mirror the T0 metrics seam: due is
        // `next_review_time <= now` with no state filter (a `state = 0`
        // row with `next_review_time = 0` is due), mastered is `state = 3`,
        // weak is `lapses > 0`, new is `state = 0`. Overlap is allowed.
        final rows = await txn.rawQuery(
          '''
          SELECT
            COUNT(DISTINCT q.id) AS question_count,
            COUNT(DISTINCT CASE WHEN rs.state = 3 THEN q.id END) AS mastered_count,
            COUNT(DISTINCT CASE WHEN rs.next_review_time <= ? THEN q.id END) AS due_count,
            COUNT(DISTINCT CASE WHEN rs.lapses > 0 THEN q.id END) AS weak_count,
            COUNT(DISTINCT CASE WHEN rs.state = 0 THEN q.id END) AS new_count
          FROM questions q
          LEFT JOIN review_states rs ON rs.question_id = q.id
          WHERE q.bank_name = ?
          ''',
          <Object?>[nowUnixSeconds, trimmed],
        );
        final row = rows.single;
        return StudyPlanPlanningAdmitted(
          StudyPlanPlanningContext(
            bankName: trimmed,
            questionCount: _intOf(row['question_count']),
            masteredCount: _intOf(row['mastered_count']),
            dueCount: _intOf(row['due_count']),
            weakCount: _intOf(row['weak_count']),
            newCount: _intOf(row['new_count']),
          ),
        );
      });
    } on StudyPlanReadException {
      rethrow;
    } on DatabaseRuntimeException {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    } on DatabaseException {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    }
  }

  /// Scope admission: Global admits any target; a Learning Space requires
  /// the current Project and the current `project_banks(projectId,
  /// bankName)` relation. Every denial collapses into the shared
  /// non-enumerating unavailable shape.
  Future<bool> _scopeAdmits(
    DatabaseExecutor txn,
    ConversationScope scope,
    String bankName,
  ) async {
    if (scope.kind == ConversationScopeKind.global) return true;
    final projectId = scope.projectId;
    if (projectId == null) return false;
    final project = await txn.query(
      'projects',
      columns: const <String>['project_id'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      limit: 1,
    );
    if (project.isEmpty) return false;
    final relation = await txn.query(
      'project_banks',
      columns: const <String>['bank_name'],
      where: 'project_id = ? AND bank_name = ?',
      whereArgs: <Object?>[projectId, bankName],
      limit: 1,
    );
    return relation.isNotEmpty;
  }

  @override
  Future<StudyPlanCandidateBatch> loadCandidates({
    required String bankName,
    required int nowUnixSeconds,
    required int maxPerPool,
  }) async {
    final trimmed = bankName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Bank name is required.');
    }
    if (maxPerPool < 1 || maxPerPool > maxPerPoolLimit) {
      throw ArgumentError.value(
        maxPerPool,
        'maxPerPool',
        'Must be between 1 and $maxPerPoolLimit.',
      );
    }
    try {
      final db = await _databaseHelper.database;
      // All three pool reads run inside ONE read-only SQLite transaction so
      // the batch is a single coherent snapshot: no review-state change can
      // be observed between pools. Read-only only; nothing is written.
      return db.transaction((txn) async {
        // Identity/review columns only: no question content, options,
        // answers, explanations, or V2 sidecar payloads are loaded for
        // selection.
        final dueRows = await txn.rawQuery(
          '''
          SELECT q.id AS storage_id, r.state, r.next_review_time, r.lapses,
                 r.difficulty
          FROM questions q
          JOIN review_states r ON r.question_id = q.id
          WHERE q.bank_name = ? AND r.next_review_time <= ?
          ORDER BY r.next_review_time ASC, q.id ASC
          LIMIT ?
          ''',
          <Object?>[trimmed, nowUnixSeconds, maxPerPool],
        );
        final weakRows = await txn.rawQuery(
          '''
          SELECT q.id AS storage_id, r.state, r.next_review_time, r.lapses,
                 r.difficulty
          FROM questions q
          JOIN review_states r ON r.question_id = q.id
          WHERE q.bank_name = ? AND r.lapses > 0
          ORDER BY r.lapses DESC, r.difficulty DESC, q.id ASC
          LIMIT ?
          ''',
          <Object?>[trimmed, maxPerPool],
        );
        final newRows = await txn.rawQuery(
          '''
          SELECT q.id AS storage_id, r.state, r.next_review_time, r.lapses,
                 r.difficulty
          FROM questions q
          JOIN review_states r ON r.question_id = q.id
          WHERE q.bank_name = ? AND r.state = 0
          ORDER BY q.id ASC
          LIMIT ?
          ''',
          <Object?>[trimmed, maxPerPool],
        );
        return StudyPlanCandidateBatch(
          due: <StudyPlanCandidate>[
            for (final row in dueRows) _candidate(row, trimmed, nowUnixSeconds),
          ],
          weak: <StudyPlanCandidate>[
            for (final row in weakRows)
              _candidate(row, trimmed, nowUnixSeconds),
          ],
          newPool: <StudyPlanCandidate>[
            for (final row in newRows) _candidate(row, trimmed, nowUnixSeconds),
          ],
        );
      });
    } on StudyPlanReadException {
      rethrow;
    } on DatabaseRuntimeException {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    } on DatabaseException {
      throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
    }
  }

  StudyPlanCandidate _candidate(
    Map<String, Object?> row,
    String bankName,
    int nowUnixSeconds,
  ) {
    final nextReviewAt = row['next_review_time'] as int?;
    final state = (row['state'] as num?)?.toInt() ?? 0;
    return StudyPlanCandidate(
      storageId: row['storage_id']! as String,
      bankName: bankName,
      due: nextReviewAt != null && nextReviewAt <= nowUnixSeconds,
      nextReviewAt: nextReviewAt,
      lapses: (row['lapses'] as num?)?.toInt() ?? 0,
      difficulty: (row['difficulty'] as num?)?.toDouble() ?? 5.0,
      classification: state == 0
          ? StudyPlanQuestionClassification.newQuestion
          : StudyPlanQuestionClassification.review,
    );
  }

  static int _intOf(Object? value) => (value as num?)?.toInt() ?? 0;
}
