import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../../application/answers/answer_candidate_review_session.dart';
import '../../application/questions/question_mutation_command.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../../data/repositories/question_repository.dart';
import '../../domain/answers/answer_candidate.dart';
import '../../domain/question/question_draft_v2.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../models/persisted_question_view.dart';
import '../widgets/persisted_question_card.dart';
import '../widgets/structured_content_renderer.dart';
import 'question_edit_screen.dart';
import 'typed_answer_repair_screen.dart';

class QuestionListScreen extends StatefulWidget {
  final String bankName;
  final QuestionRepository? questionRepository;
  final ValueChanged<int?>? onLoadFinished;

  const QuestionListScreen({
    super.key,
    required this.bankName,
    this.questionRepository,
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

  QuestionRepository get _questionRepository =>
      widget.questionRepository ?? QuestionRepository.instance;

  QuestionMutationCommand get _questionMutation =>
      QuestionMutationCommand(_questionRepository);

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
      final persisted = await _questionRepository.getPersistedQuestionsByBank(
        widget.bankName,
      );
      if (!mounted) return;
      final views = List<PersistedQuestionView>.unmodifiable(
        persisted.map(PersistedQuestionViewAdapter.fromPersisted),
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
          command: TypedAnswerCommand(_questionRepository),
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
            builder: (_) => _AiAnswerReviewDialog(
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
        SnackBar(content: Text(_generationFailureMessage(error.failure))),
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

/// Transient AI candidate review surface.
///
/// Modal dialog only; no new page. The dialog drives the shared review core
/// exactly once per explicit user decision and commits only through
/// [AiAnswerCommitCommand]. Dismissing the dialog is always zero mutation.
/// fill -> one explicit "采用答案" action; replace -> two explicit actions
/// (select/arm, then reconfirm); noOp -> informational only.
class _AiAnswerReviewDialog extends StatefulWidget {
  const _AiAnswerReviewDialog({
    required this.candidate,
    required this.session,
    required this.commitCommand,
  });

  final AnswerCandidate candidate;
  final AnswerCandidateReviewSession session;
  final AiAnswerCommitCommand commitCommand;

  @override
  State<_AiAnswerReviewDialog> createState() => _AiAnswerReviewDialogState();
}

class _AiAnswerReviewDialogState extends State<_AiAnswerReviewDialog> {
  /// Armed replace session after the first explicit replace decision.
  AnswerCandidateReviewSession? _armedSession;

  /// Confirmed session + exact confirmation after the explicit confirm
  /// decision; reused unchanged on commit retry.
  AnswerCandidateReviewSession? _decidedSession;
  AnswerCandidateConfirmation? _confirmation;
  bool _committing = false;
  String? _errorText;

  AnswerCandidate get _candidate => widget.candidate;
  AiAnswerCommitCommand get _commitCommand => widget.commitCommand;

  Future<void> _commit() async {
    if (_committing) return;
    setState(() {
      _committing = true;
      _errorText = null;
    });
    try {
      await _commitCommand.commit(
        session: _decidedSession!,
        confirmation: _confirmation!,
      );
      if (!mounted) return;
      // Unlock route pops before closing: the PopScope below blocks any
      // dismissal while a durable commit is pending, and a success pop must
      // not be intercepted.
      setState(() => _committing = false);
      Navigator.pop(context, true);
    } on AiAnswerCommitException catch (error) {
      if (!mounted) return;
      setState(() {
        _committing = false;
        _errorText = _commitFailureMessage(error.failure);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _committing = false;
        _errorText = '保存失败，请稍后重试。';
      });
    }
  }

  Future<void> _confirmFill() async {
    if (_committing) return;
    setState(() => _errorText = null);
    try {
      if (_decidedSession == null) {
        final decided = widget.session.confirmFill(_candidate.candidateId);
        _decidedSession = decided.session;
        _confirmation = decided.confirmation;
      }
      await _commit();
    } on AnswerCandidateReviewException catch (error) {
      if (!mounted) return;
      setState(() => _errorText = _reviewFailureMessage(error.failure));
    }
  }

  Future<void> _armReplace() async {
    if (_committing) return;
    setState(() => _errorText = null);
    try {
      _armedSession = widget.session.selectForReplace(_candidate.candidateId);
      if (mounted) setState(() {});
    } on AnswerCandidateReviewException catch (error) {
      if (!mounted) return;
      setState(() => _errorText = _reviewFailureMessage(error.failure));
    }
  }

  Future<void> _confirmReplace() async {
    if (_committing) return;
    setState(() => _errorText = null);
    try {
      if (_decidedSession == null) {
        final decided = _armedSession!.confirmReplace(_candidate.candidateId);
        _decidedSession = decided.session;
        _confirmation = decided.confirmation;
      }
      await _commit();
    } on AnswerCandidateReviewException catch (error) {
      if (!mounted) return;
      setState(() => _errorText = _reviewFailureMessage(error.failure));
    }
  }

  @override
  Widget build(BuildContext context) {
    final intent = _candidate.writeIntent;
    final replaceArmed = _armedSession != null;
    final isNoOp = intent == CandidateWriteIntent.noOp;
    // Route-pop protection tied to the pending durable commit: system/back
    // cannot dismiss the review while `_committing` is true, so a successful
    // commit result can never be lost to an unmounted dialog.
    return PopScope(
      canPop: !_committing,
      child: AlertDialog(
        title: const Text(
          'AI 建议答案',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _intentLabel(intent, replaceArmed),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              if (!isNoOp) ...[
                const Text(
                  '建议答案：',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                _renderAnswer(_candidate.answer),
              ],
              if (intent == CandidateWriteIntent.replace && replaceArmed) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Text(
                    '当前已有答案。\nAI 建议将现有答案替换为上方内容。\n是否确认替换？',
                    style: TextStyle(fontSize: 13, color: Colors.orangeAccent),
                  ),
                ),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        actions: _buildActions(intent, replaceArmed),
      ),
    );
  }

  String _intentLabel(CandidateWriteIntent intent, bool replaceArmed) {
    return switch (intent) {
      CandidateWriteIntent.fill => '当前答案为空，将填写 AI 建议答案。',
      CandidateWriteIntent.noOp => 'AI 建议与当前答案等价，无需修改。',
      CandidateWriteIntent.replace =>
        replaceArmed ? '已选择替换，请进行最终确认。' : '当前已有答案，AI 建议替换。',
    };
  }

  /// Display-only projection of the candidate answer. The candidate itself
  /// is never modified; option labels are only a display projection and
  /// never become formal identity.
  Widget _renderAnswer(QuestionAnswer answer) {
    return switch (answer) {
      ContentAnswer(:final content) => RichContentRenderer(content: content),
      ChoiceAnswer(:final optionIds) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final optionId in optionIds) _renderOptionProjection(optionId),
          ],
        ),
    };
  }

  Widget _renderOptionProjection(String optionId) {
    for (final option in _candidate.expectedDraft.options) {
      if (option.optionId == optionId) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${option.label}.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 6),
              Expanded(child: RichContentRenderer(content: option.content)),
            ],
          ),
        );
      }
    }
    return Text(optionId);
  }

  List<Widget> _buildActions(
    CandidateWriteIntent intent,
    bool replaceArmed,
  ) {
    final close = TextButton(
      onPressed: _committing ? null : () => Navigator.pop(context, false),
      child: const Text('取消', style: TextStyle(color: Colors.grey)),
    );
    final commitButton = _committing
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : null;
    return switch (intent) {
      CandidateWriteIntent.noOp => [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('关闭'),
          ),
        ],
      CandidateWriteIntent.fill => [
          close,
          commitButton ??
              FilledButton(
                onPressed: _confirmFill,
                child: const Text('采用答案'),
              ),
        ],
      CandidateWriteIntent.replace => [
          close,
          if (commitButton != null)
            commitButton
          else
            FilledButton(
              onPressed: replaceArmed ? _confirmReplace : _armReplace,
              child: Text(replaceArmed ? '二次确认替换' : '确认替换'),
            ),
        ],
    };
  }
}

String _generationFailureMessage(AiAnswerGenerationFailure failure) {
  return switch (failure) {
    AiAnswerGenerationFailure.questionMissing => '题目不存在，请刷新后重试。',
    AiAnswerGenerationFailure.questionNotTyped => '该题目不是结构化题目。',
    AiAnswerGenerationFailure.unsupportedQuestionKind => '该题型暂不支持 AI 解答。',
    AiAnswerGenerationFailure.unsupportedQuestionContent =>
      '此题包含当前 AI 解答暂不支持的内容（如图片或无法安全发送的结构）。',
    AiAnswerGenerationFailure.invalidQuestionState => '题目状态异常，暂无法生成。',
    AiAnswerGenerationFailure.staleTarget => '题目已发生变化，请重新生成。',
    AiAnswerGenerationFailure.providerUnconfigured => '请先配置可用的文本模型。',
    AiAnswerGenerationFailure.providerAuthenticationFailed => '模型密钥无效或未授权。',
    AiAnswerGenerationFailure.providerRateLimited => '模型请求过于频繁，请稍后重试。',
    AiAnswerGenerationFailure.providerTimeout => '模型响应超时，请稍后重试。',
    AiAnswerGenerationFailure.providerUnavailable => '模型服务暂不可用，请稍后重试。',
    AiAnswerGenerationFailure.providerRejected => '模型拒绝了请求，请稍后重试。',
    AiAnswerGenerationFailure.malformedProviderOutput => '模型返回了无法识别的结果。',
    AiAnswerGenerationFailure.validationFailed => '模型返回的答案未通过校验。',
    AiAnswerGenerationFailure.internalError => '生成失败，请稍后重试。',
  };
}

String _commitFailureMessage(AiAnswerCommitFailure failure) {
  return switch (failure) {
    AiAnswerCommitFailure.staleTarget => '题目已发生变化，请重新生成答案。',
    AiAnswerCommitFailure.candidateNotCommittable => '当前答案状态不可提交，请重新生成。',
    AiAnswerCommitFailure.candidateAlreadyDecided => '该候选答案已完成处理。',
    AiAnswerCommitFailure.persistenceFailed => '保存失败，请稍后重试。',
    AiAnswerCommitFailure.internalError => '保存失败，请稍后重试。',
  };
}

String _reviewFailureMessage(AnswerCandidateReviewFailure failure) {
  return '当前答案状态已变化，请重新生成。';
}
