import 'import_review_analyzer.dart';
import 'import_review_issue.dart';

/// Shared hard-block policy for structurally unsafe import drafts.
///
/// Missing answers remain reviewable because stem-only imports intentionally
/// omit answer-bearing fields.
class ImportReviewBlockingPolicy {
  const ImportReviewBlockingPolicy._();

  static const String reasonCode = 'invalid_question_structure';

  static const Set<ImportReviewIssueCode> _blockingCodes = {
    ImportReviewIssueCode.missingStem,
    ImportReviewIssueCode.choiceWithoutOptions,
    ImportReviewIssueCode.choiceAnswerNotInOptions,
    ImportReviewIssueCode.typeOptionsMismatch,
  };

  static List<ImportReviewIssue> blockingIssues(
    ImportReviewAnalyzerResult analysis,
  ) {
    return analysis.issues
        .where((issue) => _blockingCodes.contains(issue.code))
        .toList(growable: false);
  }

  static bool isBlocked(ImportReviewAnalyzerResult analysis) =>
      blockingIssues(analysis).isNotEmpty;
}
