import 'package:flutter/material.dart';

class ImportReviewBadge {
  final String label;
  final Color backgroundColor;
  final Color textColor;

  const ImportReviewBadge({
    required this.label,
    required this.backgroundColor,
    required this.textColor,
  });
}

class ImportReviewBadgeFormatter {
  static List<ImportReviewBadge> formatRiskHints(List<String> riskHints) {
    final badges = <ImportReviewBadge>[];

    for (final hint in riskHints) {
      switch (hint) {
        case 'answer_conflict':
          badges.add(const ImportReviewBadge(
            label: '答案冲突',
            backgroundColor: Color(0xFFFFF3E0), // orange.shade50
            textColor: Colors.orange,
          ));
          break;
        case 'orphan_fragment':
          badges.add(const ImportReviewBadge(
            label: '孤立片段',
            backgroundColor: Color(0xFFFFF3E0), // orange.shade50
            textColor: Colors.orange,
          ));
          break;
        case 'answer_only_fragment':
          badges.add(const ImportReviewBadge(
            label: '答案片段',
            backgroundColor: Color(0xFFFFF3E0), // orange.shade50
            textColor: Colors.orange,
          ));
          break;
        case 'partial_question':
          badges.add(const ImportReviewBadge(
            label: '部分题目',
            backgroundColor: Color(0xFFFFF3E0), // orange.shade50
            textColor: Colors.orange,
          ));
          break;
        case 'vision_only':
          badges.add(const ImportReviewBadge(
            label: '视觉来源',
            backgroundColor: Color(0xFFE3F2FD), // blue.shade50
            textColor: Colors.blueAccent,
          ));
          break;
        case 'fused_from_text_vision':
          badges.add(const ImportReviewBadge(
            label: '图文融合',
            backgroundColor: Color(0xFFE3F2FD), // blue.shade50
            textColor: Colors.blueAccent,
          ));
          break;
        default:
          badges.add(ImportReviewBadge(
            label: hint,
            backgroundColor: Colors.grey.shade100,
            textColor: Colors.grey.shade700,
          ));
      }
    }

    return badges;
  }
}
