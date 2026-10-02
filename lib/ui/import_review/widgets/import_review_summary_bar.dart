import 'package:flutter/material.dart';

import '../../../services/import_review/import_review_summary.dart';

/// Quality summary of the current review analysis.
///
/// Pure presentation: score, total, error, warning and missing-answer counts.
class ImportReviewSummaryBar extends StatelessWidget {
  const ImportReviewSummaryBar({super.key, required this.summary});

  final ImportReviewSummary summary;

  @override
  Widget build(BuildContext context) {
    Color scoreColor;
    if (summary.qualityScore >= 80) {
      scoreColor = Colors.green;
    } else if (summary.qualityScore >= 60) {
      scoreColor = Colors.orange;
    } else {
      scoreColor = Colors.redAccent;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).cardColor,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scoreColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${summary.qualityScore}',
              style: TextStyle(
                color: scoreColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '质量摘要 (共 ${summary.totalCount} 题)',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  '错误: ${summary.errorCount} | 警告: ${summary.warningCount} | 缺答案: ${summary.missingAnswerCount}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
