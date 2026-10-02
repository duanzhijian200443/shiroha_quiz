import '../widgets/photo_answer_transcription.dart';
import '../../application/practice/photo_answer_history.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../application/practice/practice_session_mutation_command.dart';
import '../../application/practice/record_answer_attempt_command.dart';
import '../../application/practice/photo_answer_judgement.dart';
import '../../application/practice/photo_answer_submission.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/questions/question_write_mutation_command.dart';
import '../../core/review_engine_service.dart';
import '../../data/models/persisted_question.dart';
import '../../data/models/question.dart';
import '../../domain/attempt/answer_attempt.dart';
import '../../services/llm_service.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../dependencies/practice_command_dependencies.dart';
import '../models/practice_question_view.dart';
import 'photo_capture_screen.dart';
import '../widgets/markdown_extensions.dart';
import '../widgets/structured_content_renderer.dart';
import '../theme/design_tokens.dart';

typedef PhotoAnswerCaptureLauncher = Future<ConfirmedPhotoAnswer?> Function(
  BuildContext context,
  PhotoAnswerJudgementPort recognition,
  PracticeQuestionView view,
);

class PracticePage extends StatefulWidget {
  final String? bankName;
  final int? filterType;
  final bool isPomodoroActive;
  final List<Question>? initialQuestions;
  final int? initialIndex;

  /// Prepared-session seam for explicitly selected ordinary or plan candidates.
  ///
  /// When true, the session queue has already been injected into
  /// [ReviewEngineService] via `initPreparedStudySession` (exact ordered
  /// persisted questions); this page must NOT re-run the repository session
  /// read and must NOT enter preview mode. All answering/grade/FSRS/requeue
  /// paths remain the normal non-preview ones.
  ///
  /// This is deliberately NOT [initialQuestions]: preview mode intentionally
  /// bypasses normal review/FSRS mutation and must never carry StudyPlan
  /// sessions.
  final bool usePreparedStudySession;

  /// Existing prepared plan callers remain focused; Today ordinary pools
  /// explicitly request normal attribution, including photo/manual attempts.
  final AnswerAttemptSessionKind preparedSessionKind;

  /// Assembled Application mutation commands, supplied by the composition
  /// root (or a test bundle over fake persistence). Required in practice for
  /// every mutating flow — attempts, grades-adjacent writes, preview saves,
  /// question deletion and Pomodoro summaries fail closed without it — while
  /// pure rendering and session loading never touch it.
  final PracticeCommandDependencies? practiceCommands;
  final Future<void> Function(String questionId, int grade)?
      submitReviewOverride;
  final PhotoAnswerCaptureLauncher? photoAnswerCaptureLauncher;

  const PracticePage({
    super.key,
    this.bankName,
    this.filterType,
    this.isPomodoroActive = false,
    this.initialQuestions,
    this.initialIndex,
    this.usePreparedStudySession = false,
    this.preparedSessionKind = AnswerAttemptSessionKind.focused,
    this.practiceCommands,
    this.submitReviewOverride,
    this.photoAnswerCaptureLauncher,
  });

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  /// The assembled mutation commands are read lazily and fail closed, so a
  /// surface that only renders or loads never depends on persistence wiring.
  PracticeCommandDependencies get _practiceDependencies {
    final dependencies = widget.practiceCommands;
    if (dependencies == null) {
      throw StateError('Practice mutation dependencies are not configured.');
    }
    return dependencies;
  }

  QuestionMutationCommand get _questionMutation =>
      _practiceDependencies.questionMutation;
  PracticeSessionMutationCommand get _practiceSessionMutation =>
      _practiceDependencies.practiceSessionMutation;
  QuestionWriteMutationCommand get _questionWriteMutation =>
      _practiceDependencies.questionWriteMutation;
  RecordAnswerAttemptCommand get _recordAttemptCommand =>
      _practiceDependencies.recordAttempt;

  ThemeData get _practiceTheme {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFEAEAF0) : const Color(0xFF303238);
    final muted = dark ? const Color(0xFFB4B5BE) : const Color(0xFF858891);
    final surface = dark ? const Color(0xFF24252B) : Colors.white;
    final tile = dark ? const Color(0xFF2D2E35) : const Color(0xFFF7F7FA);
    final colors = base.colorScheme.copyWith(
        primary: ink,
        onPrimary: surface,
        primaryContainer: tile,
        onPrimaryContainer: ink,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: muted,
        surfaceContainerLow: tile,
        surfaceContainerHigh: tile,
        surfaceContainer: surface,
        outline: muted,
        outlineVariant:
            dark ? const Color(0xFF40414A) : const Color(0xFFE8E8EE));
    return base.copyWith(
        colorScheme: colors,
        scaffoldBackgroundColor:
            dark ? const Color(0xFF191A20) : const Color(0xFFF7F7FA),
        textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
        appBarTheme: base.appBarTheme.copyWith(
            backgroundColor:
                dark ? const Color(0xFF191A20) : const Color(0xFFF7F7FA),
            foregroundColor: ink,
            scrolledUnderElevation: 0,
            elevation: 0));
  }

  Timer? _pomodoroTimer;
  int _pomodoroSeconds = 1500; // 25分钟
  int _pomodoroStartTime = 0;
  int _solvedInPomodoro = 0;
  PracticeQuestionView? _currentQuestion;
  bool _isAnswerRevealed = false; // 控制是否显示答案和打分底栏
  bool _isLoading = true;
  String? _error;

  int? _selectedOptionIndex;
  String? _selectedOptionId;
  bool _isGeneratingVariant = false;

  bool _isAiJudging = false;
  String? _aiFeedback;

  final TextEditingController _subjectiveController = TextEditingController();
  bool _showStandardAnswerDirectly = false;

  bool _attemptRecordedForCurrentPresentation = false;
  bool _isRecordingAttempt = false;
  bool _isSubmittingGrade = false;
  int _questionPresentedTimestamp = 0;

  // Preview mode support
  List<Question>? _previewQuestions;
  int _previewIndex = 0;

  bool get isSubjective {
    if (_currentQuestion == null) return false;
    return _currentQuestion!.displayOptions.isEmpty;
  }

  ConfirmedPhotoAnswer? _pendingPhoto;
  String? _pendingPhotoAttemptId;
  Future<List<PhotoAnswerHistoryEntry>>? _photoHistory;

  Future<void> _captureSubjectiveAnswer() async {
    if (_isAiJudging ||
        _isRecordingAttempt ||
        _attemptRecordedForCurrentPresentation) {
      return;
    }
    final view = _currentQuestion!;
    if (view.kind != PracticeQuestionKind.fillBlank &&
        view.kind != PracticeQuestionKind.shortAnswer) {
      return;
    }
    final dependencies = AiDependenciesScope.of(context);
    setState(() => _isRecordingAttempt = true);
    try {
      final photo = _pendingPhoto ??
          await (widget.photoAnswerCaptureLauncher ??
                  _openSubjectiveAnswerCapture)(
              context, dependencies.photoAnswerJudgement, view);
      if (!mounted || !identical(view, _currentQuestion) || photo == null) {
        return;
      }
      if (!photo.result.isSuccess) return;
      _pendingPhoto = photo;
      _pendingPhotoAttemptId ??= const Uuid().v4();
      if (!view.isPreview) {
        final submission = dependencies.photoAnswerSubmission;
        if (submission == null) {
          throw const PhotoAnswerSubmissionException(
              PhotoAnswerSubmissionFailure.imageSaveFailed);
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        await submission.submit(
            photo: photo,
            attemptId: _pendingPhotoAttemptId!,
            questionId: view.storageId,
            sessionKind: widget.usePreparedStudySession
                ? widget.preparedSessionKind
                : AnswerAttemptSessionKind.normal,
            answeredAt: now ~/ 1000,
            durationMs: _questionPresentedTimestamp > 0
                ? (now - _questionPresentedTimestamp).clamp(0, 86400000)
                : null);
        _attemptRecordedForCurrentPresentation = true;
        _photoHistory =
            dependencies.photoAnswerHistory?.forQuestion(view.storageId);
      }
      if (!mounted || !identical(view, _currentQuestion)) return;
      setState(() {
        final decisionText = switch (photo.result.decision!) {
          PhotoAnswerDecision.correct => '作答正确',
          PhotoAnswerDecision.incorrect => '作答不正确',
          PhotoAnswerDecision.uncertain => 'AI 无法可靠判断这张作答图片。建议重新拍摄或改用文字输入。',
        };
        _aiFeedback = '$decisionText\n${photo.result.feedback}';
        _isAnswerRevealed = true;
        _pendingPhoto = null;
        _pendingPhotoAttemptId = null;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法保存本次作答，请重试')));
      }
    } finally {
      if (mounted) setState(() => _isRecordingAttempt = false);
    }
  }

  Future<ConfirmedPhotoAnswer?> _openSubjectiveAnswerCapture(
      BuildContext context,
      PhotoAnswerJudgementPort recognition,
      PracticeQuestionView view) {
    final question = view.photoAnswerQuestion;
    final answer = view.photoAnswerStandardAnswer;
    if (question == null || answer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('题目或标准答案无效，暂时无法进行拍照判题。')),
      );
      return Future.value(null);
    }
    return Navigator.of(context)
        .push<ConfirmedPhotoAnswer>(MaterialPageRoute<ConfirmedPhotoAnswer>(
      builder: (_) => PhotoCaptureScreen.subjectiveAnswer(
          photoAnswerJudgement: recognition,
          questionKind: view.kind == PracticeQuestionKind.fillBlank
              ? PhotoAnswerQuestionKind.fillBlank
              : PhotoAnswerQuestionKind.shortAnswer,
          question: question,
          standardAnswer: answer),
    ));
  }

  @override
  void initState() {
    super.initState();
    _initSession();
    if (widget.isPomodoroActive) {
      _pomodoroStartTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _pomodoroTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() {
          if (_pomodoroSeconds > 0) {
            _pomodoroSeconds--;
          } else {
            _handlePomodoroEnd(true);
          }
        });
      });
    }
  }

  Future<void> _initSession() async {
    setState(() => _isLoading = true);
    try {
      if (widget.initialQuestions != null &&
          widget.initialQuestions!.isNotEmpty) {
        _previewQuestions = List.from(widget.initialQuestions!);
        _previewIndex = widget.initialIndex ?? 0;
      } else if (widget.usePreparedStudySession) {
        // SPL-1 特训: the exact ordered queue was already injected via
        // ReviewEngineService.initPreparedStudySession; skip the repository
        // session read. _previewQuestions stays null, so the queue (and the
        // normal grade/FSRS/requeue paths) are used.
      } else {
        final bankName = widget.bankName ?? '默认题库';
        // 核心修复：把被遗忘的 filterType 过滤条件传给调度器，实现题型物理隔离
        await ReviewEngineService().initStudySession(
          bankName,
          type: widget.filterType,
          limit: 40,
        );
      }
      _loadNextQuestion();
    } catch (e) {
      debugPrint('会话初始化失败: $e');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _loadNextQuestion() {
    PracticeQuestionView? nextQ;

    if (_previewQuestions != null) {
      if (_previewIndex < _previewQuestions!.length) {
        nextQ = PracticeQuestionViewAdapter.fromLegacyQuestion(
          _previewQuestions![_previewIndex],
        );
        _previewIndex++;
      }
    } else {
      final persisted = ReviewEngineService().popNextQuestion();
      if (persisted != null) {
        nextQ = PracticeQuestionViewAdapter.fromPersisted(persisted);
      }
    }

    if (nextQ == null) {
      // 队列为空，代表本次刷题完成
      _handleSessionComplete();
      return;
    }

    setState(() {
      _currentQuestion = nextQ;
      _isAnswerRevealed = false;
      _isAiJudging = false;
      _aiFeedback = null;
      _selectedOptionIndex = null;
      _selectedOptionId = null;
      _subjectiveController.clear();
      _showStandardAnswerDirectly = false;
      _attemptRecordedForCurrentPresentation = false;
      _pendingPhoto = null;
      _pendingPhotoAttemptId = null;
      _photoHistory = null;
      _isRecordingAttempt = false;
      _isSubmittingGrade = false;
      _questionPresentedTimestamp = DateTime.now().millisecondsSinceEpoch;
    });
  }

  void _handleSessionComplete() {
    if (widget.isPomodoroActive) {
      // 如果番茄钟开启，调用番茄钟的结束逻辑
      _handlePomodoroEnd(true);
    } else {
      // 正常结束提示
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('🎉 任务完成'),
          content: const Text('太棒了！你已经消灭了当前队列中的所有题目。'),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context); // 关弹窗
                Navigator.pop(context); // 退回上一页，触发上层 .then 刷新
              },
              child: const Text('返回首页'),
            )
          ],
        ),
      );
    }
  }

  Future<void> _handlePomodoroEnd(bool isCompleted) async {
    _pomodoroTimer?.cancel();

    final actualDuration = 1500 - _pomodoroSeconds;

    // 1. 强制数值安全落盘
    await _practiceSessionMutation.insertPomodoroSession({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'bank_name': widget.bankName ?? '默认题库',
      'start_time': _pomodoroStartTime,
      'end_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'target_duration': 1500,
      'actual_duration': actualDuration,
      'status': isCompleted ? 1 : 0,
      'questions_solved': _solvedInPomodoro,
    });

    if (!mounted) return;

    // 3. UI 阻断与退出
    if (isCompleted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('🍅 专注结束',
              style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text('完成 25 分钟沉浸！\n共消灭 $_solvedInPomodoro 道题。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('收下数据',
                  style: TextStyle(color: Colors.deepOrange)),
            ),
          ],
        ),
      );
    }
    if (!mounted) return;
    Navigator.pop(context); // 退出答题页，返回详情页
  }

  Future<void> _submitGrade(int grade) async {
    if (_currentQuestion == null || _isSubmittingGrade) return;

    final view = _currentQuestion!;
    final isPreview = view.isPreview;

    if (!isPreview) {
      setState(() => _isSubmittingGrade = true);
      try {
        final submitFn =
            widget.submitReviewOverride ?? ReviewEngineService().submitReview;
        await submitFn(view.storageId, grade);
        if (!mounted) return;
        if (grade == 1) {
          ReviewEngineService().requeueQuestion(view.source!);
        }
      } catch (e) {
        debugPrint('Submit review failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('提交评级失败，请重试')),
          );
        }
        return;
      } finally {
        if (mounted) {
          setState(() => _isSubmittingGrade = false);
        }
      }
    }

    if (widget.isPomodoroActive) {
      _solvedInPomodoro++;
    }

    _loadNextQuestion();
  }

  Future<void> _handleRevealAnswer() async {
    if (_currentQuestion == null) return;
    if (!isSubjective &&
        _selectedOptionIndex == null &&
        _selectedOptionId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择一个答案')));
      return;
    }

    if (_isRecordingAttempt || _attemptRecordedForCurrentPresentation) {
      return;
    }

    final view = _currentQuestion!;
    if (view.isPreview) {
      setState(() {
        _isAnswerRevealed = true;
        _attemptRecordedForCurrentPresentation = true;
      });
      return;
    }

    setState(() => _isRecordingAttempt = true);

    try {
      final isTypedOption = _selectedOptionId != null;
      final bool isCorrect;
      final String payloadJson;
      if (isTypedOption) {
        isCorrect = view.answerOptionIds.contains(_selectedOptionId);
        payloadJson = AnswerAttemptPayload.choice(
          optionIds: <String>[_selectedOptionId!],
        );
      } else {
        final letter = String.fromCharCode(65 + _selectedOptionIndex!);
        isCorrect = view.legacyAnswer.trim().toUpperCase() == letter;
        payloadJson = AnswerAttemptPayload.legacyChoice(
          labels: <String>[letter],
        );
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final durationMs = _questionPresentedTimestamp > 0
          ? (nowMs - _questionPresentedTimestamp).clamp(0, 86400000)
          : null;

      final attempt = AnswerAttempt(
        attemptId: const Uuid().v4(),
        questionId: view.storageId,
        sessionKind: widget.usePreparedStudySession
            ? widget.preparedSessionKind
            : AnswerAttemptSessionKind.normal,
        modality: AnswerAttemptModality.choice,
        answerPayloadJson: payloadJson,
        correctness: isCorrect,
        answeredAt: nowMs ~/ 1000,
        durationMs: durationMs,
      );

      await _recordAttemptCommand.recordAttempt(attempt);

      if (mounted) {
        setState(() {
          _attemptRecordedForCurrentPresentation = true;
          _isAnswerRevealed = true;
        });
      }
    } catch (e) {
      debugPrint('Record answer attempt failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('记录本次作答失败，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRecordingAttempt = false);
      }
    }
  }

  @override
  void dispose() {
    _pomodoroTimer?.cancel();
    _subjectiveController.dispose();
    super.dispose();
  }

  // ==============================
  //  Markdown Rendering Helper
  // ==============================

  Widget _buildMarkdown(String text,
      {bool isOption = false,
      bool isSelected = false,
      Color? optionTextColor}) {
    final theme = _practiceTheme;
    final textColor = isOption
        ? (optionTextColor ??
            (isSelected
                ? theme.colorScheme.primary
                : theme.textTheme.bodyLarge?.color))
        : theme.textTheme.bodyLarge?.color;
    final fontWeight =
        (isOption && isSelected) ? FontWeight.bold : FontWeight.normal;
    final fontSize = isOption ? 16.0 : 17.0;

    return buildLatexWidget(
      context,
      text,
      textColor: textColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
    );
  }

  // ==============================
  //  UI Widgets
  // ==============================

  @override
  Widget build(BuildContext context) =>
      Theme(data: _practiceTheme, child: _buildPage());

  Widget _buildPage() {
    if (_isLoading) {
      return Scaffold(
          backgroundColor: _practiceTheme.scaffoldBackgroundColor,
          appBar: _buildAppBar(),
          body: const Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
          backgroundColor: _practiceTheme.scaffoldBackgroundColor,
          appBar: _buildAppBar(),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline,
                size: 48, color: _practiceTheme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(
                    fontSize: 13,
                    color: _practiceTheme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _initSession, child: const Text('重试')),
          ])));
    }
    if (_currentQuestion == null) {
      return Scaffold(
          backgroundColor: _practiceTheme.scaffoldBackgroundColor,
          appBar: _buildAppBar(),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.inbox_rounded,
                size: 56, color: _practiceTheme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('还没有题目，先去导入题库吧',
                style: TextStyle(
                    fontSize: 15,
                    color: _practiceTheme.colorScheme.onSurfaceVariant)),
          ])));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (widget.isPomodoroActive &&
            _pomodoroTimer != null &&
            _pomodoroTimer!.isActive) {
          await _handlePomodoroEnd(false);
          return;
        }

        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        key: const ValueKey<String>('practice-page-scaffold'),
        backgroundColor: _practiceTheme.scaffoldBackgroundColor,
        appBar: _buildAppBar(),
        body: _buildQuestionContent(),
        bottomNavigationBar: _buildBottomAction(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final colors = _practiceTheme.colorScheme;
    final bank = _currentQuestion?.bankName ?? widget.bankName ?? '当前题库';
    return AppBar(
        toolbarHeight:
            MediaQuery.textScalerOf(context).scale(26).clamp(56.0, 100.0),
        backgroundColor: _practiceTheme.scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: '退出练习',
            onPressed: () => Navigator.of(context).pop()),
        title: Tooltip(
            message: bank,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_currentQuestion?.isPreview == true ? '题目预览' : '专注练习',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              Text(bank,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
            ])),
        centerTitle: false,
        actions: [
          if (widget.isPomodoroActive)
            Center(
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                        '🍅 ${(_pomodoroSeconds ~/ 60).toString().padLeft(2, '0')}:${(_pomodoroSeconds % 60).toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.tertiary)))),
          if (_isGeneratingVariant)
            const SizedBox(
                width: 32,
                height: 32,
                child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)))),
          PopupMenuButton<String>(
              key: const ValueKey('practice-more-menu'),
              tooltip: '更多操作',
              onSelected: (action) {
                if (action == 'variant') {
                  _generateVariant();
                } else if (action == 'delete') {
                  _deleteCurrentQuestion();
                }
              },
              itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'variant',
                        enabled:
                            !_isGeneratingVariant && _currentQuestion != null,
                        child: const Row(children: [
                          Icon(Icons.auto_awesome_outlined, size: 20),
                          SizedBox(width: 10),
                          Text('生成变种题')
                        ])),
                    PopupMenuItem(
                        value: 'delete',
                        enabled: _currentQuestion != null &&
                            !_currentQuestion!.isPreview,
                        child: const Row(children: [
                          Icon(Icons.delete_outline, size: 20),
                          SizedBox(width: 10),
                          Text('删除题目')
                        ])),
                  ]),
        ]);
  }

  Widget _buildQuestionContent() {
    if (_currentQuestion == null) return const SizedBox.shrink();
    final view = _currentQuestion!;
    return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
            child: ListView(
                key: const ValueKey('practice-content-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _buildQuestionCard(view),
                  const SizedBox(height: 14),
                  if (isSubjective)
                    _buildSubjectiveSection(view)
                  else
                    _buildOptionsList(view.displayOptions),
                  if (_isAnswerRevealed && !isSubjective) ...[
                    const SizedBox(height: 14),
                    _buildAnalysis(view),
                    if (!view.isPreview) _buildPhotoHistory(view),
                  ],
                ])));
  }

  Widget _section(
      {Key? key,
      required String title,
      IconData? icon,
      required Widget child}) {
    final colors = _practiceTheme.colorScheme;
    return Container(
        key: key,
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: DesignTokens.surfaceShadow(_practiceTheme.brightness)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: colors.onSurfaceVariant),
              const SizedBox(width: 7)
            ],
            Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant)))
          ]),
          const SizedBox(height: 14),
          child,
        ]));
  }

  Widget _buildQuestionCard(PracticeQuestionView view) => _section(
      key: const ValueKey('practice-question-card'),
      title: switch (view.kind) {
        PracticeQuestionKind.singleChoice => '单选题',
        PracticeQuestionKind.multipleChoice => '选择题',
        PracticeQuestionKind.fillBlank => '填空题',
        PracticeQuestionKind.shortAnswer => '简答题',
        PracticeQuestionKind.unknown => '题目',
      },
      child: view.isTyped
          ? RichContentRenderer(content: view.typedStem!, fontSize: 17)
          : _buildMarkdown(view.legacyStem));

  Widget _buildOptionsList(List<PracticeOptionView> options) {
    final colors = _practiceTheme.colorScheme;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: options.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final option = options[i];
        final isTypedOption = option.optionId != null;
        final letter =
            isTypedOption ? option.label : String.fromCharCode(65 + i);
        final sel = isTypedOption
            ? _selectedOptionId == option.optionId
            : _selectedOptionIndex == i;
        Color bg = colors.surface, border = colors.outlineVariant;
        Color lBg = colors.surfaceContainerLow, lFg = colors.onSurfaceVariant;
        String? resultLabel;
        IconData? resultIcon;
        var bodyFg = colors.onSurface;

        if (sel) {
          bg = colors.primaryContainer;
          border = colors.primary;
          lBg = colors.primary;
          lFg = colors.onPrimary;
          bodyFg = colors.onPrimaryContainer;
        }

        if (_isAnswerRevealed && _currentQuestion != null) {
          final view = _currentQuestion!;
          final bool isCorrect = isTypedOption
              ? view.answerOptionIds.contains(option.optionId)
              : view.legacyAnswer.trim().toUpperCase() == letter;
          if (isCorrect) {
            bg = colors.brightness == Brightness.dark
                ? const Color(0xFF22362E)
                : const Color(0xFFF0F7F3);
            border = colors.brightness == Brightness.dark
                ? const Color(0xFF88C5A3)
                : const Color(0xFF397B56);
            lBg = border;
            lFg = colors.surface;
            resultLabel = '正确答案';
            resultIcon = Icons.check_circle_outline;
          } else if (sel && !isCorrect) {
            bg = colors.errorContainer;
            border = colors.error;
            lBg = colors.error;
            lFg = colors.onError;
            bodyFg = colors.onErrorContainer;
            resultLabel = '选择错误';
            resultIcon = Icons.cancel_outlined;
          }
        }

        return Semantics(
          button: true,
          selected: sel,
          enabled: !_isAnswerRevealed,
          child: GestureDetector(
            onTap: _isAnswerRevealed
                ? null
                : () => setState(() {
                      if (isTypedOption) {
                        _selectedOptionId = option.optionId;
                      } else {
                        _selectedOptionIndex = i;
                      }
                    }),
            child: AnimatedContainer(
                key: ValueKey<String>('practice-option-$i'),
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: border,
                        width: sel || _isAnswerRevealed ? 1.5 : 1)),
                child: Row(children: [
                  Container(
                      width: 30,
                      height: 30,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: lBg),
                      alignment: Alignment.center,
                      child: Text(letter,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: lFg))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (resultLabel != null) ...[
                            Row(children: [
                              Icon(resultIcon, size: 16, color: border),
                              const SizedBox(width: 5),
                              Text(resultLabel,
                                  style: TextStyle(fontSize: 12, color: border))
                            ]),
                            const SizedBox(height: 6),
                          ],
                          Builder(
                            builder: (context) {
                              if (isTypedOption) {
                                return RichContentRenderer(
                                  content: option.typedContent!,
                                  fontSize: 16,
                                  textColor: bodyFg,
                                  fontWeight:
                                      sel ? FontWeight.bold : FontWeight.normal,
                                );
                              }
                              String optStr = (option.legacyRaw ?? '').trim();
                              String stripped = optStr
                                  .replaceFirst(
                                      RegExp(
                                          r'^(?:[A-D][\.、]?\s*|\([A-D]\)\s*)+'),
                                      '')
                                  .trim();
                              if (stripped.isEmpty) stripped = optStr;
                              return _buildMarkdown(
                                stripped,
                                isOption: true,
                                isSelected: sel,
                                optionTextColor: bodyFg,
                              );
                            },
                          ),
                        ]),
                  ),
                ])),
          ),
        );
      },
    );
  }

  Widget _buildAnalysis(PracticeQuestionView view) {
    final colors = _practiceTheme.colorScheme;
    return _section(
      title: '答案与解析',
      icon: Icons.info_outline,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (view.isTyped) ...[
          Text('正确答案:',
              style: TextStyle(
                  fontSize: 16,
                  color: colors.onSurface,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (view.typedAnswer != null)
            RichContentRenderer(content: view.typedAnswer!, fontSize: 16)
          else
            Text('无',
                style: TextStyle(
                    fontSize: 16,
                    color: colors.onSurface,
                    fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          if (view.typedExplanation != null)
            RichContentRenderer(content: view.typedExplanation!, fontSize: 16)
          else
            Text('无解析',
                style: TextStyle(
                    fontSize: 16,
                    color: _practiceTheme.colorScheme.onSurfaceVariant)),
        ] else ...[
          Text('正确答案: ${view.legacyAnswer}',
              style: TextStyle(
                  fontSize: 16,
                  color: colors.onSurface,
                  fontWeight: FontWeight.bold)),
          if ((view.legacyRawExplanation != null &&
                  view.legacyRawExplanation!.isNotEmpty) ||
              (view.legacyExplanation != null &&
                  view.legacyExplanation!.isNotEmpty)) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _buildMarkdown((view.legacyRawExplanation != null &&
                    view.legacyRawExplanation!.isNotEmpty)
                ? view.legacyRawExplanation!
                : (view.legacyExplanation ?? '暂无解析')),
          ],
        ],
      ]),
    );
  }

  Widget _buildPhotoHistory(PracticeQuestionView view) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AiDependenciesScope>();
    _photoHistory ??= scope?.photoAnswerHistory?.forQuestion(view.storageId);
    if (_photoHistory == null) return const SizedBox.shrink();
    return FutureBuilder<List<PhotoAnswerHistoryEntry>>(
        future: _photoHistory,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Text('无法加载作答图片记录，请稍后重试');
          final entries = snapshot.data ?? const <PhotoAnswerHistoryEntry>[];
          if (entries.isEmpty) return const SizedBox.shrink();
          return ExpansionTile(title: const Text('拍照作答记录'), children: [
            for (final entry in entries.reversed)
              ListTile(
                title:
                    Text(entry.evidenceAvailable ? '作答图片已保存至资料库' : '原始作答图片已清理'),
                subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.attempt.correctness == null
                          ? '无法可靠判断'
                          : entry.attempt.correctness!
                              ? '作答正确'
                              : '作答不正确'),
                      if (entry.transcription.isNotEmpty)
                        PhotoAnswerTranscription(text: entry.transcription),
                      if (entry.feedback.isNotEmpty) Text(entry.feedback),
                    ]),
              ),
          ]);
        });
  }

  Widget _buildSubjectiveSection(PracticeQuestionView view) {
    final colors = _practiceTheme.colorScheme;
    if (_isAnswerRevealed || _showStandardAnswerDirectly) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_aiFeedback != null) ...[
          _section(
              title: 'AI 助教判卷结果',
              icon: Icons.auto_awesome_outlined,
              child: Text(_aiFeedback!,
                  style: const TextStyle(fontSize: 16, height: 1.65))),
          const SizedBox(height: 14),
        ],
        _buildAnalysis(view),
        if (!view.isPreview) _buildPhotoHistory(view),
      ]);
    }
    final isFillInBlank = view.kind == PracticeQuestionKind.fillBlank;
    return _section(
        key: const ValueKey('practice-answer-input'),
        title: '我的作答',
        icon: Icons.edit_note_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              controller: _subjectiveController,
              minLines: isFillInBlank ? 1 : 5,
              maxLines: isFillInBlank ? 1 : 5,
              style: const TextStyle(fontSize: 16, height: 1.6),
              decoration: InputDecoration(
                  hintText: isFillInBlank ? '输入填空答案' : '写下你的思路与解答…',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.outlineVariant)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.outlineVariant)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.primary)),
                  filled: true,
                  fillColor: colors.surfaceContainerLow,
                  contentPadding: const EdgeInsets.all(14))),
          if (view.kind == PracticeQuestionKind.fillBlank ||
              view.kind == PracticeQuestionKind.shortAnswer) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
                key: const ValueKey('subjective-answer-photo-action'),
                onPressed: _isAiJudging || _isRecordingAttempt
                    ? null
                    : _captureSubjectiveAnswer,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: Text(_pendingPhoto == null ? '拍照作答' : '重试提交作答')),
          ],
          const SizedBox(height: 4),
          Text('可以输入答案，也可以在纸上作答后拍照。',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: colors.onSurfaceVariant)),
        ]));
  }

  Future<void> _judgeSubjectiveAnswer() async {
    final uAnswer = _subjectiveController.text.trim();
    if (uAnswer.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先输入你的解答')));
      return;
    }
    if (_isRecordingAttempt || _isAiJudging) return;
    final aiService = AiDependenciesScope.of(context).aiService;

    final view = _currentQuestion!;
    if (!view.isPreview && !_attemptRecordedForCurrentPresentation) {
      setState(() => _isRecordingAttempt = true);
      try {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final durationMs = _questionPresentedTimestamp > 0
            ? (nowMs - _questionPresentedTimestamp).clamp(0, 86400000)
            : null;
        final attempt = AnswerAttempt(
          attemptId: const Uuid().v4(),
          questionId: view.storageId,
          sessionKind: widget.usePreparedStudySession
              ? widget.preparedSessionKind
              : AnswerAttemptSessionKind.normal,
          modality: AnswerAttemptModality.text,
          answerPayloadJson: AnswerAttemptPayload.text(text: uAnswer),
          correctness: null,
          answeredAt: nowMs ~/ 1000,
          durationMs: durationMs,
        );
        await _recordAttemptCommand.recordAttempt(attempt);
        _attemptRecordedForCurrentPresentation = true;
      } catch (e) {
        debugPrint('Record text answer attempt failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('记录本次作答失败，请重试')),
          );
        }
        return;
      } finally {
        if (mounted) {
          setState(() => _isRecordingAttempt = false);
        }
      }
    }

    if (!mounted) return;

    setState(() => _isAiJudging = true);

    final feedback =
        await aiService.judgeAnswer(view.stemText, view.answerText, uAnswer);

    if (mounted) {
      setState(() {
        _aiFeedback = feedback;
        _isAiJudging = false;
        _isAnswerRevealed = true; // Auto reveal answer and grade buttons
      });
    }
  }

  Future<void> _revealSubjectiveAnswer() async {
    final uAnswer = _subjectiveController.text.trim();
    final view = _currentQuestion!;
    if (uAnswer.isNotEmpty &&
        !view.isPreview &&
        !_attemptRecordedForCurrentPresentation) {
      setState(() => _isRecordingAttempt = true);
      try {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final durationMs = _questionPresentedTimestamp > 0
            ? (nowMs - _questionPresentedTimestamp).clamp(0, 86400000)
            : null;
        final attempt = AnswerAttempt(
          attemptId: const Uuid().v4(),
          questionId: view.storageId,
          sessionKind: widget.usePreparedStudySession
              ? widget.preparedSessionKind
              : AnswerAttemptSessionKind.normal,
          modality: AnswerAttemptModality.text,
          answerPayloadJson: AnswerAttemptPayload.text(text: uAnswer),
          correctness: null,
          answeredAt: nowMs ~/ 1000,
          durationMs: durationMs,
        );
        await _recordAttemptCommand.recordAttempt(attempt);
        _attemptRecordedForCurrentPresentation = true;
      } catch (e) {
        debugPrint('Record text answer attempt failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('记录本次作答失败，请重试')),
          );
        }
        return;
      } finally {
        if (mounted) {
          setState(() => _isRecordingAttempt = false);
        }
      }
    }

    if (mounted) {
      setState(() {
        _showStandardAnswerDirectly = true;
        _isAnswerRevealed = true;
      });
    }
  }

  // ==============================
  //  Bottom Actions & FSRS Buttons
  // ==============================

  Widget _bottomPanel(Widget child) {
    return Container(
      color: _practiceTheme.colorScheme.surface,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
            top: false,
            child: Align(
                heightFactor: 1,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(
                        maxWidth: DesignTokens.contentMaxWidth),
                    child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: child)))),
      ),
    );
  }

  Widget _buildBottomAction() {
    if (_currentQuestion == null) return const SizedBox.shrink();
    final view = _currentQuestion!;
    final colors = _practiceTheme.colorScheme;
    final primaryStyle = ElevatedButton.styleFrom(
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        minimumSize: const Size.fromHeight(52),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)));
    if (!_isAnswerRevealed) {
      if (isSubjective) {
        return _bottomPanel(Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                  key: const ValueKey<String>('practice-subjective-reveal'),
                  style: primaryStyle,
                  onPressed:
                      _isRecordingAttempt ? null : _revealSubjectiveAnswer,
                  child: const Text('查看答案并自评',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600))),
              const SizedBox(height: 6),
              TextButton.icon(
                  key: const ValueKey<String>('practice-ai-judge'),
                  onPressed: _isAiJudging || _isRecordingAttempt
                      ? null
                      : _judgeSubjectiveAnswer,
                  icon: _isAiJudging
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text(_isAiJudging ? 'AI 正在判卷…' : '呼叫 AI 助教判卷')),
            ]));
      }
      return _bottomPanel(ElevatedButton(
          key: const ValueKey<String>('practice-reveal-answer'),
          style: primaryStyle,
          onPressed: _isRecordingAttempt ? null : _handleRevealAnswer,
          child: const Text('查看答案',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))));
    }
    if (view.isPreview) return _buildPreviewBottomBar(view);
    return _bottomPanel(LayoutBuilder(builder: (context, constraints) {
      final columns = MediaQuery.textScalerOf(context).scale(14) > 19 ||
              constraints.maxWidth < 300
          ? 2
          : 4;
      final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
      return Wrap(
          key: const ValueKey<String>('practice-grade-bar'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in [('重来', 1), ('困难', 2), ('顺利', 3), ('极易', 4)])
              SizedBox(
                  width: width, child: _buildGradeButton(item.$1, item.$2)),
          ]);
    }));
  }

  Widget _buildGradeButton(String label, int grade) {
    final colors = _practiceTheme.colorScheme;
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
          backgroundColor: colors.surfaceContainerLow,
          foregroundColor: colors.onSurface,
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      onPressed: _isSubmittingGrade ? null : () => _submitGrade(grade),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  void _discardPreviewQuestion() {
    _loadNextQuestion(); // In preview mode, just load next to discard
  }

  Future<void> _savePreviewQuestion() async {
    final view = _currentQuestion;
    if (view == null || !view.isPreview) return;
    final previewQuestion = view.legacyQuestion!;
    if (previewQuestion.id == null ||
        !previewQuestion.id!.startsWith('preview_')) {
      return;
    }

    try {
      await _questionWriteMutation.savePreviewQuestion(
        previewQuestion.toMap(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('💾 题目已成功收入题库！')),
      );

      _loadNextQuestion(); // Proceed to next after saving
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: ${e.toString()}')),
      );
    }
  }

  Widget _buildPreviewBottomBar(PracticeQuestionView view) {
    final colors = _practiceTheme.colorScheme;
    return _bottomPanel(LayoutBuilder(builder: (context, constraints) {
      final stacked = MediaQuery.textScalerOf(context).scale(16) > 22;
      final width =
          stacked ? constraints.maxWidth : (constraints.maxWidth - 12) / 2;
      return Wrap(spacing: 12, runSpacing: 8, children: [
        SizedBox(
            width: width,
            child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('丢弃'),
                onPressed: _discardPreviewQuestion,
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))))),
        SizedBox(
            width: width,
            child: ElevatedButton.icon(
                icon: const Icon(Icons.archive_outlined),
                label: const Text('收入题库'),
                onPressed: _savePreviewQuestion,
                style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    minimumSize: const Size.fromHeight(52),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))))),
      ]);
    }));
  }

  void _generateVariant() async {
    final view = _currentQuestion;
    if (view == null || _isGeneratingVariant) return;
    final currentQuestion = view.interactionQuestion!;

    setState(() {
      _isGeneratingVariant = true;
    });

    try {
      final newQuestion = await LLMService(
        engineRepository: AiDependenciesScope.of(context).engineRepository,
      ).generateVariantQuestion(currentQuestion);
      if (!mounted) return;

      if (newQuestion != null) {
        // Enqueue the new variant to be shown immediately next!
        ReviewEngineService().requeueQuestion(
          LegacyPersistedQuestion(question: newQuestion),
        );

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✨ 变种题生成成功！已加入队列。')),
        );
      } else {
        throw Exception('LLM service returned no question.');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ AI 调用失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingVariant = false;
        });
      }
    }
  }

  Future<void> _deleteCurrentQuestion() async {
    final view = _currentQuestion;
    if (view == null) return;
    final qId = view.storageId;
    if (qId.isEmpty || view.isPreview) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text(
          '将删除此题以及相关的复习状态和复习日志；历史作答记录会保留，'
          '来源文件不会被删除。如果题目仍被试卷引用，删除会被阻止。'
          '此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _questionMutation.deleteQuestion(qId);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🗑️ 题目已彻底删除')),
      );

      _loadNextQuestion(); // Move to next
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除题目失败，请稍后重试')),
      );
    }
  }
}
