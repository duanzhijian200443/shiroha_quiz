import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/models/review_dashboard_data.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/llm_service.dart';
import 'package:uuid/uuid.dart';

import '../data/models/study_plan_bank_catalog.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';

import 'package:shiroha_quiz/data/repositories/review_repository.dart';

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
  final AiEngineRepository engineRepository;
  _PendingWrite(
    this.questionId,
    this.grade,
    this.durationMs,
    this.userAnswer,
    this.aiEvaluation,
    this.engineRepository, {
    required this.lease,
  });

  final BackupRestoreMutationLease lease;
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
  // Shared completion for the batch currently being flushed. Reset and
  // lifecycle callers must await this future instead of observing only the
  // queue, because the active batch has already been removed from it.
  Future<void>? _activeFlushFuture;

  // 双端队列调度器 (O(1) 内存会话)
  Queue<PersistedQuestion>? _sessionQueue;

  static const int _batchSize = 5;
  static const Duration _debounceWindow = Duration(milliseconds: 800);

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
    final nowUnixSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return ReviewRepository.instance.fetchDueQuestions(
      bankName: bankName,
      type: type,
      limit: limit,
      nowUnixSeconds: nowUnixSeconds,
    );
  }

  Future<void> submitReviewResult(
    String questionId,
    int grade,
    int durationMs, {
    required AiEngineRepository engineRepository,
    String? userAnswer,
    String? aiEvaluation,
  }) {
    final lease = BackupRestoreMutationGate.instance.acquireMutationLease();
    return _submitReviewResultUnchecked(
      questionId,
      grade,
      durationMs,
      lease: lease,
      engineRepository: engineRepository,
      userAnswer: userAnswer,
      aiEvaluation: aiEvaluation,
    );
  }

  Future<void> _submitReviewResultUnchecked(
    String questionId,
    int grade,
    int durationMs, {
    required BackupRestoreMutationLease lease,
    required AiEngineRepository engineRepository,
    String? userAnswer,
    String? aiEvaluation,
  }) async {
    _queue.add(_PendingWrite(
      questionId,
      grade,
      durationMs,
      userAnswer,
      aiEvaluation,
      engineRepository,
      lease: lease,
    ));

    if (_queue.length >= _batchSize) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      await _flushNow();
      return;
    }

    _scheduleDebouncedFlush();
  }

  /// Drains both queued writes and the batch currently in flight.
  Future<void> flushPending() async {
    while (true) {
      _debounceTimer?.cancel();
      _debounceTimer = null;

      final activeFlush = _activeFlushFuture;
      if (activeFlush != null) {
        await activeFlush;
        continue;
      }

      if (_queue.isEmpty) return;
      await _flushNow();
    }
  }

  /// Clears process-lifetime review state after B0 has drained all accepted
  /// durable review writes and the restored database is authoritative.
  void resetTransientStateForRestore() {
    if (_queue.isNotEmpty || _flushing || _activeFlushFuture != null) {
      throw StateError('Review writes must drain before restore reload.');
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _sessionQueue = null;
  }

  Future<Map<String, int>> getDashboardData() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int todayStart = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    ).millisecondsSinceEpoch;

    return ReviewRepository.instance.getDashboardData(now, todayStart);
  }

  Future<void> clearAllData() {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      // A review submission may already have acquired its lease while its
      // debounced write is still only queued. Drain that accepted write before
      // publishing the destructive clear-all transaction.
      await flushPending();
      await ReviewRepository.instance.clearAllData();
    });
  }

  /// D1D targeted reset: restore one question's mutable ReviewState
  /// scheduling values without clearing either review or answer history.
  Future<void> resetReviewState(String questionId) {
    return BackupRestoreMutationGate.instance.runMutation(
      () async {
        await flushPending();
        await ReviewRepository.instance.resetReviewState(questionId);
      },
    );
  }

  Future<List<Map<String, dynamic>>> getQuestionBankStats() {
    final int now = TimeUtil.getRealUTCTimestamp();
    return ReviewRepository.instance.getQuestionBankStats(now);
  }

  Future<Map<String, dynamic>> getBankStats(String bankName) {
    final int nowUnix = TimeUtil.getRealUTCTimestamp();
    return ReviewRepository.instance.getBankStats(bankName, nowUnix);
  }

  Future<ReviewDashboardData> getReviewDashboardData(String bankName,
      {int days = 7, bool includeToday = true}) async {
    final stats = await getBankStats(bankName);

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final startWindow =
        includeToday ? todayStart : todayStart.add(const Duration(days: 1));
    final endWindow = startWindow.add(Duration(days: days));

    final startUnix = startWindow.millisecondsSinceEpoch ~/ 1000;
    final endUnix = endWindow.millisecondsSinceEpoch ~/ 1000;

    final timestamps =
        await ReviewRepository.instance.getFutureReviewTimestamps(
      bankName: bankName,
      startUnixSeconds: startUnix,
      endUnixSeconds: endUnix,
    );

    // Group by day (using local timezone boundaries)
    final Map<int, int> dayCounts = {};
    for (int i = 0; i < days; i++) {
      dayCounts[i] = 0;
    }

    for (final ts in timestamps) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final diff = dt.difference(startWindow).inDays;
      if (diff >= 0 && diff < days) {
        dayCounts[diff] = (dayCounts[diff] ?? 0) + 1;
      }
    }

    final forecast = <DailyReviewForecast>[];
    for (int i = 0; i < days; i++) {
      forecast.add(DailyReviewForecast(
        date: startWindow.add(Duration(days: i)),
        count: dayCounts[i] ?? 0,
      ));
    }

    return ReviewDashboardData(
      total: stats['total'] ?? 0,
      newCount: stats['new_count'] ?? 0,
      dueReviewCount: stats['review_count'] ?? 0,
      masteredCount: stats['mastered_count'] ?? 0,
      scheduledCount: stats['scheduled_count'] ?? 0,
      forecast: forecast,
    );
  }

  Future<StudyPlanBankCatalog> getStudyPlanBankCatalog() async {
    final List<StudyPlanBank> rawBanks = [];

    // 核心注入：动态生成虚拟错题本卡片
    final lapseCount = await ReviewRepository.instance.getGlobalLapseCount();
    if (lapseCount > 0) {
      final stats = await getBankStats('🔥 全局错题本');
      rawBanks.add(StudyPlanBank(
        bankName: '🔥 全局错题本',
        folderName: StudyPlanBankCatalog.priorityFolderName, // 专属高亮学科文件夹
        total: stats['total'] ?? 0,
        mastered: stats['mastered_count'] ?? 0,
        dailyQuota: 40,
        daysLeft:
            (((stats['total'] ?? 0) - (stats['mastered_count'] ?? 0)) / 40)
                .ceil(),
      ));
    }

    final bankNames = await ReviewRepository.instance.getAllDistinctBankNames();
    final folderMap = await ReviewRepository.instance.getAllBankFolders();

    for (var bName in bankNames) {
      final stats = await getBankStats(bName);

      final quota = await SettingsRepository.instance
          .getDailyQuota(bName, defaultQuota: 40);

      final total = stats['total'] ?? 0;
      final mastered = stats['mastered_count'] ?? 0;
      final unmastered = (total - mastered) < 0 ? 0 : (total - mastered);
      final daysLeft = (unmastered / (quota > 0 ? quota : 40)).ceil();

      rawBanks.add(StudyPlanBank(
        bankName: bName,
        folderName:
            folderMap[bName] ?? StudyPlanBankCatalog.uncategorizedFolderName,
        total: total,
        mastered: mastered,
        dailyQuota: quota,
        daysLeft: daysLeft,
      ));
    }

    return StudyPlanBankCatalog.fromBanks(rawBanks);
  }

  Future<List<Map<String, dynamic>>> getAllBankStats() async {
    final catalog = await getStudyPlanBankCatalog();
    return catalog.banks.map((bank) => bank.toLegacyMap()).toList();
  }

  // ================================================================
  //  FSRS 核心数学引擎
  // ================================================================

  // Grade: 1=重来(Again), 2=困难(Hard), 3=顺利(Good), 4=极易(Easy)
  Map<String, dynamic> _calculateFSRS(
      Map<String, dynamic> currentState, int grade) {
    double d = (currentState['difficulty'] as num?)?.toDouble() ?? 5.0;
    double s = (currentState['stability'] as num?)?.toDouble() ?? 0.0;
    int reps = (currentState['reps'] as int?) ?? 0;
    int lapses = (currentState['lapses'] as int?) ?? 0;
    int lastReview = (currentState['last_review_time'] as int?) ?? 0;

    final int nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int actualElapsed =
        lastReview == 0 ? 0 : (nowUnix - lastReview) ~/ 86400;

    // 1. 难度 D 的动态演进 (界于 1.0 - 10.0)
    double dNew = d - (grade - 3) * 0.8;
    dNew = math.max(1.0, math.min(10.0, dNew));

    if (grade == 1) {
      lapses++;
    }

    // 2. 稳定性 S 的计算
    double sNew;
    if (reps == 0) {
      sNew = grade == 1 ? 1.0 : (grade == 2 ? 2.0 : (grade == 3 ? 3.0 : 5.0));
    } else {
      if (grade == 1) {
        sNew = math.max(1.0, s * math.exp(-0.3 * dNew));
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

  Future<void> submitReview(String questionId, int grade) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _submitReviewUnchecked(questionId, grade),
    );
  }

  Future<void> _submitReviewUnchecked(String questionId, int grade) async {
    final states =
        await ReviewRepository.instance.fetchReviewStates([questionId]);
    if (!states.containsKey(questionId)) return;

    final currentState = states[questionId]!;
    final newState = _calculateFSRS(currentState, grade);
    newState['question_id'] = questionId;

    final safeLen = math.min(8, questionId.length);
    final newLog = {
      'id':
          '${DateTime.now().millisecondsSinceEpoch}_${questionId.substring(0, safeLen)}',
      'question_id': questionId,
      'grade': grade,
      'llm_score': 0.0,
      'review_time': newState['last_review_time'],
      'duration_ms': 0,
    };

    await ReviewRepository.instance.updateReviewStatesAndLogs(
      [], // no inserts
      [newState], // updates
      [newLog], // log insert
    );
  }

  // ================================================================
  //  双端队列会话调度器
  // ================================================================

  Future<void> initStudySession(String bankName,
      {int? type, int limit = 40}) async {
    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final questions = await ReviewRepository.instance
        .getPersistedStudySessionQuestions(bankName, nowUnix,
            type: type, limit: limit);
    _sessionQueue = Queue<PersistedQuestion>.from(questions);
  }

  /// Narrow SPL-1-U0 prepared-session seam: replaces the current in-memory
  /// session queue with the exact provided ordered questions.
  ///
  /// Its responsibility is ONLY queue replacement. It never selects
  /// candidates, queries the StudyPlan, writes review state, changes FSRS,
  /// or persists selected IDs. The caller (StudyPlan materialization
  /// adapter) must already have materialized the exact ordered questions.
  void initPreparedStudySession(List<PersistedQuestion> orderedQuestions) {
    _sessionQueue = Queue<PersistedQuestion>.from(orderedQuestions);
  }

  // O(1) 极速弹出一道题
  PersistedQuestion? popNextQuestion() {
    if (_sessionQueue == null || _sessionQueue!.isEmpty) return null;
    return _sessionQueue!.removeFirst();
  }

  // O(1) 错题回炉：grade=1(重来)时塞回队尾，本轮必须消灭它
  void requeueQuestion(PersistedQuestion question) {
    _sessionQueue?.addLast(question);
  }

  // ================================================================
  //  内部批量写
  // ================================================================

  Future<void> _flushNow() {
    final activeFlush = _activeFlushFuture;
    if (activeFlush != null) return activeFlush;
    if (_queue.isEmpty) return Future<void>.value();

    final completion = Completer<void>();
    _activeFlushFuture = completion.future;
    unawaited(_runFlush(completion));
    return completion.future;
  }

  Future<void> _runFlush(Completer<void> completion) async {
    _flushing = true;

    final batch = List<_PendingWrite>.from(_queue);
    _queue.clear();

    try {
      final int now = TimeUtil.getRealUTCTimestamp();

      final ids = batch.map((e) => e.questionId).toList();
      final stateMap = await ReviewRepository.instance.fetchReviewStates(ids);
      final questionMapData =
          await ReviewRepository.instance.fetchQuestions(ids);

      final questionMap = <String, Question>{};
      for (final r in questionMapData.values) {
        questionMap[r['id'].toString()] = Question.fromMap(r);
      }

      final statesToInsert = <Map<String, dynamic>>[];
      final statesToUpdate = <Map<String, dynamic>>[];
      final logsToInsert = <Map<String, dynamic>>[];

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
          LLMService(
            engineRepository: item.engineRepository,
          ).generateVariantQuestion(originalQuestion);
          debugPrint(
              "Variant generation triggered for question ${item.questionId}");
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
          'last_lapse_time':
              item.grade < 2 ? now : (prev?['last_lapse_time'] ?? 0),
        };

        if (prev == null) {
          statesToInsert.add(stateValues);
        } else {
          statesToUpdate.add(stateValues);
        }

        logsToInsert.add({
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

      await ReviewRepository.instance.updateReviewStatesAndLogs(
        statesToInsert,
        statesToUpdate,
        logsToInsert,
      );
      for (final item in batch) {
        item.lease.release();
      }
      completion.complete();
    } catch (error, stackTrace) {
      _queue.insertAll(0, batch);
      completion.completeError(error, stackTrace);
    } finally {
      _flushing = false;
      if (identical(_activeFlushFuture, completion.future)) {
        _activeFlushFuture = null;
      }
      if (_queue.isNotEmpty && _debounceTimer == null) {
        _scheduleDebouncedFlush();
      }
    }
  }

  void _scheduleDebouncedFlush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, () {
      _debounceTimer = null;
      if (_queue.isNotEmpty) {
        unawaited(_flushNow().catchError((_) {}));
      }
    });
  }
}
