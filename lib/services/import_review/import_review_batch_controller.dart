import '../../data/models/question_draft.dart';
import 'import_review_item.dart';

class ImportReviewBatchController {
  static List<ImportReviewItem> deleteSelected({
    required List<ImportReviewItem> items,
    required Set<int> selectedOriginalIndices,
  }) {
    if (selectedOriginalIndices.isEmpty) return items;
    return items
        .where((item) => !selectedOriginalIndices.contains(item.originalIndex))
        .toList();
  }

  static List<ImportReviewItem> changeTypeSelected({
    required List<ImportReviewItem> items,
    required Set<int> selectedOriginalIndices,
    required QuestionType targetType,
  }) {
    if (selectedOriginalIndices.isEmpty) return items;
    return items.map((item) {
      if (selectedOriginalIndices.contains(item.originalIndex)) {
        return item.copyWith(
          draft: item.draft.copyWith(type: targetType),
        );
      }
      return item;
    }).toList();
  }
}
