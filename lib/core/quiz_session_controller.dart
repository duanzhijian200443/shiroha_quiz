import 'package:flutter/foundation.dart';

import '../../data/models/question.dart';
import 'review_engine_service.dart';

// ================================================================
//  QuizSessionController — 双缓冲队列状态机
//
//  架构示意:
//  ┌─────────────┐     submitAnswer()     ┌─────────────┐
//  │  current     │ ───────────────────→  │  已评分       │
//  │  正在展示     │                       │  异步写库     │
//  └─────────────┘                       └─────────────┘
//         ↓ 切题瞬间（同步，零等待）
//  ┌─────────────┐
//  │  next → cur  │   ← 从 preloadQueue 弹出
//  └─────────────┘
//         ↓ 队列补水（后台异步，不阻塞 UI）
//  ┌─────────────┐
//  │  preloadQueue │  ← fetchDueQuestions() 静默补入
//  └─────────────┘
// ================================================================

class QuizSessionController extends ChangeNotifier {
  final ReviewEngineService _engine = ReviewEngineService();

  // ---- 对外只读状态 ----
  List<Question> _questions = [];
  int _currentIndex = -1;
  bool _loading = true;
  bool _exhausted = false;
  String? _error;

  List<Question> get questions => List.unmodifiable(_questions);
  int get currentIndex => _currentIndex;
  bool get loading => _loading;
  bool get exhausted => _exhausted;
  String? get error => _error;

  VoidCallback? _deleteRequestHandler;

  void setDeleteRequestHandler(VoidCallback handler) {
    _deleteRequestHandler = handler;
  }

  void requestDelete() {
    _deleteRequestHandler?.call();
  }

  /// 当前展示的题目
  Question? get currentQuestion =>
      _currentIndex >= 0 && _currentIndex < _questions.length
          ? _questions[_currentIndex]
          : null;

  /// 下一道题（供 UI 层预渲染）
  Question? get nextQuestion {
    final nextIdx = _currentIndex + 1;
    return nextIdx < _questions.length ? _questions[nextIdx] : null;
  }

  /// 剩余未做题数
  int get remaining => _questions.length - _currentIndex - 1;

  // ================================================================
  //  初始化
  // ================================================================

  Future<void> initSession({int preloadCount = 5}) async {
    _loading = true;
    _exhausted = false;
    _error = null;
    notifyListeners();

    try {
      final maps = await _engine.fetchDueQuestions(limit: preloadCount);
      _questions = maps.map((m) => Question.fromMap(m)).toList();

      if (_questions.isEmpty) {
        _exhausted = true;
        _currentIndex = -1;
      } else {
        _currentIndex = 0;
        // 预加载不够 → 后台补水
        if (_questions.length < preloadCount) {
          _silentRefill(preloadCount - _questions.length);
        }
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 传入外部题目列表（如错题本定向复习）
  void initWithQuestions(List<Question> qs) {
    _questions = List.from(qs);
    _currentIndex = qs.isNotEmpty ? 0 : -1;
    _exhausted = qs.isEmpty;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  // ================================================================
  //  提交答案 — 双缓冲核心流转
  // ================================================================

  void submitAnswer(int grade, int durationMs, {bool autoNext = true}) {
    final q = currentQuestion;
    if (q == null || q.id == null) return;

    // 1) 异步写库（不阻塞）
    _engine.submitReviewResult(q.id.toString(), grade, durationMs);

    if (autoNext) {
      goToNext();
    }
  }

  void goToNext() {
    // 2) 同步切题 — 零等待
    if (_currentIndex < _questions.length - 1) {
      _currentIndex++;
    } else {
      // 队列耗尽，尝试补水
      _exhausted = true;
    }

    // 3) 静默补水：维持 5 个以上缓冲段
    if (remaining < 5 && !_exhausted) {
      _silentRefill(5);
    }

    notifyListeners();
  }

  Future<void> deleteCurrentQuestion() async {
    final q = currentQuestion;
    if (q == null || q.id == null) return;

    // 1) 异步删库
    await _engine.deleteQuestionAndRelatedData(q.id!);

    // 2) 从当前会话中移除
    final currentIndex = _questions.indexOf(q);
    if (currentIndex != -1) {
      _questions.removeAt(currentIndex);
      if (_questions.isEmpty) {
        _exhausted = true;
      } else if (_currentIndex >= _questions.length) {
        // 如果删除的是最后一个，指针回退
        _currentIndex = _questions.length - 1;
      }
      notifyListeners();
    }
  }

  // ================================================================
  //  静默补水（后台异步，绝不阻塞当前答题）
  // ================================================================

  bool _refilling = false;

  Future<void> _silentRefill(int count) async {
    if (_refilling) return;
    _refilling = true;

    try {
      final maps = await _engine.fetchDueQuestions(limit: count);
      if (maps.isEmpty) return;

      // 去重后追加到队尾
      final existingIds = _questions.map((q) => q.id).toSet();
      final newcomers = maps
          .map((m) => Question.fromMap(m))
          .where((q) => !existingIds.contains(q.id))
          .toList();

      if (newcomers.isNotEmpty) {
        _questions.addAll(newcomers);
        _exhausted = false;
        notifyListeners();
      }
    } catch (_) {
      // 补水失败静默 — 不影响当前答题
    } finally {
      _refilling = false;
    }
  }

  // ================================================================
  //  生命周期
  // ================================================================

  @override
  void dispose() {
    _engine.flushPending();
    super.dispose();
  }

  void onSessionEnd() {
    _engine.flushPending();
  }
}
