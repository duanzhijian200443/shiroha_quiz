import 'package:flutter/material.dart';
import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../../application/answers/answer_candidate_review_session.dart';
import '../../domain/answers/answer_candidate.dart';
import '../../domain/question/question_draft_v2.dart';
import '../widgets/structured_content_renderer.dart';

/// Transient AI candidate review surface.
///
/// Modal dialog only; no new page. The dialog drives the shared review core
/// exactly once per explicit user decision and commits only through
/// [AiAnswerCommitCommand]. Dismissing the dialog is always zero mutation.
/// fill -> one explicit "采用答案" action; replace -> two explicit actions
/// (select/arm, then reconfirm); noOp -> informational only.
class AiAnswerReviewDialog extends StatefulWidget {
  const AiAnswerReviewDialog({
    super.key,
    required this.candidate,
    required this.session,
    required this.commitCommand,
  });

  final AnswerCandidate candidate;
  final AnswerCandidateReviewSession session;
  final AiAnswerCommitCommand commitCommand;

  @override
  State<AiAnswerReviewDialog> createState() => _AiAnswerReviewDialogState();
}

class _AiAnswerReviewDialogState extends State<AiAnswerReviewDialog> {
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

String aiAnswerGenerationFailureMessage(AiAnswerGenerationFailure failure) {
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
