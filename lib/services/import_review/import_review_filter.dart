import 'import_review_item.dart';
import 'import_review_issue.dart';
import 'import_review_analyzer.dart';
import 'import_review_visible_item.dart';

enum ImportReviewFilter {
  all,
  errorsOnly,
  warningsOnly,
  missingAnswer,
  choiceIssues,
  fusionRisks,
  answerConflict,
  orphanOrAnswerOnly,
  visionOnly,
  fused,
}

enum ImportReviewSort {
  originalOrder,
  riskFirst,
  missingFieldsFirst,
  sourceRiskFirst,
}

class ImportReviewFilterService {
  static List<ImportReviewVisibleItem> apply({
    required List<ImportReviewItem> items,
    required ImportReviewAnalyzerResult analysis,
    required ImportReviewFilter filter,
    required ImportReviewSort sort,
  }) {
    // 1. Map to ImportReviewVisibleItem
    final visibleItems = <ImportReviewVisibleItem>[];
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final itemIssues =
          analysis.issues.where((issue) => issue.questionIndex == i).toList();
      visibleItems.add(ImportReviewVisibleItem(
        item: item,
        canonicalIndex: i,
        issues: itemIssues,
      ));
    }

    // 2. Filter
    final filtered = visibleItems.where((vi) {
      switch (filter) {
        case ImportReviewFilter.all:
          return true;
        case ImportReviewFilter.errorsOnly:
          return vi.issues
              .any((issue) => issue.severity == ImportReviewSeverity.error);
        case ImportReviewFilter.warningsOnly:
          return vi.issues
              .any((issue) => issue.severity == ImportReviewSeverity.warning);
        case ImportReviewFilter.missingAnswer:
          return vi.issues.any(
              (issue) => issue.code == ImportReviewIssueCode.missingAnswer);
        case ImportReviewFilter.choiceIssues:
          return vi.issues.any((issue) => _isChoiceIssue(issue.code));
        case ImportReviewFilter.fusionRisks:
          return vi.issues.any((issue) =>
              issue.code == ImportReviewIssueCode.answerConflict ||
              issue.code == ImportReviewIssueCode.orphanFragment ||
              issue.code == ImportReviewIssueCode.answerOnlyFragment ||
              issue.code == ImportReviewIssueCode.partialQuestion);
        case ImportReviewFilter.answerConflict:
          return vi.issues.any(
              (issue) => issue.code == ImportReviewIssueCode.answerConflict);
        case ImportReviewFilter.orphanOrAnswerOnly:
          return vi.issues.any((issue) =>
              issue.code == ImportReviewIssueCode.orphanFragment ||
              issue.code == ImportReviewIssueCode.answerOnlyFragment);
        case ImportReviewFilter.visionOnly:
          return vi.item.metadata.riskHints.contains('vision_only');
        case ImportReviewFilter.fused:
          return vi.item.metadata.source == 'fused';
      }
    }).toList();

    // 3. Sort
    filtered.sort((a, b) {
      switch (sort) {
        case ImportReviewSort.originalOrder:
          return a.item.originalIndex.compareTo(b.item.originalIndex);

        case ImportReviewSort.riskFirst:
          final rankA = _getRiskRank(a.issues);
          final rankB = _getRiskRank(b.issues);
          if (rankA != rankB) {
            return rankB.compareTo(rankA); // higher risk first
          }
          if (a.issues.length != b.issues.length) {
            return b.issues.length
                .compareTo(a.issues.length); // more issues first
          }
          return a.item.originalIndex.compareTo(b.item.originalIndex);

        case ImportReviewSort.missingFieldsFirst:
          final rankA = _getMissingFieldsRank(a.issues);
          final rankB = _getMissingFieldsRank(b.issues);
          if (rankA != rankB) {
            return rankB.compareTo(rankA); // higher rank first
          }
          return a.item.originalIndex.compareTo(b.item.originalIndex);

        case ImportReviewSort.sourceRiskFirst:
          final rankA = _getSourceRiskRank(a.item.metadata.riskHints, a.issues);
          final rankB = _getSourceRiskRank(b.item.metadata.riskHints, b.issues);
          if (rankA != rankB) {
            return rankB.compareTo(rankA); // higher rank first
          }
          return a.item.originalIndex.compareTo(b.item.originalIndex);
      }
    });

    return filtered;
  }

  static int _getRiskRank(List<ImportReviewIssue> issues) {
    if (issues.any((i) => i.severity == ImportReviewSeverity.error)) {
      return 3;
    }
    if (issues.any((i) => i.severity == ImportReviewSeverity.warning)) {
      return 2;
    }
    if (issues.any((i) => i.severity == ImportReviewSeverity.info)) {
      return 1;
    }
    return 0;
  }

  static int _getMissingFieldsRank(List<ImportReviewIssue> issues) {
    int rank = 0;
    if (issues.any((i) => i.code == ImportReviewIssueCode.missingStem)) {
      rank += 4;
    }
    if (issues.any((i) => i.code == ImportReviewIssueCode.missingAnswer)) {
      rank += 2;
    }
    if (issues.any((issue) => _isChoiceIssue(issue.code))) {
      rank += 1;
    }
    return rank;
  }

  static int _getSourceRiskRank(
      List<String> riskHints, List<ImportReviewIssue> issues) {
    if (riskHints.contains('answer_conflict')) return 4;
    if (riskHints.contains('answer_leaked_to_content') ||
        riskHints.contains('low_quality_vision_parse') ||
        riskHints.contains('q_num_drift') ||
        riskHints.contains('duplicate_q_num')) {
      return 4;
    }
    if (riskHints.contains('orphan_fragment') ||
        riskHints.contains('answer_only_fragment') ||
        riskHints.contains('partial_question') ||
        riskHints.contains('missing_answer_or_explanation') ||
        riskHints.contains('type_options_mismatch')) {
      return 3;
    }
    if (riskHints.contains('vision_only')) return 2;
    if (riskHints.contains('fused_from_text_vision')) return 1;
    return 0;
  }

  static bool _isChoiceIssue(ImportReviewIssueCode code) {
    return code == ImportReviewIssueCode.choiceWithoutOptions ||
        code == ImportReviewIssueCode.choiceAnswerNotInOptions ||
        code == ImportReviewIssueCode.choiceAnswerNeedsReview ||
        code == ImportReviewIssueCode.typeOptionsMismatch;
  }

  static Map<ImportReviewFilter, int> countByFilter({
    required List<ImportReviewItem> items,
    required ImportReviewAnalyzerResult analysis,
  }) {
    final counts = <ImportReviewFilter, int>{};
    for (final filter in ImportReviewFilter.values) {
      counts[filter] = apply(
        items: items,
        analysis: analysis,
        filter: filter,
        sort: ImportReviewSort.originalOrder,
      ).length;
    }
    return counts;
  }
}
