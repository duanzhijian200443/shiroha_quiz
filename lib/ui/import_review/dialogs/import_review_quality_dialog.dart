import 'package:flutter/material.dart';

/// Confirmation dialog shown before committing an import whose review report
/// still carries quality problems.
///
/// The page decides when this dialog appears and what "continue" does.
class ImportReviewQualityDialog extends StatelessWidget {
  const ImportReviewQualityDialog({
    super.key,
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.confirmIsDanger,
    required this.onContinue,
  });

  final String title;
  final String message;
  final String cancelLabel;
  final String confirmLabel;
  final bool confirmIsDanger;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(cancelLabel, style: const TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: confirmIsDanger
                ? Colors.redAccent
                : Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () {
            Navigator.pop(context);
            onContinue();
          },
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
