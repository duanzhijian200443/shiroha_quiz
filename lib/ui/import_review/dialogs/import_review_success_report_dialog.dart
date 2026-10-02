import 'package:flutter/material.dart';

import '../../../services/import_review/import_review_report.dart';
import '../../../services/import_review/import_review_report_formatter.dart';

/// Import report shown after a successful commit.
///
/// The page owns when it is shown and what [onDone] navigates to.
class ImportReviewSuccessReportDialog extends StatelessWidget {
  const ImportReviewSuccessReportDialog({
    super.key,
    required this.report,
    required this.bankName,
    required this.folderName,
    required this.onDone,
  });

  final ImportReviewReport report;
  final String bankName;
  final String folderName;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本次导入报告',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            ImportReviewReportFormatter.formatSuccessReport(
                report, bankName, folderName),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            onDone();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
