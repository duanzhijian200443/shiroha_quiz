import 'package:flutter/material.dart';

import '../../data/models/persisted_question.dart';
import '../models/persisted_question_view.dart';
import 'structured_content_renderer.dart';

/// Renders one [PersistedQuestionView]. The card never touches the
/// repository, search, or database; typed content always goes through the
/// RichContent renderer and legacy content through the legacy renderer.
class PersistedQuestionCard extends StatelessWidget {
  const PersistedQuestionCard({
    super.key,
    required this.question,
    required this.onDelete,
    this.onEditLegacy,
    this.onRepairTypedAnswer,
  });

  final PersistedQuestionView question;
  final VoidCallback onDelete;

  /// Only non-null for legacy rows; typed rows must pass null so the editor
  /// can never be opened.
  final VoidCallback? onEditLegacy;

  /// Only non-null for typed rows: opens the typed answer-only repair
  /// screen. Legacy rows pass null.
  final VoidCallback? onRepairTypedAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? Colors.white10 : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    _TypeBadge(
                      label: _typeLabel(question.kind),
                      color: _typeColor(question.kind),
                    ),
                    if (question.isTyped) ...[
                      const SizedBox(width: 6),
                      const _TypeBadge(label: '结构化', color: Colors.teal),
                    ],
                  ],
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  onPressed: onDelete,
                  tooltip: '删除题目',
                ),
              ],
            ),
            const SizedBox(height: 12),
            RichContentFieldRenderer(
              content: question.typedStem,
              legacyText: question.legacyStem,
            ),
            if (question.options.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final option in question.options)
                _buildOption(context, option),
            ],
            const Divider(height: 24),
            _buildAnswerSection(context),
            if (question.reviewMetrics != null) ...[
              const Divider(height: 24),
              _buildReviewMetrics(question.reviewMetrics!),
            ],
            const Divider(height: 24),
            _buildEditRow(context),
            if (question.isTyped) ...[
              const SizedBox(height: 4),
              const Text(
                '结构化题目仅支持修正答案，题干与选项暂不可编辑',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOption(
    BuildContext context,
    PersistedQuestionOptionView option,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${option.label}.',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: option.typedContent != null
                ? RichContentRenderer(
                    content: option.typedContent!, fontSize: 15)
                : StructuredContentRenderer(
                    text: option.legacyText, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerSection(BuildContext context) {
    if (question.isTyped) {
      return _buildTypedAnswerSection();
    }

    final hasAnswerOrExplanation = question.legacyAnswer.isNotEmpty ||
        question.legacyExplanation.isNotEmpty;
    if (!hasAnswerOrExplanation) {
      return _legacyEmptyAnswerPrompt();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('标准答案：'),
        const SizedBox(height: 4),
        StructuredContentRenderer(
          text: question.legacyAnswer.isEmpty ? '无' : question.legacyAnswer,
          textColor: Colors.green,
        ),
        const SizedBox(height: 12),
        const _SectionLabel('解析：'),
        const SizedBox(height: 4),
        StructuredContentRenderer(
          text: question.legacyExplanation.isEmpty
              ? '无解析'
              : question.legacyExplanation,
          textColor: Colors.grey,
        ),
      ],
    );
  }

  Widget _buildTypedAnswerSection() {
    final answer = question.typedAnswer;
    final explanation = question.typedExplanation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (answer == null)
          _typedRepairPrompt()
        else ...[
          const _SectionLabel('标准答案：'),
          const SizedBox(height: 4),
          RichContentRenderer(content: answer, textColor: Colors.green),
          const SizedBox(height: 12),
          _typedRepairButton(),
        ],
        if (explanation != null) ...[
          const SizedBox(height: 12),
          const _SectionLabel('解析：'),
          const SizedBox(height: 4),
          RichContentRenderer(content: explanation, textColor: Colors.grey),
        ] else if (answer != null) ...[
          const SizedBox(height: 12),
          const _SectionLabel('解析：'),
          const SizedBox(height: 4),
          const Text('无解析', style: TextStyle(color: Colors.grey)),
        ],
      ],
    );
  }

  /// Tappable typed empty-answer prompt: opens the typed repair screen.
  Widget _typedRepairPrompt() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onRepairTypedAnswer,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(Icons.edit_note_rounded, color: Colors.orangeAccent),
              SizedBox(height: 4),
              Text(
                '暂无答案，点击手动补充',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tappable typed repair entry shown next to an existing typed answer.
  Widget _typedRepairButton() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: onRepairTypedAnswer,
        icon: const Icon(Icons.edit_note_rounded, size: 16, color: Colors.teal),
        label: const Text('修正答案', style: TextStyle(color: Colors.teal)),
      ),
    );
  }

  Widget _legacyEmptyAnswerPrompt() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEditLegacy,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(Icons.edit_note_rounded, color: Colors.orangeAccent),
              SizedBox(height: 4),
              Text(
                '✍️ 暂无答案，点击手动添加或修改',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Wrong-book surface only: the read joined `review_states`, so the card
  /// shows the lapses/difficulty/stability metrics the old page displayed.
  Widget _buildReviewMetrics(PersistedQuestionReviewMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('复习数据'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricItem(label: '错误次数', value: '${metrics.lapses}'),
            _MetricItem(
              label: '难度系数',
              value: metrics.difficulty.toStringAsFixed(2),
            ),
            _MetricItem(
              label: '稳定性',
              value: metrics.stability.toStringAsFixed(2),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditRow(BuildContext context) {
    final isTyped = question.isTyped;
    final color = isTyped ? Colors.grey : Colors.blueAccent;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton.icon(
          icon: Icon(Icons.edit_note_rounded, size: 16, color: color),
          label: Text('编辑题目', style: TextStyle(color: color)),
          onPressed: isTyped ? null : onEditLegacy,
        ),
      ],
    );
  }

  String _typeLabel(PersistedQuestionViewKind kind) {
    return switch (kind) {
      PersistedQuestionViewKind.singleChoice => '单选',
      PersistedQuestionViewKind.multipleChoice => '多选',
      PersistedQuestionViewKind.fillBlank => '填空',
      PersistedQuestionViewKind.shortAnswer => '简答',
      PersistedQuestionViewKind.unknown => '未知',
    };
  }

  Color _typeColor(PersistedQuestionViewKind kind) {
    return switch (kind) {
      PersistedQuestionViewKind.singleChoice => Colors.blueAccent,
      PersistedQuestionViewKind.multipleChoice => Colors.orangeAccent,
      PersistedQuestionViewKind.fillBlank => Colors.purpleAccent,
      PersistedQuestionViewKind.shortAnswer => Colors.greenAccent,
      PersistedQuestionViewKind.unknown => Colors.grey,
    };
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Colors.grey,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  const _MetricItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label：$value',
        style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
      ),
    );
  }
}
