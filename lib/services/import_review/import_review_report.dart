import 'import_review_issue.dart';

class ImportReviewReport {
  final int totalCount;
  final int qualityScore;
  final int errorCount;
  final int warningCount;
  final int infoCount;
  final int missingAnswerCount;
  final int choiceIssueCount;

  final Map<ImportReviewIssueCode, int> issueCodeCounts;
  final Map<String, int> riskHintCounts;
  final Map<String, int> sourceCounts;

  final List<ImportReviewReportItem> highRiskItems;

  ImportReviewReport({
    required this.totalCount,
    required this.qualityScore,
    required this.errorCount,
    required this.warningCount,
    required this.infoCount,
    required this.missingAnswerCount,
    required this.choiceIssueCount,
    required this.issueCodeCounts,
    required this.riskHintCounts,
    required this.sourceCounts,
    required this.highRiskItems,
  });
}

class ImportReviewReportItem {
  final int originalIndex;
  final int displayIndex;
  final String contentPreview;
  final List<ImportReviewIssueCode> issueCodes;
  final List<String> riskHints;
  final ImportReviewSeverity maxSeverity;

  ImportReviewReportItem({
    required this.originalIndex,
    required this.displayIndex,
    required this.contentPreview,
    required this.issueCodes,
    required this.riskHints,
    required this.maxSeverity,
  });
}
