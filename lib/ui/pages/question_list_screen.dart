import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/answers/ai_answer_generation.dart';
import '../../application/questions/question_list_query_port.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../models/persisted_question_view.dart';
import '../widgets/persisted_question_card.dart';
import 'question_edit_screen.dart';
import 'typed_answer_repair_screen.dart';
import 'answer_completion_ai_review.dart';

class QuestionListScreen extends StatefulWidget {
  final String bankName;
  final QuestionListQueryPort? questionListQuery;
  final QuestionMutationPersistencePort? questionMutationPersistence;
  final TypedAnswerPersistencePort? typedAnswerPersistence;
  final ValueChanged<int?>? onLoadFinished;

  const QuestionListScreen({
    super.key,
    required this.bankName,
    this.questionListQuery,
    this.questionMutationPersistence,
    this.typedAnswerPersistence,
    this.onLoadFinished,
  });

  @override
  State<QuestionListScreen> createState() => _QuestionListScreenState();
}

class _QuestionListScreenState extends State<QuestionListScreen> {
  List<PersistedQuestionView> _allQuestions = [];
  List<PersistedQuestionView> _visibleQuestions = [];
  bool _isLoading = true;
  bool _hasLoadError = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  /// Storage ids with an in-flight P7 AI generation; used to prevent
  /// duplicate triggers, show per-card busy state, and cancel on dispose.
  final Set<String> _generatingIds = <String>{};

  /// Cached on first AI action so [dispose] can cancel in-flight
  /// generations without touching a BuildContext.
  AiAnswerGenerationService? _generationService;

  QuestionListQueryPort get _questionListQuery {
    final port = widget.questionListQuery;
    if (port == null) {
      throw StateError('Question list query is not configured.');
    }
    return port;
  }

  QuestionMutationCommand get _questionMutation =>
      QuestionMutationCommand(_requireQuestionMutationPersistence);

  QuestionMutationPersistencePort get _requireQuestionMutationPersistence {
    final port = widget.questionMutationPersistence;
    if (port == null) {
      throw StateError('Question mutation dependency is not configured.');
    }
    return port;
  }

  TypedAnswerPersistencePort get _requireTypedAnswerPersistence {
    final port = widget.typedAnswerPersistence;
    if (port == null) {
      throw StateError('Typed answer dependency is not configured.');
    }
    return port;
  }

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    // Cancel every in-flight generation: a late result must never open a
    // dialog or commit after this screen is gone.
    final generationService = _generationService;
    if (generationService != null) {
      for (final storageId in _generatingIds.toList()) {
        generationService.cancel(storageId);
      }
    }
    super.dispose();
  }

  Future<void> _loadQuestions() async {
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
    });
    try {
      final persisted = await _questionListQuery.listQuestionsForBank(
        widget.bankName,
      );
      if (!mounted) return;
      final views = List<PersistedQuestionView>.unmodifiable(
        persisted.map(PersistedQuestionViewAdapter.fromApplication),
      );
      setState(() {
        _allQuestions = views;
        _applyQuery();
        _isLoading = false;
      });
      widget.onLoadFinished?.call(views.length);
    } catch (_) {
      debugPrint('Question list load failed');
      if (!mounted) return;
      setState(() {
        _allQuestions = [];
        _visibleQuestions = [];
        _isLoading = false;
        _hasLoadError = true;
      });
      widget.onLoadFinished?.call(null);
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(_applyQuery);
    });
  }

  void _applyQuery() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      _visibleQuestions = _allQuestions;
      return;
    }
    _visibleQuestions = [
      for (final question in _allQuestions)
        if (question.searchText.toLowerCase().contains(query)) question,
    ];
  }

  Future<void> _deleteQuestion(PersistedQuestionView question) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '确认删除',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '删除 Question 及允许级联的 ReviewState、ReviewLog 等题目子状态；'
          '保留 AnswerAttempt 历史作答事实，不删除来源文件；如有 ExamPaper 引用，'
          '删除会被阻止。此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (question.storageId.isEmpty) return;
    try {
      await _questionMutation.deleteQuestion(question.storageId);
      await _loadQuestions();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，请稍后重试')),
      );
    }
  }

  void _openLegacyEditor(PersistedQuestionView question) {
    final payload = question.legacyEditPayload;
    if (payload == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => QuestionEditScreen(
          question: payload,
          mutationCommand: _questionMutation,
        ),
      ),
    ).then((modified) {
      if (modified == true && mounted) _loadQuestions();
    });
  }

  void _openTypedRepair(PersistedQuestionView question) {
    final draft = question.typedDraft;
    if (draft == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => TypedAnswerRepairScreen(
          question: question,
          draft: draft,
          command: TypedAnswerCommand(_requireTypedAnswerPersistence),
        ),
      ),
    ).then((modified) {
      if (modified == true && mounted) _loadQuestions();
    });
  }

  /// P7 AI answer action: explicit user action on one persisted typed
  /// question. Presentation only orchestrates; the I0 generation service and
  /// the C0 commit command own the authoritative validation boundaries.
  Future<void> _onAiAnswer(PersistedQuestionView question) async {
    if (!question.isTyped || question.storageId.isEmpty) return;
    if (_generatingIds.contains(question.storageId)) return;
    final scope = AiDependenciesScope.of(context);
    final generationService = scope.answerGenerationService;
    final commitCommand = scope.answerCommitCommand;
    _generationService = generationService;
    setState(() => _generatingIds.add(question.storageId));
    try {
      final outcome = await generationService.generateForQuestion(
        storageId: question.storageId,
      );
      if (!mounted) return;
      setState(() => _generatingIds.remove(question.storageId));
      switch (outcome) {
        case AiAnswerGenerationGenerated(
            :final candidate,
            :final reviewSession
          ):
          final committed = await showDialog<bool>(
            context: context,
            // The review dialog is never barrier-dismissible: dismissal is
            // always an explicit Cancel/关闭 decision (zero mutation), and
            // during a pending durable commit the dialog must stay mounted
            // so the commit result can reach the parent.
            barrierDismissible: false,
            builder: (_) => AiAnswerReviewDialog(
              candidate: candidate,
              session: reviewSession,
              commitCommand: commitCommand,
            ),
          );
          if (committed == true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已保存 AI 答案')),
            );
            // Reload the authoritative persisted state; never fake the
            // card answer in memory.
            await _loadQuestions();
          }
        case AiAnswerGenerationDiscarded():
          // Late cancelled/superseded result: no dialog, no commit.
          break;
      }
    } on AiAnswerGenerationException catch (error) {
      if (!mounted) return;
      setState(() => _generatingIds.remove(question.storageId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(aiAnswerGenerationFailureMessage(error.failure))),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _generatingIds.remove(question.storageId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('生成失败，请稍后重试。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          '${widget.bankName} 题库',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索题目内容、选项或解析...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: isDark ? Colors.white10 : Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasLoadError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                '题库中存在无法安全读取的题目，请重试或修复数据',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadQuestions,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_visibleQuestions.isEmpty) {
      return const Center(
        child: Text('没有找到匹配的题目', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: _visibleQuestions.length,
      itemBuilder: (context, index) {
        final question = _visibleQuestions[index];
        final isTyped = question.isTyped;
        return PersistedQuestionCard(
          question: question,
          onDelete: () => _deleteQuestion(question),
          onEditLegacy: isTyped ? null : () => _openLegacyEditor(question),
          onRepairTypedAnswer:
              isTyped ? () => _openTypedRepair(question) : null,
          onAiAnswer: isTyped && question.storageId.isNotEmpty
              ? () => _onAiAnswer(question)
              : null,
          aiBusy: _generatingIds.contains(question.storageId),
        );
      },
    );
  }
}
