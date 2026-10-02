import 'package:flutter/material.dart';

/// Bottom commit bar shown outside selection mode.
class ImportReviewCommitBar extends StatelessWidget {
  const ImportReviewCommitBar({
    super.key,
    required this.itemCount,
    required this.isSaving,
    required this.isBlockedByQualityGate,
    required this.isDistillingAnswers,
    required this.blockedLabel,
    required this.onCommit,
  });

  final int itemCount;
  final bool isSaving;
  final bool isBlockedByQualityGate;
  final bool isDistillingAnswers;

  /// Label shown while the quality gate blocks the commit action.
  final String blockedLabel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor:
                isBlockedByQualityGate ? Colors.grey : theme.primaryColor,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : (isBlockedByQualityGate
                  ? const Icon(Icons.block)
                  : const Icon(Icons.check_circle_outline)),
          label: Text(
              isBlockedByQualityGate
                  ? blockedLabel
                  : (isSaving ? '正在入库...' : '确认无误，将 $itemCount 题收入题库'),
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          onPressed: (isSaving || isBlockedByQualityGate || isDistillingAnswers)
              ? null
              : onCommit,
        ),
      ),
    );
  }
}
