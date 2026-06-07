import 'import_review_item.dart';
import 'import_review_issue.dart';

class ImportReviewVisibleItem {
  final ImportReviewItem item;
  final int canonicalIndex;
  final List<ImportReviewIssue> issues;

  const ImportReviewVisibleItem({
    required this.item,
    required this.canonicalIndex,
    required this.issues,
  });
}
