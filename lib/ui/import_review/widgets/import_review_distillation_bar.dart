import 'package:flutter/material.dart';

/// Answer-distillation bar: how many questions can be completed from their
/// existing explanation, batch progress and the cancel/generate actions.
///
/// The bar renders itself away while there is nothing to generate and no
/// generation is running. It performs no distillation work itself.
class ImportReviewDistillationBar extends StatelessWidget {
  const ImportReviewDistillationBar({
    super.key,
    required this.candidateCount,
    required this.isDistillingAnswers,
    required this.cancellationRequested,
    required this.completedCount,
    required this.totalCount,
    required this.isSaving,
    required this.onGenerateAll,
    required this.onCancel,
  });

  final int candidateCount;
  final bool isDistillingAnswers;
  final bool cancellationRequested;
  final int completedCount;
  final int totalCount;
  final bool isSaving;
  final VoidCallback onGenerateAll;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (candidateCount == 0 && !isDistillingAnswers) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.primaryColor.withValues(alpha: 0.05),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 20, color: theme.primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isDistillingAnswers
                      ? '正在生成答案 $completedCount/$totalCount'
                      : '可用解析补全 $candidateCount 道主观题标准答案',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Text(
                  '仅依据已有解析提取简洁答案，不会重新解题。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isDistillingAnswers)
            TextButton(
              key: const ValueKey('answer-distillation-cancel'),
              onPressed: cancellationRequested ? null : onCancel,
              child: const Text('停止生成'),
            )
          else
            FilledButton(
              key: const ValueKey('answer-distillation-batch'),
              onPressed: isSaving ? null : onGenerateAll,
              child: Text('补全 $candidateCount 道'),
            ),
        ],
      ),
    );
  }
}
