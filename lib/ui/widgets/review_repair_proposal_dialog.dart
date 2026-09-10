import 'package:flutter/material.dart';

import '../../data/models/question_draft.dart';
import '../../services/import_review/review_repair_edit.dart';
import '../../services/import_review/review_repair_service.dart';

/// Chinese label for one repair field, used by the review card and the dialog.
String reviewRepairFieldLabel(ReviewRepairField field) {
  return switch (field) {
    ReviewRepairField.content => '题干',
    ReviewRepairField.options => '选项',
    ReviewRepairField.standardAnswer => '标准答案',
    ReviewRepairField.explanation => '解析',
  };
}

/// Proposal-first review of an AI repair.
///
/// Shows which fields change, the current text and the suggested text, plus the
/// local validation outcome. It returns `true` only when the user chooses to
/// apply; dismissing the dialog is a cancel with zero mutation.
class ReviewRepairProposalDialog extends StatelessWidget {
  const ReviewRepairProposalDialog({super.key, required this.proposal});

  final ReviewRepairProposal proposal;

  static const Key dialogKey = Key('review-repair-dialog');
  static const Key cancelKey = Key('review-repair-cancel');
  static const Key applyKey = Key('review-repair-apply');

  static Key fieldKey(ReviewRepairField field) =>
      Key('review-repair-field-${field.wireKey}');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: dialogKey,
      title: Text('AI 修补建议 · 第 ${proposal.questionNumber} 题'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '修改字段：${proposal.changedFields.map(reviewRepairFieldLabel).join('、')}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                '触发问题：${proposal.request.target.triggerCodes.join('、')}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 12),
              for (final field in proposal.changedFields)
                _FieldDiff(
                  key: fieldKey(field),
                  field: field,
                  original: _originalText(field),
                  proposed: _proposedText(field),
                ),
              const SizedBox(height: 12),
              Text(
                '验证',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: theme.primaryColor,
                ),
              ),
              const SizedBox(height: 4),
              _ValidationLine(
                passed: proposal.validation.structuralValid,
                label: '结构检查通过',
              ),
              _ValidationLine(
                passed: proposal.validation.latexValid,
                label: 'LaTeX 检查通过',
              ),
              if (proposal.validation.remainingDiagnostics.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '仍存在的问题：'
                  '${proposal.validation.remainingDiagnostics.join('、')}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.orange,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: applyKey,
          onPressed: proposal.applicable
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('应用修补'),
        ),
      ],
    );
  }

  String _originalText(ReviewRepairField field) =>
      _textFor(field, proposal.originalDraft);

  String _proposedText(ReviewRepairField field) =>
      _textFor(field, proposal.proposedDraft);

  String _textFor(ReviewRepairField field, QuestionDraft draft) {
    return switch (field) {
      ReviewRepairField.content => draft.content,
      ReviewRepairField.options => draft.options.join('\n'),
      ReviewRepairField.standardAnswer => draft.standardAnswer,
      ReviewRepairField.explanation => draft.explanation,
    };
  }
}

class _FieldDiff extends StatelessWidget {
  const _FieldDiff({
    super.key,
    required this.field,
    required this.original,
    required this.proposed,
  });

  final ReviewRepairField field;
  final String original;
  final String proposed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reviewRepairFieldLabel(field),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          _DiffBlock(label: '原内容', text: original, color: Colors.grey),
          const SizedBox(height: 6),
          _DiffBlock(
            label: '建议',
            text: proposed,
            color: Theme.of(context).primaryColor,
          ),
        ],
      ),
    );
  }
}

class _DiffBlock extends StatelessWidget {
  const _DiffBlock({
    required this.label,
    required this.text,
    required this.color,
  });

  final String label;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              child: SelectableText(
                text.isEmpty ? '（空）' : text,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValidationLine extends StatelessWidget {
  const _ValidationLine({required this.passed, required this.label});

  final bool passed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          passed ? Icons.check_circle_outline : Icons.error_outline,
          size: 14,
          color: passed ? Colors.green : Colors.redAccent,
        ),
        const SizedBox(width: 4),
        Text(
          passed ? '✓ $label' : '✗ $label',
          style: TextStyle(
            fontSize: 12,
            color: passed ? Colors.green.shade800 : Colors.redAccent,
          ),
        ),
      ],
    );
  }
}
