import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/services/llm_service.dart';
import 'package:uuid/uuid.dart';

import 'database/database_helper.dart';

const _uuid = Uuid();

// ================================================================
//  FSRS-Lite 算法核心（64-bit Double 精度）
// ================================================================

class FsrsState {
  final double difficulty;
  final double stability;
  final int state;
  final int reps;
  final int lapses;

  const FsrsState({
    required this.difficulty,
    required this.stability,
    required this.state,
    required this.reps,
    required this.lapses,
  });

  static const FsrsState defaults = FsrsState(
    difficulty: 5.0,
    stability: 0.0,
    state: 0,
    reps: 0,
    lapses: 0,
  );
}

class FsrsResult {
  final double nextD;
  final double nextS;
  final int intervalDays;
  final int nextState;

  const FsrsResult({
    required this.nextD,
    required this.nextS,
    required this.intervalDays,
    required this.nextState,
  });
}

FsrsResult calculateNextState(int grade, FsrsState prev) {
  final nextD = (prev.difficulty - (grade - 2) * 0.8).clamp(1.0, 10.0);

  double nextS;
  if (grade < 2) {
    nextS = (prev.stability * 0.2).clamp(0.5, double.infinity);
  } else {
    if (prev.state == 0 || prev.state == 1) {
      nextS = (grade == 4) ? 4.0 : (grade == 3 ? 2.0 : 1.0);
    } else {
      final factor = math.exp(0.1 * (10 - nextD)) *
          (grade == 4 ? 1.5 : (grade == 3 ? 1.0 : 0.8));
      nextS = prev.stability * factor;
    }
  }

  final intervalDays = nextS.clamp(0, 3650.0).round();

  int nextState;
  if (grade < 2) {
    nextState = 1;
  } else if (prev.state <= 1) {
    nextState = 2;
  } else if (prev.stability > 30) {
    nextState = 3;
  } else {
    nextState = prev.state;
  }

  return FsrsResult(
    nextD: nextD,
    nextS: nextS,
    intervalDays: intervalDays,
    nextState: nextState,
  );
}

// ================================================================
//  TimeUtil
// ================================================================

class TimeUtil {
  TimeUtil._();
  static int getRealUTCTimestamp() {
    return DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  }
}

// ================================================================
//  写队列条目
// ================================================================

class _PendingWrite {
  final String questionId;
  final int grade;
  final int durationMs;
  final String? userAnswer;
  final String? aiEvaluation;
  _PendingWrite(this.questionId, this.grade, this.durationMs, this.userAnswer, this.aiEvaluation);
}

// ================================================================
//  ReviewEngineService — 批量写 + 生命周期感知
// ================================================================

class ReviewEngineService with WidgetsBindingObserver {
  static final ReviewEngineService _instance = ReviewEngineService._();
  factory ReviewEngineService() => _instance;
  ReviewEngineService._() {
    WidgetsBinding.instance.addObserver(this);
  }

  final List<_PendingWrite> _queue = [];
  Timer? _debounceTimer;
  bool _flushing = false;

  // 双端队列调度器 (O(1) 内存会话)
  Queue<Map<String, dynamic>>? _sessionQueue;

  static const int _batchSize = 5;
  static const Duration _debounceWindow = Duration(milliseconds: 800);

  Future<Database> get _db async => await DatabaseHelper.instance.database;

  // ---- 生命周期：App 切后台时自动刷盘 ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      flushPending();
    }
  }



  // ================================================================
  //  公开 API
  // ================================================================


    Future<List<Map<String, dynamic>>> fetchDueQuestions({
      String? bankName,
      int? type,
      int limit = 50,
    }) async {
      final db = await DatabaseHelper.instance.database;
      final nowUnixSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      
      // 1. 构建基础过滤条件
      String baseWhere = '1=1';
      List<dynamic> baseArgs = [];
      if (bankName != null && bankName.isNotEmpty) {
        baseWhere += ' AND q.bank_name = ?';
        baseArgs.add(bankName);
      }
      if (type != null) {
        if (type == 0) {
          // 0 代表选择题大类，同时兼容单选(0)和多选(1)
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
      List<Map<String, dynamic>> results = List<Map<String, dynamic>>.from(await db.rawQuery(dueQuery, dueArgs));

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
        
        List<Map<String, dynamic>> fallbackResults = await db.rawQuery(fallbackQuery, fallbackArgs);
        results.addAll(fallbackResults);
      }
      
      return results;
    }


  Future<void> submitReviewResult(
    String questionId,
    int grade,
    int durationMs, {
    String? userAnswer,
    String? aiEvaluation,
  }) async {
    _queue.add(_PendingWrite(questionId, grade, durationMs, userAnswer, aiEvaluation));

    if (_queue.length >= _batchSize) {
      _debounceTimer?.cancel();
      await _flushNow();
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, () {
      if (_queue.isNotEmpty) _flushNow();
    });
  }

  Future<void> flushPending() async {
    _debounceTimer?.cancel();
    if (_queue.isNotEmpty) await _flushNow();
  }

  Future<Map<String, int>> getDashboardData() async {
    final db = await _db;
    final int now = DateTime.now().millisecondsSinceEpoch;

    final int todayStart = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    ).millisecondsSinceEpoch;

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

  Future<List<Map<String, dynamic>>> getDetailedWrongQuestions() async {
    final db = await _db;
    return db.rawQuery('''
      SELECT 
        q.id, 
        q.type, 
        q.content, 
        q.options, 
        q.standard_answer, 
        q.bank_name,
        rs.lapses, 
        rs.difficulty, 
        rs.stability,
        rs.last_lapse_time
      FROM questions q
      INNER JOIN review_states rs ON q.id = rs.question_id
      WHERE rs.lapses > 0
      ORDER BY rs.last_lapse_time DESC;
    ''');
  }

  Future<void> clearAllData() async {
    final db = await _db;
    await db.delete('review_states');
    await db.delete('review_logs');
    await db.delete('questions');
  }

  Future<void> deleteQuestionAndRelatedData(String questionId) async {
    final db = await _db;
    await db.delete('questions', where: 'id = ?', whereArgs: [questionId]);
  }

  Future<List<Map<String, dynamic>>> getQuestionBankStats() async {
    final db = await _db;
    final int now = TimeUtil.getRealUTCTimestamp();
    return db.rawQuery('''
      SELECT
        q.bank_name,
        COUNT(*) AS total_count,
        SUM(CASE WHEN rs.next_review_time <= ? THEN 1 ELSE 0 END) AS due_count
      FROM questions q
      LEFT JOIN review_states rs ON q.id = rs.question_id
      GROUP BY q.bank_name
      ORDER BY q.bank_name
    ''', [now]);
  }

  Future<Map<String, int>> getBankStats(String bankName) async {
    final db = await DatabaseHelper.instance.database;
    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 核心拦截：虚空错题本大盘计算
    if (bankName == '🔥 全局错题本') {
      final res = await db.rawQuery('''
        SELECT COUNT(q.id) as total,
               SUM(CASE WHEN r.next_review_time <= ? THEN 1 ELSE 0 END) as review_count
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE r.lapses > 0
      ''', [nowUnix]);
      
      final total = (res.first['total'] as int?) ?? 0;
      final reviewCount = (res.first['review_count'] as int?) ?? 0;
      
      return {
        'total': total,
        'new_count': 0, // 错题本没有新题
        'review_count': reviewCount,
        'mastered_count': total - reviewCount,
      };
    }

    // 1. 统计该题库总题数
    final totalRes = await db.rawQuery('SELECT COUNT(id) as count FROM questions WHERE bank_name = ?', [bankName]);
    final total = (totalRes.first['count'] as int?) ?? 0;

    // 2. 统计新题数量 (state = 0: New)
    final newRes = await db.rawQuery('''
      SELECT COUNT(q.id) as count 
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE q.bank_name = ? AND r.state = 0
    ''', [bankName]);
    final newCount = (newRes.first['count'] as int?) ?? 0;

    // 3. 统计待复习数量 (state > 0 且 next_review_time <= 当前时间)
    final reviewRes = await db.rawQuery('''
      SELECT COUNT(q.id) as count 
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE q.bank_name = ? AND r.state > 0 AND r.next_review_time <= ?
    ''', [bankName, nowUnix]);
    final reviewCount = (reviewRes.first['count'] as int?) ?? 0;

    // 4. 统计已掌握数量 (非新题，且未到期的题)
    final masteredCount = total - newCount - reviewCount;

    return {
      'total': total,
      'new_count': newCount,
      'review_count': reviewCount,
      'mastered_count': masteredCount > 0 ? masteredCount : 0,
    };
  }

  Future<List<Map<String, dynamic>>> getAllBankStats() async {
    final db = await DatabaseHelper.instance.database;
    List<Map<String, dynamic>> allStats = [];

    // 核心注入：动态生成虚拟错题本卡片
    final lapseRes = await db.rawQuery('SELECT COUNT(question_id) as count FROM review_states WHERE lapses > 0');
    final lapseCount = (lapseRes.first['count'] as int?) ?? 0;
    if (lapseCount > 0) {
      final stats = await getBankStats('🔥 全局错题本');
      allStats.add({
        'bank_name': '🔥 全局错题本',
        'folder_name': '🚨 重点突破', // 专属高亮学科文件夹
        'total': stats['total'],
        'mastered': stats['mastered_count'],
        'daily_quota': 40,
        'days_left': ((stats['total']! - stats['mastered_count']!) / 40).ceil(),
      });
    }

    final res = await db.rawQuery('SELECT DISTINCT bank_name FROM questions');
    
    // 一次性获取所有题库的文件夹映射关系
    final List<Map<String, dynamic>> mappings = await db.query('bank_folders');
    final Map<String, String> folderMap = {
      for (var item in mappings) item['bank_name'] as String: item['folder_name'] as String
    };

    for (var row in res) {
      String bName = row['bank_name'] as String;
      final stats = await getBankStats(bName);
      
      final quotaStr = await DatabaseHelper.instance.getSetting('${bName}_daily_quota');
      final quota = int.tryParse(quotaStr ?? '40') ?? 40;
      
      final unmastered = (stats['total'] ?? 0) - (stats['mastered_count'] ?? 0);
      final daysLeft = (unmastered / quota).ceil();

      allStats.add({
        'bank_name': bName,
        'folder_name': folderMap[bName] ?? '📁 未分类题库', // 核心注入：文件夹名称
        'total': stats['total'],
        'mastered': stats['mastered_count'],
        'daily_quota': quota,
        'days_left': daysLeft,
      });
    }
    return allStats;
  }

  Future<void> deleteQuestionBank(String bankName) async {
    final db = await _db;
    await db.delete('questions', where: 'bank_name = ?', whereArgs: [bankName]);
  }

  // ================================================================
  //  FSRS 核心数学引擎
  // ================================================================

  // Grade: 1=重来(Again), 2=困难(Hard), 3=顺利(Good), 4=极易(Easy)
  Map<String, dynamic> _calculateFSRS(Map<String, dynamic> currentState, int grade) {
    double d = (currentState['difficulty'] as num?)?.toDouble() ?? 5.0;
    double s = (currentState['stability'] as num?)?.toDouble() ?? 0.0;
    int reps = (currentState['reps'] as int?) ?? 0;
    int lapses = (currentState['lapses'] as int?) ?? 0;
    int lastReview = (currentState['last_review_time'] as int?) ?? 0;

    final int nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int actualElapsed = lastReview == 0 ? 0 : (nowUnix - lastReview) ~/ 86400;

    // 1. 难度 D 的动态演进 (界于 1.0 - 10.0)
    double dNew = d - (grade - 3) * 0.8;
    dNew = math.max(1.0, math.min(10.0, dNew));

    // 2. 稳定性 S 的计算
    double sNew;
    if (reps == 0) {
      sNew = grade == 1 ? 1.0 : (grade == 2 ? 2.0 : (grade == 3 ? 3.0 : 5.0));
    } else {
      if (grade == 1) {
        sNew = math.max(1.0, s * math.exp(-0.3 * dNew));
        lapses++;
      } else {
        double gradeMultiplier = grade == 2 ? 0.8 : (grade == 3 ? 1.0 : 1.3);
        double factor = math.exp(0.1 * (10 - dNew)) * gradeMultiplier;
        double timeRatio = s == 0 ? 1.0 : math.min(actualElapsed / s, 2.0);
        sNew = s * (1 + (factor - 1) * timeRatio);
      }
    }

    // 3. 计算下一次复习时间戳 (Unix 秒)
    int nextIntervalDays = (sNew * 1.5).round();
    if (grade == 1) nextIntervalDays = 0;
    int nextReviewTime = nowUnix + (nextIntervalDays * 86400);

    return {
      'state': grade == 1 ? 1 : 2,
      'difficulty': dNew,
      'stability': sNew,
      'last_review_time': nowUnix,
      'next_review_time': nextReviewTime,
      'reps': reps + 1,
      'lapses': lapses,
      'last_lapse_time': grade == 1 ? nowUnix : currentState['last_lapse_time'],
    };
  }

  // ================================================================
  //  评级提交 (事务安全)
  // ================================================================

  Future<void> submitReview(String questionId, int grade) async {
    final db = await DatabaseHelper.instance.database;

    await db.transaction((txn) async {
      final stateRes = await txn.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: [questionId],
        limit: 1,
      );
      if (stateRes.isEmpty) return;

      final currentState = Map<String, dynamic>.from(stateRes.first);
      final newState = _calculateFSRS(currentState, grade);

      await txn.update(
        'review_states',
        newState,
        where: 'question_id = ?',
        whereArgs: [questionId],
      );

      final safeLen = math.min(8, questionId.length);
      await txn.insert('review_logs', {
        'id': '${DateTime.now().millisecondsSinceEpoch}_${questionId.substring(0, safeLen)}',
        'question_id': questionId,
        'grade': grade,
        'llm_score': 0.0,
        'review_time': newState['last_review_time'],
        'duration_ms': 0,
      });
    });
  }

  // ================================================================
  //  双端队列会话调度器
  // ================================================================

  Future<void> initStudySession(String bankName, {int? type, int limit = 40}) async {
    final db = await DatabaseHelper.instance.database;
    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    
    String typeCondition = "";
    List<dynamic> args = [];
    
    if (type != null) {
      if (type == 0) typeCondition = " AND q.type IN (0, 1)";
      else { typeCondition = " AND q.type = ?"; args.add(type); }
    }

    List<Map<String, dynamic>> rawQuestions;

    // 核心拦截：错题本专属 O(1) 提取队列
    if (bankName == '🔥 全局错题本') {
      args.insert(0, nowUnix); // 错题仅复习到期部分
      args.add(limit);
      rawQuestions = await db.rawQuery('''
        SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time 
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE r.lapses > 0 AND r.next_review_time <= ? $typeCondition
        ORDER BY r.next_review_time ASC
        LIMIT ?
      ''', args);
    } else {
      args.insert(0, bankName);
      args.insert(1, nowUnix);
      args.add(limit);
      rawQuestions = await db.rawQuery('''
        SELECT q.*, r.state, r.difficulty, r.stability, r.reps, r.next_review_time 
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE q.bank_name = ? AND (r.state = 0 OR r.next_review_time <= ?) $typeCondition
        ORDER BY r.state DESC, r.next_review_time ASC
        LIMIT ?
      ''', args);
    }
    
    _sessionQueue = Queue<Map<String, dynamic>>.from(rawQuestions);
  }

  // O(1) 极速弹出一道题
  Map<String, dynamic>? popNextQuestion() {
    if (_sessionQueue == null || _sessionQueue!.isEmpty) return null;
    return _sessionQueue!.removeFirst();
  }

  // O(1) 错题回炉：grade=1(重来)时塞回队尾，本轮必须消灭它
  void requeueQuestion(Map<String, dynamic> question) {
    _sessionQueue?.addLast(question);
  }

  // ================================================================
  //  内部批量写
  // ================================================================

  Future<void> _flushNow() async {
    if (_flushing || _queue.isEmpty) return;
    _flushing = true;

    final batch = List<_PendingWrite>.from(_queue);
    _queue.clear();

    try {
      final db = await _db;
      final int now = TimeUtil.getRealUTCTimestamp();

      await db.transaction((txn) async {
        final ids = batch.map((e) => e.questionId).toList();
        final placeholders = List.filled(ids.length, '?').join(',');
        
        // Fetch both review states and full question objects
        final reviewStateRows = await txn.rawQuery(
          'SELECT * FROM review_states WHERE question_id IN ($placeholders)',
          ids,
        );
        final questionRows = await txn.rawQuery(
          'SELECT * FROM questions WHERE id IN ($placeholders)',
          ids,
        );

        final stateMap = <String, Map<String, dynamic>>{};
        for (final r in reviewStateRows) {
          stateMap[r['question_id'].toString()] = r;
        }

        final questionMap = <String, Question>{};
        for (final r in questionRows) {
          questionMap[r['id'].toString()] = Question.fromMap(r);
        }

        for (final item in batch) {
          final prev = stateMap[item.questionId];
          final FsrsState fsrs = prev != null
              ? FsrsState(
                  difficulty: (prev['difficulty'] as num?)?.toDouble() ?? 5.0,
                  stability: (prev['stability'] as num?)?.toDouble() ?? 0.0,
                  state: (prev['state'] as int?) ?? 0,
                  reps: (prev['reps'] as int?) ?? 0,
                  lapses: (prev['lapses'] as int?) ?? 0,
                )
              : FsrsState.defaults;

          // --- 错题变异触发器 ---
          final originalQuestion = questionMap[item.questionId];
          // isLapse(答错了) == false && grade(评分) >= 3 && currentLapses(之前错过) > 0
          if (item.grade >= 3 && fsrs.lapses > 0 && originalQuestion != null) {
            // Fire and Forget
            LLMService().generateVariantQuestion(originalQuestion);
            print("Variant generation triggered for question ${item.questionId}");
          }
          // --- 触发器结束 ---

          final result = calculateNextState(item.grade, fsrs);
          final int nextReviewTime = now + result.intervalDays * 86400;

          final Map<String, dynamic> stateValues = {
            'question_id': item.questionId,
            'state': result.nextState,
            'difficulty': result.nextD,
            'stability': result.nextS,
            'last_review_time': now,
            'next_review_time': nextReviewTime,
            'reps': fsrs.reps + 1,
            'lapses': item.grade < 2 ? fsrs.lapses + 1 : fsrs.lapses,
            'last_lapse_time': item.grade < 2 ? now : (prev?['last_lapse_time'] ?? 0),
          };

          if (prev == null) {
            await txn.insert('review_states', stateValues);
          } else {
            await txn.update(
              'review_states',
              stateValues,
              where: 'question_id = ?',
              whereArgs: [item.questionId],
            );
          }

          await txn.insert('review_logs', {
            'id': _uuid.v4(),
            'question_id': item.questionId,
            'grade': item.grade,
            'llm_score': null,
            'review_time': now,
            'duration_ms': item.durationMs,
            'user_answer': item.userAnswer,
            'ai_evaluation': item.aiEvaluation,
          });
        }
      });
    } catch (_) {
      _queue.insertAll(0, batch);
      rethrow;
    } finally {
      _flushing = false;
    }
  }
}
