import 'import_review_report.dart';
import 'import_review_item.dart';
import 'import_review_analyzer.dart';
import 'import_review_issue.dart';

class ImportReviewReportBuilder {
  static ImportReviewReport build(
    List<ImportReviewItem> items,
    ImportReviewAnalyzerResult analyzerResult,
  ) {
    // 1. Group issues by questionIndex (current index in items)
    final Map<int, List<ImportReviewIssue>> issuesByItem = {};
    for (final issue in analyzerResult.issues) {
      issuesByItem.putIfAbsent(issue.questionIndex, () => []).add(issue);
    }

    // 2. Count info severity issues
    int infoCount = 0;
    for (final issue in analyzerResult.issues) {
      if (issue.severity == ImportReviewSeverity.info) {
        infoCount++;
      }
    }

    // 3. Count issueCodeCounts
    final Map<ImportReviewIssueCode, int> issueCodeCounts = {};
    for (final issue in analyzerResult.issues) {
      issueCodeCounts[issue.code] = (issueCodeCounts[issue.code] ?? 0) + 1;
    }

    // 4. Count riskHintCounts and sourceCounts
    final Map<String, int> riskHintCounts = {};
    final Map<String, int> sourceCounts = {};
    for (final item in items) {
      // Risk Hints
      for (final hint in item.metadata.riskHints) {
        riskHintCounts[hint] = (riskHintCounts[hint] ?? 0) + 1;
      }
      // Source
      final src =
          item.metadata.source.isEmpty ? 'unknown' : item.metadata.source;
      sourceCounts[src] = (sourceCounts[src] ?? 0) + 1;
    }

    // 5. Build highRiskItems
    final List<ImportReviewReportItem> highRiskItems = [];
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final itemIssues = issuesByItem[i] ?? const [];
      final hasIssues = itemIssues.isNotEmpty;
      final hasRiskHints = item.metadata.riskHints.isNotEmpty;

      if (hasIssues || hasRiskHints) {
        // Determine max severity
        ImportReviewSeverity maxSeverity = ImportReviewSeverity.info;
        if (itemIssues.isNotEmpty) {
          if (itemIssues
              .any((issue) => issue.severity == ImportReviewSeverity.error)) {
            maxSeverity = ImportReviewSeverity.error;
          } else if (itemIssues
              .any((issue) => issue.severity == ImportReviewSeverity.warning)) {
            maxSeverity = ImportReviewSeverity.warning;
          }
        }

        // Get issue codes
        final List<ImportReviewIssueCode> codes =
            itemIssues.map((issue) => issue.code).toList();

        // Content preview with safe fallback
        final rawContent = item.draft.content.trim();
        final contentPreview = rawContent.isEmpty
            ? '无题干描述'
            : (rawContent.length > 30
                ? '${rawContent.substring(0, 30)}...'
                : rawContent);

        highRiskItems.add(ImportReviewReportItem(
          originalIndex: item.originalIndex,
          displayIndex: i + 1,
          contentPreview: contentPreview,
          issueCodes: codes,
          riskHints: item.metadata.riskHints,
          maxSeverity: maxSeverity,
        ));
      }
    }

    // Sort highRiskItems: error > warning > info, then by displayIndex
    highRiskItems.sort((a, b) {
      final aPriority = _getSeverityPriority(a.maxSeverity);
      final bPriority = _getSeverityPriority(b.maxSeverity);
      if (aPriority != bPriority) {
        return bPriority.compareTo(aPriority); // Descending
      }
      return a.displayIndex.compareTo(b.displayIndex); // Ascending
    });

    return ImportReviewReport(
      totalCount: items.length,
      qualityScore: analyzerResult.summary.qualityScore,
      errorCount: analyzerResult.summary.errorCount,
      warningCount: analyzerResult.summary.warningCount,
      infoCount: infoCount,
      missingAnswerCount: analyzerResult.summary.missingAnswerCount,
      choiceIssueCount: analyzerResult.summary.choiceIssueCount,
      issueCodeCounts: issueCodeCounts,
      riskHintCounts: riskHintCounts,
      sourceCounts: sourceCounts,
      highRiskItems: highRiskItems,
    );
  }

  static int _getSeverityPriority(ImportReviewSeverity severity) {
    switch (severity) {
      case ImportReviewSeverity.error:
        return 3;
      case ImportReviewSeverity.warning:
        return 2;
      case ImportReviewSeverity.info:
        return 1;
    }
  }
}
