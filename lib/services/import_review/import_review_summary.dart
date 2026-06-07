class ImportReviewSummary {
  final int totalCount;
  final int errorCount;
  final int warningCount;
  final int missingAnswerCount;
  final int choiceIssueCount;
  final int qualityScore;

  const ImportReviewSummary({
    required this.totalCount,
    required this.errorCount,
    required this.warningCount,
    required this.missingAnswerCount,
    required this.choiceIssueCount,
    required this.qualityScore,
  });
}
