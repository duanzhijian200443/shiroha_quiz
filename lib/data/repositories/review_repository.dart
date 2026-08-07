import 'package:sqflite/sqflite.dart';
import '../../core/database/database_helper.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';

const _globalWrongBookBankName = '🔥 全局错题本';

class ReviewRepository {
  ReviewRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ReviewRepository instance = ReviewRepository();

  final DatabaseHelper _databaseHelper;
  static const QuestionV2PersistenceMapper _mapper =
      QuestionV2PersistenceMapper();

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
        (SELECT COUNT(*) FROM review_states WHERE lapses > 0) AS wrong_count
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
        SELECT COUNT(q.id) as total,
               SUM(CASE WHEN r.next_review_time <= ? THEN 1 ELSE 0 END) as review_count,
               SUM(CASE WHEN r.state = 3 THEN 1 ELSE 0 END) as mastered_count
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE r.lapses > 0
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
        WHERE r.lapses > 0
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
    final lapseRes = await db.rawQuery(
        'SELECT COUNT(question_id) as count FROM review_states WHERE lapses > 0');
    return (lapseRes.first['count'] as int?) ?? 0;
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
        JOIN review_states r ON q.id = r.question_id
        LEFT JOIN question_v2_payloads p ON q.id = p.question_id
        WHERE r.lapses > 0 AND r.next_review_time <= ? $typeCondition
        ORDER BY r.next_review_time ASC
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
