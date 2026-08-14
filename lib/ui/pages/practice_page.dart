import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/review_engine_service.dart';
import '../../data/models/persisted_question.dart';
import '../../data/models/question.dart';
import '../../data/repositories/question_repository.dart';
import '../../services/llm_service.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../models/practice_question_view.dart';
import '../widgets/markdown_extensions.dart';
import '../widgets/structured_content_renderer.dart';

class PracticePage extends StatefulWidget {
  final String? bankName;
  final int? filterType;
  final bool isPomodoroActive;
  final List<Question>? initialQuestions;
  final int? initialIndex;

  const PracticePage({
    super.key,
    this.bankName,
    this.filterType,
    this.isPomodoroActive = false,
    this.initialQuestions,
    this.initialIndex,
  });

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
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

  // Preview mode support
  List<Question>? _previewQuestions;
  int _previewIndex = 0;

  bool get isSubjective {
    if (_currentQuestion == null) return false;
    return _currentQuestion!.displayOptions.isEmpty;
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
    await QuestionRepository.instance.insertPomodoroSession({
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
    if (_currentQuestion == null) return;

    final view = _currentQuestion!;
    final isPreview = view.isPreview;

    if (!isPreview) {
      // 1. 异步触发底层 SQLite 事务落盘 FSRS 数据
      // 不使用 await 阻塞 UI，保障极速切换体验
      ReviewEngineService().submitReview(view.storageId, grade);

      // 2. 错题回炉机制：如果是“重来(1)”，O(1) 压入队列尾部
      if (grade == 1) {
        ReviewEngineService().requeueQuestion(view.source!);
      }
    }

    // 3. 计步器联动
    if (widget.isPomodoroActive) {
      _solvedInPomodoro++;
    }

    // 4. 极速切换下一题
    _loadNextQuestion();
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
      {bool isOption = false, bool isSelected = false}) {
    final theme = Theme.of(context);
    final textColor = isOption
        ? (isSelected
            ? theme.colorScheme.primary
            : theme.textTheme.bodyLarge?.color)
        : theme.textTheme.bodyLarge?.color;
    final fontWeight =
        (isOption && isSelected) ? FontWeight.bold : FontWeight.normal;
    final fontSize = isOption ? 15.0 : 16.0;

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
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: _buildAppBar(),
          body: const Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: _buildAppBar(),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _initSession, child: const Text('重试')),
          ])));
    }
    if (_currentQuestion == null) {
      return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: _buildAppBar(),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.inbox_rounded,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('还没有题目，先去导入题库吧',
                style: TextStyle(
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: _buildAppBar(),
        body: _buildQuestionContent(),
        bottomNavigationBar: _buildBottomAction(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
          icon: Icon(Icons.close,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '退出练习'),
      title: Text('刷题中',
          style: TextStyle(
              fontSize: 15,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      centerTitle: true,
      actions: [
        if (widget.isPomodoroActive)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                '🍅 ${(_pomodoroSeconds ~/ 60).toString().padLeft(2, '0')}:${(_pomodoroSeconds % 60).toString().padLeft(2, '0')}',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepOrange),
              ),
            ),
          ),
        _isGeneratingVariant
            ? const SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.amber),
                  ),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.auto_awesome, color: Colors.amber),
                onPressed: _generateVariant,
                tooltip: '生成变种题',
              ),
        IconButton(
          icon: Icon(Icons.delete_outline,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          onPressed: _deleteCurrentQuestion,
        ),
      ],
    );
  }

  Widget _buildQuestionContent() {
    if (_currentQuestion == null) return const SizedBox.shrink();
    final view = _currentQuestion!;
    final opts = view.displayOptions;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      children: [
        _buildQuestionCard(view),
        const SizedBox(height: 16),
        if (isSubjective)
          _buildSubjectiveSection(view)
        else
          _buildOptionsList(opts),
        if (_isAnswerRevealed && !isSubjective) ...[
          const SizedBox(height: 16),
          _buildAnalysis(view)
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildQuestionCard(PracticeQuestionView view) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('practice-question-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: colors.shadow.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 3))
          ]),
      child: view.isTyped
          ? RichContentRenderer(content: view.typedStem!, fontSize: 16)
          : _buildMarkdown(view.legacyStem),
    );
  }

  Widget _buildOptionsList(List<PracticeOptionView> options) {
    final colors = Theme.of(context).colorScheme;
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
        Color bg = colors.surfaceContainerLow, border = colors.outlineVariant;
        Color lBg = colors.secondaryContainer,
            lFg = colors.onSecondaryContainer;

        if (sel) {
          bg = colors.primaryContainer;
          border = colors.primary;
          lBg = colors.primary;
          lFg = colors.onPrimary;
        }

        if (_isAnswerRevealed && _currentQuestion != null) {
          final view = _currentQuestion!;
          final bool isCorrect = isTypedOption
              ? view.answerOptionIds.contains(option.optionId)
              : view.legacyAnswer.trim().toUpperCase() == letter;
          if (isCorrect) {
            bg = colors.tertiaryContainer;
            border = colors.tertiary;
            lBg = colors.tertiary;
            lFg = colors.onTertiary;
          } else if (sel && !isCorrect) {
            bg = colors.errorContainer;
            border = colors.error;
            lBg = colors.error;
            lFg = colors.onError;
          }
        }

        return GestureDetector(
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                  child: Builder(
                    builder: (context) {
                      if (isTypedOption) {
                        final theme = Theme.of(context);
                        return RichContentRenderer(
                          content: option.typedContent!,
                          fontSize: 15,
                          textColor: sel
                              ? theme.colorScheme.primary
                              : theme.textTheme.bodyLarge?.color,
                          fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        );
                      }
                      String optStr = (option.legacyRaw ?? '').trim();
                      String stripped = optStr
                          .replaceFirst(
                              RegExp(r'^(?:[A-D][\.、]?\s*|\([A-D]\)\s*)+'), '')
                          .trim();
                      if (stripped.isEmpty) stripped = optStr;
                      return _buildMarkdown(
                        stripped,
                        isOption: true,
                        isSelected: sel,
                      );
                    },
                  ),
                ),
              ])),
        );
      },
    );
  }

  Widget _buildAnalysis(PracticeQuestionView view) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.primary.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.info_outline, size: 22, color: colors.primary),
          const SizedBox(width: 8),
          Text('答案与解析',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: colors.primary)),
        ]),
        const SizedBox(height: 8),
        if (view.isTyped) ...[
          Text('正确答案:',
              style: TextStyle(
                  fontSize: 13,
                  color: colors.onSurface,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          if (view.typedAnswer != null)
            RichContentRenderer(content: view.typedAnswer!, fontSize: 13)
          else
            Text('无',
                style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurface,
                    fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          if (view.typedExplanation != null)
            RichContentRenderer(content: view.typedExplanation!, fontSize: 13)
          else
            Text('无解析',
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ] else ...[
          Text('正确答案: ${view.legacyAnswer}',
              style: TextStyle(
                  fontSize: 13,
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

  Widget _buildSubjectiveSection(PracticeQuestionView view) {
    final colors = Theme.of(context).colorScheme;
    if (_isAnswerRevealed || _showStandardAnswerDirectly) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_aiFeedback != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, color: colors.primary, size: 18),
                    const SizedBox(width: 8),
                    Text('AI 助教判卷结果',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colors.primary)),
                  ],
                ),
                const SizedBox(height: 12),
                Text(_aiFeedback!,
                    style: const TextStyle(fontSize: 14, height: 1.6)),
              ],
            ),
          ),
        _buildAnalysis(view)
      ]);
    }

    final bool isFillInBlank = view.stemText.contains('___');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(children: [
        TextField(
          controller: _subjectiveController,
          maxLines: isFillInBlank ? 1 : 5,
          decoration: InputDecoration(
            hintText: '请输入你的答案...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.outline),
            ),
            filled: true,
            fillColor: colors.surfaceContainerHigh,
          ),
        ),
        const SizedBox(height: 16),
        Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: const Text('呼叫 AI 助教判卷',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                onPressed: _isAiJudging
                    ? null
                    : () async {
                        final uAnswer = _subjectiveController.text.trim();
                        if (uAnswer.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('请先输入你的解答')));
                          return;
                        }
                        setState(() => _isAiJudging = true);

                        final feedback = await AiDependenciesScope.of(context)
                            .aiService
                            .judgeAnswer(
                                view.stemText, view.answerText, uAnswer);

                        if (mounted) {
                          setState(() {
                            _aiFeedback = feedback;
                            _isAiJudging = false;
                            _isAnswerRevealed =
                                true; // Auto reveal answer and grade buttons
                          });
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.onPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _showStandardAnswerDirectly = true;
                  _isAnswerRevealed = true;
                });
              },
              child: const Text('跳过 AI，直接看答案自评'),
            )
          ],
        ),
        if (_isAiJudging)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          )
      ]),
    );
  }

  // ==============================
  //  Bottom Actions & FSRS Buttons
  // ==============================

  Widget _buildBottomAction() {
    if (_currentQuestion == null) return const SizedBox.shrink();
    final view = _currentQuestion!;
    final isPreview = view.isPreview;
    final colors = Theme.of(context).colorScheme;

    if (!_isAnswerRevealed) {
      if (isSubjective) {
        return const SizedBox.shrink(); // Subjective has its own buttons
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              key: const ValueKey<String>('practice-reveal-answer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              onPressed: () {
                if (!isSubjective &&
                    _selectedOptionIndex == null &&
                    _selectedOptionId == null) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('请先选择一个答案')));
                  return;
                }
                setState(() => _isAnswerRevealed = true);
              },
              child: const Text('查看答案',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      );
    }

    if (isPreview) {
      return _buildPreviewBottomBar(view);
    }

    // 当答案揭晓时，底部显示四个 FSRS 评级按钮
    return SafeArea(
      child: Container(
        key: const ValueKey<String>('practice-grade-bar'),
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          boxShadow: [
            BoxShadow(
                color: colors.shadow.withValues(alpha: 0.10),
                blurRadius: 10,
                offset: const Offset(0, -4))
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildGradeButton('重来', 1),
            _buildGradeButton('困难', 2),
            _buildGradeButton('顺利', 3),
            _buildGradeButton('极易', 4),
          ],
        ),
      ),
    );
  }

  Widget _buildGradeButton(String label, int grade) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (grade) {
      1 => colors.error,
      2 => colors.tertiary,
      3 => colors.secondary,
      _ => colors.primary,
    };
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.1),
            foregroundColor: color,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () => _submitGrade(grade),
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
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
      await QuestionRepository.instance.savePreviewQuestion(
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
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: BoxDecoration(color: colors.surfaceContainer, boxShadow: [
        BoxShadow(
            color: colors.shadow.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, -2))
      ]),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: const Text('丢弃',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  onPressed: _discardPreviewQuestion,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.errorContainer,
                    foregroundColor: colors.onErrorContainer,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.archive_rounded),
                  label: const Text('收入题库',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  onPressed: _savePreviewQuestion,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.tertiaryContainer,
                    foregroundColor: colors.onTertiaryContainer,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
        content: const Text('确定要彻底删除此题及所有复习记录吗？此操作不可恢复。'),
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
      await QuestionRepository.instance.deleteQuestion(qId);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🗑️ 题目已彻底删除')),
      );

      _loadNextQuestion(); // Move to next
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: ${e.toString()}')),
      );
    }
  }
}
