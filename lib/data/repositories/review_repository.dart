import '../../application/study_query/study_query_ports.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';

const _globalWrongBookBankName = '🔥 全局错题本';

/// Bounded result of one SPL-1-U0 selected-ID materialization attempt.
sealed class StudyPlanSessionMaterialization {
  const StudyPlanSessionMaterialization();
}

/// The exact selected storage IDs were materialized in the exact requested
/// order with zero missing or undecodable rows.
final class StudyPlanSessionMaterializationSuccess
    extends StudyPlanSessionMaterialization {
  const StudyPlanSessionMaterializationSuccess(this.questions);

  final List<PersistedQuestion> questions;
}

/// Bounded failure: empty/oversized/duplicate input, a missing selected ID,
/// a corrupt/unsafe typed sidecar, or a database failure. Carries no SQL,
/// paths, or raw causes. Zero partial results are ever produced.
final class StudyPlanSessionMaterializationUnavailable
    extends StudyPlanSessionMaterialization {
  const StudyPlanSessionMaterializationUnavailable();
}

class ReviewRepository implements StudyMetricsQueryPort {
  ReviewRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ReviewRepository instance = ReviewRepository();

  final DatabaseHelper _databaseHelper;
  static const QuestionV2PersistenceMapper _mapper =
      QuestionV2PersistenceMapper();

  /// SPL-1-U0 materialization bound: a selected StudyPlan session is capped
  /// at `ActiveStudyPlan.dailyTarget` (max 200) distinct storage IDs.
  static const int _maxStudyPlanSessionIds = 200;

  Future<Database> get _db async => await _databaseHelper.database;

  Future<List<Map<String, dynamic>>> fetchDueQuestions({
    String? bankName,
    int? type,
    int limit = 50,
    required int nowUnixSeconds,
  }) async {
    final db = await _db;

    // 1. 构建基础过滤条件
    String baseWhere = '1=1';
    List<dynamic> baseArgs = [];
    if (bankName != null && bankName.isNotEmpty) {
      baseWhere += ' AND q.bank_name = ?';
      baseArgs.add(bankName);
    }
    if (type != null) {
      if (type == 0) {
        baseWhere += ' AND q.type IN (0, 1)';
      } else {
        baseWhere += ' AND q.type = ?';
        baseArgs.add(type);
      }
    }

    // 2. 优先拉取到期题目
    String dueQuery = '''
      SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time, r.last_lapse_time
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE $baseWhere AND r.next_review_time <= ?
      ORDER BY r.next_review_time ASC
      LIMIT ?
    ''';
    List<dynamic> dueArgs = [...baseArgs, nowUnixSeconds, limit];
    List<Map<String, dynamic>> results =
        List<Map<String, dynamic>>.from(await db.rawQuery(dueQuery, dueArgs));

    // 3. 降级兜底：如果到期题目不足 limit，拉取未到期题或新题补足队列
    if (results.length < limit) {
      int remain = limit - results.length;
      List<String> existingIds = results.map((e) => e['id'] as String).toList();
      String excludeClause = existingIds.isNotEmpty
          ? 'AND q.id NOT IN (${List.filled(existingIds.length, '?').join(',')})'
          : '';

      String fallbackQuery = '''
        SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time, r.last_lapse_time
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE $baseWhere $excludeClause
        ORDER BY r.next_review_time ASC
        LIMIT ?
      ''';
      List<dynamic> fallbackArgs = [...baseArgs];
      if (existingIds.isNotEmpty) fallbackArgs.addAll(existingIds);
      fallbackArgs.add(remain);

      List<Map<String, dynamic>> fallbackResults =
          await db.rawQuery(fallbackQuery, fallbackArgs);
      results.addAll(fallbackResults);
    }

    return results;
  }

  Future<Map<String, int>> getDashboardData(int now, int todayStart) async {
    final db = await _db;

    final rows = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM questions) AS question_count,
        (SELECT COUNT(*) FROM review_states WHERE state = 3) AS mastered_count,
        (SELECT COUNT(*) FROM review_states WHERE next_review_time <= ?) AS review_due,
        (SELECT COUNT(*) FROM review_logs WHERE review_time >= ?) AS today_practice,
        (
          SELECT COUNT(DISTINCT q.id)
          FROM questions q
          LEFT JOIN review_states r ON q.id = r.question_id
          WHERE (
            EXISTS (
              SELECT 1 FROM answer_attempts aa
              WHERE aa.question_id = q.id AND aa.correctness = 0
            )
            OR (r.lapses IS NOT NULL AND r.lapses > 0)
          )
        ) AS wrong_count
    ''', [now, todayStart]);

    final row = rows.first;

    return <String, int>{
      'questionCount': row['question_count'] as int? ?? 0,
      'masteredCount': row['mastered_count'] as int? ?? 0,
      'reviewDue': row['review_due'] as int? ?? 0,
      'todayPractice': row['today_practice'] as int? ?? 0,
      'wrongCount': row['wrong_count'] as int? ?? 0,
    };
  }

  Future<void> clearAllData() async {
    final db = await _db;
    await db.delete('answer_attempts');
    await db.delete('review_states');
    await db.delete('review_logs');
    await db.delete('questions');
  }

  Future<List<Map<String, dynamic>>> getQuestionBankStats(int nowUnix) async {
    final db = await _db;
    return db.rawQuery('''
      SELECT
        q.bank_name,
        COUNT(*) AS total_count,
        SUM(CASE WHEN rs.next_review_time <= ? THEN 1 ELSE 0 END) AS due_count
      FROM questions q
      LEFT JOIN review_states rs ON q.id = rs.question_id
      GROUP BY q.bank_name
      ORDER BY q.bank_name
    ''', [nowUnix]);
  }

  Future<Map<String, dynamic>> getBankStats(
      String bankName, int nowUnix) async {
    final db = await _db;

    if (bankName == _globalWrongBookBankName) {
      final res = await db.rawQuery('''
        SELECT COUNT(DISTINCT q.id) as total,
               SUM(CASE WHEN r.next_review_time <= ? THEN 1 ELSE 0 END) as review_count,
               SUM(CASE WHEN r.state = 3 THEN 1 ELSE 0 END) as mastered_count
        FROM questions q
        LEFT JOIN review_states r ON q.id = r.question_id
        WHERE (
          EXISTS (
            SELECT 1 FROM answer_attempts aa
            WHERE aa.question_id = q.id AND aa.correctness = 0
          )
          OR (r.lapses IS NOT NULL AND r.lapses > 0)
        )
      ''', [nowUnix]);

      final total = (res.first['total'] as int?) ?? 0;
      final reviewCount = (res.first['review_count'] as int?) ?? 0;
      final masteredCount = (res.first['mastered_count'] as int?) ?? 0;
      final scheduledCount = total - reviewCount - masteredCount;

      return {
        'total': total,
        'new_count': 0,
        'review_count': reviewCount,
        'mastered_count': masteredCount,
        'scheduled_count': scheduledCount > 0 ? scheduledCount : 0,
      };
    }

    final totalRes = await db.rawQuery(
        'SELECT COUNT(id) as count FROM questions WHERE bank_name = ?',
        [bankName]);
    final total = (totalRes.first['count'] as int?) ?? 0;

    final newRes = await db.rawQuery('''
      SELECT COUNT(q.id) as count
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE q.bank_name = ? AND r.state = 0
    ''', [bankName]);
    final newCount = (newRes.first['count'] as int?) ?? 0;

    final reviewRes = await db.rawQuery('''
      SELECT COUNT(q.id) as count
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE q.bank_name = ? AND r.state > 0 AND r.next_review_time <= ?
    ''', [bankName, nowUnix]);
    final dueReviewCount = (reviewRes.first['count'] as int?) ?? 0;

    final masteredRes = await db.rawQuery('''
      SELECT COUNT(q.id) as count
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE q.bank_name = ? AND r.state = 3
    ''', [bankName]);
    final masteredCount = (masteredRes.first['count'] as int?) ?? 0;

    final scheduledCount = total - newCount - dueReviewCount - masteredCount;

    return {
      'total': total,
      'new_count': newCount,
      'review_count': dueReviewCount,
      'mastered_count': masteredCount,
      'scheduled_count': scheduledCount > 0 ? scheduledCount : 0,
    };
  }

  Future<List<int>> getFutureReviewTimestamps({
    required String bankName,
    required int startUnixSeconds,
    required int endUnixSeconds,
  }) async {
    final db = await _db;

    if (bankName == _globalWrongBookBankName) {
      final res = await db.rawQuery('''
        SELECT r.next_review_time
        FROM review_states r
        JOIN questions q ON q.id = r.question_id
        WHERE (
          EXISTS (
            SELECT 1 FROM answer_attempts aa
            WHERE aa.question_id = q.id AND aa.correctness = 0
          )
          OR r.lapses > 0
        )
          AND r.state > 0
          AND r.next_review_time >= ?
          AND r.next_review_time < ?
      ''', [startUnixSeconds, endUnixSeconds]);
      return res.map((e) => (e['next_review_time'] as int?) ?? 0).toList();
    }

    final res = await db.rawQuery('''
      SELECT r.next_review_time
      FROM review_states r
      JOIN questions q ON q.id = r.question_id
      WHERE q.bank_name = ?
        AND r.state > 0
        AND r.next_review_time >= ?
        AND r.next_review_time < ?
    ''', [bankName, startUnixSeconds, endUnixSeconds]);

    return res.map((e) => (e['next_review_time'] as int?) ?? 0).toList();
  }

  Future<int> getGlobalLapseCount() async {
    final db = await _db;
    final lapseRes = await db.rawQuery('''
      SELECT COUNT(DISTINCT q.id) as count
      FROM questions q
      LEFT JOIN review_states r ON q.id = r.question_id
      WHERE (
        EXISTS (
          SELECT 1 FROM answer_attempts aa
          WHERE aa.question_id = q.id AND aa.correctness = 0
        )
        OR (r.lapses IS NOT NULL AND r.lapses > 0)
      )
    ''');
    return (lapseRes.first['count'] as num?)?.toInt() ?? 0;
  }

  // ---------------------------------------------------------------------------
  // T0 read-only study metrics seam (additive)
  //
  // These read APIs back the application study query layer and are purely
  // additive. Failures cross the boundary as a safe
  // [StudyQueryRepositoryException]; no SQL, path, or raw cause is exposed.
  // ---------------------------------------------------------------------------

  @override
  Future<StudyOverviewCounts> getStudyOverviewCounts({
    String? bankName,
    required int nowUnixSeconds,
    required int todayStartUnixSeconds,
  }) async {
    final rows = await _metricsQueryRows((db) {
      return db.rawQuery(
        '''
        SELECT
          COUNT(DISTINCT q.id) AS question_count,
          COUNT(DISTINCT CASE WHEN rs.state = 3 THEN q.id END) AS mastered_count,
          COUNT(DISTINCT CASE WHEN rs.next_review_time <= ? THEN q.id END) AS due_count,
          COUNT(DISTINCT CASE WHEN rl.review_time >= ? THEN q.id END) AS today_practice_count,
          COUNT(DISTINCT CASE WHEN (
            EXISTS (
              SELECT 1 FROM answer_attempts aa
              WHERE aa.question_id = q.id AND aa.correctness = 0
            )
            OR (rs.lapses IS NOT NULL AND rs.lapses > 0)
          ) THEN q.id END) AS wrong_count
        FROM questions q
        LEFT JOIN review_states rs ON rs.question_id = q.id
        LEFT JOIN review_logs rl ON rl.question_id = q.id
        WHERE (? IS NULL OR q.bank_name = ?)
      ''',
        <Object?>[nowUnixSeconds, todayStartUnixSeconds, bankName, bankName],
      );
    });
    final row = rows.single;
    return StudyOverviewCounts(
      questionCount: (row['question_count'] as num?)?.toInt() ?? 0,
      masteredCount: (row['mastered_count'] as num?)?.toInt() ?? 0,
      dueCount: (row['due_count'] as num?)?.toInt() ?? 0,
      todayPracticeCount: (row['today_practice_count'] as num?)?.toInt() ?? 0,
      wrongQuestionCount: (row['wrong_count'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<List<int>> getStudyScheduledReviewTimestamps({
    String? bankName,
    required int fromUnixSeconds,
    required int toUnixSeconds,
  }) async {
    final rows = await _metricsQueryRows((db) {
      final whereParts = <String>[
        'rs.state > 0',
        'rs.next_review_time IS NOT NULL',
        'rs.next_review_time >= ?',
        'rs.next_review_time < ?',
      ];
      final args = <Object?>[fromUnixSeconds, toUnixSeconds];
      if (bankName != null) {
        whereParts.add('q.bank_name = ?');
        args.add(bankName);
      }
      return db.rawQuery('''
        SELECT rs.next_review_time
        FROM review_states rs
        JOIN questions q ON q.id = rs.question_id
        WHERE ${whereParts.join(' AND ')}
        ORDER BY rs.next_review_time ASC
      ''', args);
    });
    return <int>[
      for (final row in rows) (row['next_review_time'] as num?)?.toInt() ?? 0,
    ];
  }

  @override
  Future<int> countStudyDueNow({
    String? bankName,
    required int nowUnixSeconds,
  }) async {
    final rows = await _metricsQueryRows((db) {
      final whereParts = <String>['rs.next_review_time <= ?'];
      final args = <Object?>[nowUnixSeconds];
      if (bankName != null) {
        whereParts.add('q.bank_name = ?');
        args.add(bankName);
      }
      return db.rawQuery('''
        SELECT COUNT(*) AS c
        FROM review_states rs
        JOIN questions q ON q.id = rs.question_id
        WHERE ${whereParts.join(' AND ')}
      ''', args);
    });
    return (rows.single['c'] as num?)?.toInt() ?? 0;
  }

  /// Runs one metrics query with the fixed boundary failure mapping.
  Future<List<Map<String, Object?>>> _metricsQueryRows(
    Future<List<Map<String, Object?>>> Function(Database db) query,
  ) async {
    try {
      final db = await _db;
      return await query(db);
    } on StudyQueryRepositoryException {
      rethrow;
    } on DatabaseRuntimeException {
      throw const StudyQueryRepositoryException(
        StudyQueryRepositoryFailure.unavailable,
      );
    } on DatabaseException {
      throw const StudyQueryRepositoryException(
        StudyQueryRepositoryFailure.unavailable,
      );
    }
  }

  Future<List<String>> getAllDistinctBankNames() async {
    final db = await _db;
    final res = await db.rawQuery('SELECT DISTINCT bank_name FROM questions');
    return res.map((e) => e['bank_name'] as String).toList();
  }

  Future<Map<String, String>> getAllBankFolders() async {
    final db = await _db;
    final List<Map<String, dynamic>> mappings = await db.query('bank_folders');
    return {
      for (var item in mappings)
        item['bank_name'] as String: item['folder_name'] as String
    };
  }

  /// Typed-authority study-session read: same selection semantics as the
  /// retired raw-map session read (new/due selection, type filter, limit, and
  /// ordering stay in SQL), but every row is union-decoded through the V2
  /// sidecar. Typed rows carry their draft as the fact source; wholly legacy
  /// rows decode as [LegacyPersistedQuestion]. Any corrupt, partial, or
  /// unsafe sidecar fails the whole session read without V1 fallback.
  Future<List<PersistedQuestion>> getPersistedStudySessionQuestions(
    String bankName,
    int nowUnix, {
    int? type,
    int limit = 40,
  }) async {
    final db = await _db;
    String typeCondition = "";
    List<dynamic> args = [];

    if (type != null) {
      if (type == 0) {
        typeCondition = " AND q.type IN (0, 1)";
      } else {
        typeCondition = " AND q.type = ?";
        args.add(type);
      }
    }

    final String payloadColumns = '''
      p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
      p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
    ''';

    final List<Map<String, Object?>> rows;
    if (bankName == _globalWrongBookBankName) {
      rows = await db.rawQuery('''
        SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time,
               $payloadColumns
        FROM questions q
        LEFT JOIN review_states r ON q.id = r.question_id
        LEFT JOIN question_v2_payloads p ON q.id = p.question_id
        WHERE (
          EXISTS (
            SELECT 1 FROM answer_attempts aa
            WHERE aa.question_id = q.id AND aa.correctness = 0
          )
          OR (r.lapses IS NOT NULL AND r.lapses > 0)
        )
        AND (r.state IS NULL OR r.state = 0 OR r.next_review_time <= ?) $typeCondition
        ORDER BY COALESCE(r.next_review_time, 0) ASC
        LIMIT ?
      ''', <Object?>[nowUnix, ...args, limit]);
    } else {
      rows = await db.rawQuery('''
        SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time,
               $payloadColumns
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        LEFT JOIN question_v2_payloads p ON q.id = p.question_id
        WHERE q.bank_name = ? AND (r.state = 0 OR r.next_review_time <= ?) $typeCondition
        ORDER BY r.state DESC, r.next_review_time ASC
        LIMIT ?
      ''', <Object?>[bankName, nowUnix, ...args, limit]);
    }

    return rows.map(_mapper.decodeJoinedRow).toList(growable: false);
  }

  /// Narrow SPL-1-U0 selected-ID materialization.
  ///
  /// Loads the exact selected storage IDs (max 200, no duplicates) with their
  /// V2 sidecars and union-decodes every row through the same typed/legacy
  /// authority as [getPersistedStudySessionQuestions]. The returned list is
  /// reconstructed in the exact input-ID order: SQL `IN (...)` row order is
  /// never authoritative. Any missing ID, corrupt/partial/unsafe sidecar, or
  /// database failure fails the WHOLE preparation boundedly with zero partial
  /// queue; there is no silent V1 fallback and no replacement selection.
  Future<StudyPlanSessionMaterialization> materializeStudyPlanSession(
    List<String> storageIds,
  ) async {
    if (storageIds.isEmpty ||
        storageIds.length > _maxStudyPlanSessionIds ||
        storageIds.toSet().length != storageIds.length) {
      return const StudyPlanSessionMaterializationUnavailable();
    }
    try {
      final db = await _db;
      final placeholders = List.filled(storageIds.length, '?').join(',');
      final payloadColumns = '''
        p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
        p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      ''';
      final rows = await db.rawQuery('''
        SELECT q.*, $payloadColumns
        FROM questions q
        LEFT JOIN question_v2_payloads p ON q.id = p.question_id
        WHERE q.id IN ($placeholders)
      ''', storageIds);

      final byId = <String, PersistedQuestion>{};
      try {
        for (final row in rows) {
          final decoded = _mapper.decodeJoinedRow(row);
          byId[decoded.storageId] = decoded;
        }
      } on QuestionV2PayloadException {
        return const StudyPlanSessionMaterializationUnavailable();
      }

      final ordered = <PersistedQuestion>[];
      for (final storageId in storageIds) {
        final decoded = byId[storageId];
        if (decoded == null) {
          return const StudyPlanSessionMaterializationUnavailable();
        }
        ordered.add(decoded);
      }
      return StudyPlanSessionMaterializationSuccess(ordered);
    } on DatabaseRuntimeException {
      return const StudyPlanSessionMaterializationUnavailable();
    } on DatabaseException {
      return const StudyPlanSessionMaterializationUnavailable();
    }
  }

  // 暴露给事务的核心读写逻辑
  Future<void> applyReviewStatesTxn(
    DatabaseExecutor txn,
    List<String> questionIds,
    Map<String, Map<String, dynamic>> newStateMap,
    Map<String, Map<String, dynamic>> logMap,
  ) async {
    // 1. Fetch current states
    final placeholders = List.filled(questionIds.length, '?').join(',');
    final reviewStateRows = await txn.rawQuery(
      'SELECT * FROM review_states WHERE question_id IN ($placeholders)',
      questionIds,
    );
    final existingStateMap = <String, Map<String, dynamic>>{};
    for (final r in reviewStateRows) {
      existingStateMap[r['question_id'].toString()] = r;
    }

    // Caller will need original questions for variant generation
    // So we just return the full rows?
    // Actually, to keep it clean, maybe we let the caller pass the complete evaluated states.
    // Let's refactor this: The Service calculates the states, and Repository just saves them.
  }

  // Revised approach:
  Future<Map<String, Map<String, dynamic>>> fetchReviewStates(
      List<String> questionIds) async {
    final db = await _db;
    final placeholders = List.filled(questionIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM review_states WHERE question_id IN ($placeholders)',
      questionIds,
    );
    return {for (var r in rows) r['question_id'].toString(): r};
  }

  Future<Map<String, Map<String, dynamic>>> fetchQuestions(
      List<String> questionIds) async {
    final db = await _db;
    final placeholders = List.filled(questionIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM questions WHERE id IN ($placeholders)',
      questionIds,
    );
    return {for (var r in rows) r['id'].toString(): r};
  }

  Future<void> updateReviewStatesAndLogs(
    List<Map<String, dynamic>> statesToInsert,
    List<Map<String, dynamic>> statesToUpdate,
    List<Map<String, dynamic>> logsToInsert,
  ) async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final state in statesToInsert) {
        await txn.insert('review_states', state);
      }
      for (final state in statesToUpdate) {
        await txn.update(
          'review_states',
          state,
          where: 'question_id = ?',
          whereArgs: [state['question_id']],
        );
      }
      for (final log in logsToInsert) {
        await txn.insert('review_logs', log);
      }
    });
  }
}
