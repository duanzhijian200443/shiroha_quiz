import 'package:flutter/material.dart';

import '../../../application/import_review/typed_review_snapshot.dart';
import '../../../data/models/question_draft.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/question/question_draft_v2.dart';
import '../../../services/import_review/explanation_edit_provenance.dart';
import '../../../services/import_review/import_review_badge_formatter.dart';
import '../../../services/import_review/import_review_item.dart';
import '../../../services/import_review/import_review_issue.dart';
import '../../../services/import_review/import_review_metadata.dart';
import '../../../services/import_review/review_legacy_field_content.dart';
import '../../widgets/markdown_extensions.dart';
import '../../widgets/structured_content_renderer.dart';

/// One review card: badges, issues, repair/distillation affordances, stem,
/// options and the answer/explanation block.
///
/// Presentation only. Every value it renders is passed in, and every user
/// action is reported through the callbacks, which the page routes to the
/// review controller.
class ImportReviewQuestionCard extends StatelessWidget {
  const ImportReviewQuestionCard({
    super.key,
    required this.item,
    this.snapshot,
    required this.index,
    required this.issues,
    required this.explanationRetained,
    required this.explanationProvenance,
    required this.onExplanationRetentionChanged,
    required this.onEditExplanation,
    required this.answerDistillationCandidate,
    required this.answerDistillationStatus,
    required this.proofExplanationRecognized,
    required this.answerDistillationInProgress,
    required this.onAnswerDistillation,
    required this.reviewRepairEligible,
    required this.reviewRepairInProgress,
    required this.reviewRepairProposalReady,
    required this.onReviewRepair,
  });

  final ImportReviewItem item;
  final TypedReviewSnapshot? snapshot;
  final int index;
  final List<ImportReviewIssue> issues;
  final bool explanationRetained;
  final ExplanationEditProvenance explanationProvenance;
  final ValueChanged<bool>? onExplanationRetentionChanged;
  final VoidCallback? onEditExplanation;
  final bool answerDistillationCandidate;
  final String? answerDistillationStatus;
  final bool proofExplanationRecognized;
  final bool answerDistillationInProgress;
  final VoidCallback? onAnswerDistillation;
  final bool reviewRepairEligible;
  final bool reviewRepairInProgress;
  final bool reviewRepairProposalReady;
  final VoidCallback? onReviewRepair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = item.draft;
    final standardAnswer = question.standardAnswer.trim();
    final explanation = question.explanation.trim();
    final baseline = snapshot?.baselineLegacy;
    final typed = snapshot?.draft;
    final typedAnswer = question.standardAnswer == baseline?.standardAnswer &&
            typed?.answer is ContentAnswer
        ? (typed!.answer as ContentAnswer).content
        : null;
    final typedExplanation = resolveExplanationReviewContent(
      originalContent: typed?.explanation,
      baselineText: baseline?.explanation ?? '',
      currentText: question.explanation,
      retained: explanationRetained,
      provenance: explanationProvenance,
    );
    final metadataAvailable = item.metadataProjectionState ==
        ImportReviewMetadataProjectionState.available;
    final metadataUnavailable = item.metadataProjectionState ==
        ImportReviewMetadataProjectionState.unavailable;
    final hasWarningOrError = issues.any(
      (issue) =>
          issue.severity == ImportReviewSeverity.warning ||
          issue.severity == ImportReviewSeverity.error,
    );
    final reviewOnly = metadataAvailable &&
        !reviewRepairEligible &&
        item.metadata.repairCandidateCodes.isEmpty &&
        hasWarningOrError;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    question.type.displayName,
                    style: TextStyle(
                      color: theme.primaryColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '第 ${index + 1} 题',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            if (item.metadata.riskHints.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6.0,
                runSpacing: 6.0,
                children: ImportReviewBadgeFormatter.formatRiskHints(
                        item.metadata.riskHints)
                    .map((badge) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badge.backgroundColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badge.label,
                            style: TextStyle(
                              color: badge.textColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 8),
              _IssueSummary(issues: issues),
            ],
            if (metadataUnavailable) ...[
              const SizedBox(height: 8),
              _RepairEligibilityNotice(
                key: ValueKey(
                  'question-repair-metadata-unavailable-${item.originalIndex}',
                ),
                icon: Icons.error_outline,
                color: Colors.redAccent,
                message: '审核元数据不可用，无法判断 AI 修补资格，请人工核对或重试。',
              ),
            ],
            if (reviewOnly) ...[
              const SizedBox(height: 8),
              _RepairEligibilityNotice(
                key: ValueKey(
                  'question-repair-review-only-${item.originalIndex}',
                ),
                icon: Icons.person_search_outlined,
                color: Colors.orangeAccent,
                message: '本题存在解析风险，需要人工核对；当前不支持 AI 自动修补。',
              ),
            ],
            if (metadataAvailable &&
                item.metadata.repairCandidateCodes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Chip(
                key: ValueKey(
                  'question-repair-candidate-${item.originalIndex}',
                ),
                avatar: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('需要结构修复'),
              ),
            ],
            if (answerDistillationCandidate) ...[
              const SizedBox(height: 8),
              if (answerDistillationStatus == 'ai_rejected' ||
                  answerDistillationStatus == 'ai_failed') ...[
                Chip(
                  key: ValueKey(
                    'answer-distillation-status-${item.originalIndex}',
                  ),
                  avatar: Icon(
                    answerDistillationStatus == 'ai_failed'
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 16,
                  ),
                  label: Text(
                    answerDistillationStatus == 'ai_failed'
                        ? '生成失败，可重试'
                        : '未找到可安全提炼的答案',
                  ),
                ),
                const SizedBox(height: 4),
              ],
              OutlinedButton.icon(
                key: ValueKey(
                  'answer-distillation-single-${item.originalIndex}',
                ),
                onPressed: onAnswerDistillation,
                icon: answerDistillationInProgress
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 16),
                label: Text(
                  answerDistillationInProgress ? '正在生成答案' : '生成标准答案',
                ),
              ),
            ],
            if (proofExplanationRecognized) ...[
              const SizedBox(height: 8),
              const Chip(
                avatar: Icon(Icons.verified_outlined, size: 16),
                label: Text('证明过程已识别'),
              ),
            ],
            if (reviewRepairEligible) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: ValueKey(
                  'review-ai-repair-${item.originalIndex}',
                ),
                onPressed: onReviewRepair,
                icon: reviewRepairInProgress
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high_outlined, size: 16),
                label: Text(reviewRepairInProgress
                    ? '正在生成修补建议'
                    : reviewRepairProposalReady
                        ? '查看 AI 修补建议'
                        : 'AI 修补'),
              ),
            ],
            // Per-question keep/discard is meaningful only where a
            // document-level policy choice existed. New imports retain every
            // explanation, so they expose no retention control on the card.
            if (onExplanationRetentionChanged != null &&
                (question.type == QuestionType.singleChoice ||
                    question.type == QuestionType.fillBlank) &&
                (question.rawExplanation?.trim().isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    key: ValueKey(
                      'question-explanation-keep-${item.originalIndex}',
                    ),
                    label: const Text('保留解析'),
                    selected: explanationRetained,
                    onSelected: (_) => onExplanationRetentionChanged!(true),
                  ),
                  FilterChip(
                    key: ValueKey(
                      'question-explanation-discard-${item.originalIndex}',
                    ),
                    label: const Text('忽略解析'),
                    selected: !explanationRetained,
                    onSelected: (_) => onExplanationRetentionChanged!(false),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _buildContent(
              context,
              question.content,
              question.content == baseline?.content ? typed?.stem : null,
            ),
            if (question.options.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (var i = 0; i < question.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: baseline != null &&
                          typed != null &&
                          question.options.length == baseline.options.length &&
                          question.options.length == typed.options.length &&
                          question.options[i] == baseline.options[i]
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${typed.options[i].label}. '),
                            Expanded(
                              child: _buildContent(context, question.options[i],
                                  typed.options[i].content),
                            ),
                          ],
                        )
                      : _buildMarkdown(context, question.options[i]),
                ),
            ],
            const Divider(height: 24),
            if (!question.hasAnswerOrExplanation &&
                typedAnswer == null &&
                typedExplanation == null)
              const _MissingAnswerNotice()
            else
              _AnswerBlock(
                standardAnswer: standardAnswer,
                explanation: explanation,
                typedAnswer: typedAnswer,
                typedExplanation: typedExplanation,
                onEditExplanation: onEditExplanation,
              ),
          ],
        ),
      ),
    );
  }

  static Widget _buildContent(
      BuildContext context, String text, RichContent? content) {
    return content == null
        ? _buildMarkdown(context, text)
        : RichContentRenderer(content: content, fontSize: 14);
  }

  static Widget _buildMarkdown(BuildContext context, String text) {
    return buildLatexWidget(
      context,
      text,
      textColor: Theme.of(context).textTheme.bodyLarge?.color,
      fontSize: 14.0,
    );
  }
}

class _IssueSummary extends StatelessWidget {
  const _IssueSummary({required this.issues});

  final List<ImportReviewIssue> issues;

  @override
  Widget build(BuildContext context) {
    final visibleIssues = issues.take(3).toList(growable: false);
    final hasError =
        issues.any((issue) => issue.severity == ImportReviewSeverity.error);
    final color = hasError ? Colors.redAccent : Colors.orangeAccent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in visibleIssues)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    issue.severity == ImportReviewSeverity.error
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      issue.message,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (issues.length > visibleIssues.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '另有 ${issues.length - visibleIssues.length} 条问题',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RepairEligibilityNotice extends StatelessWidget {
  const _RepairEligibilityNotice({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingAnswerNotice extends StatelessWidget {
  const _MissingAnswerNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(height: 4),
            Text(
              '暂无答案，导入后可编辑或使用 AI 解答',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerBlock extends StatelessWidget {
  const _AnswerBlock({
    required this.standardAnswer,
    required this.explanation,
    this.typedAnswer,
    this.typedExplanation,
    this.onEditExplanation,
  });

  final String standardAnswer;
  final String explanation;
  final RichContent? typedAnswer;
  final RichContent? typedExplanation;
  final VoidCallback? onEditExplanation;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '标准答案：',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        ImportReviewQuestionCard._buildContent(
          context,
          standardAnswer.isEmpty ? '无' : standardAnswer,
          typedAnswer,
        ),
        if (explanation.isNotEmpty || typedExplanation != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                '解析：',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (onEditExplanation != null) ...[
                const Spacer(),
                TextButton.icon(
                  key: const ValueKey('explanation-edit-open'),
                  onPressed: onEditExplanation,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('编辑', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          ImportReviewQuestionCard._buildContent(
              context, explanation, typedExplanation),
        ],
      ],
    );
  }
}
