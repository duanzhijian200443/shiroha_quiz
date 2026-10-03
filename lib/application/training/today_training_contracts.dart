import '../../domain/training/category_key.dart';
import '../home_training_result.dart';
import 'training_contracts.dart';

final class TrainingCount {
  TrainingCount(this.value) {
    requireHomeTrainingInput(value >= 0);
  }
  final int value;
}

/// Distinct Question counts across all configured members, including 0%.
/// todayPracticedCount is distinct formally graded ReviewLog Question identity,
/// never attempt/grade/session count or inferred duration.
final class TrainingContentSummary {
  TrainingContentSummary({
    required this.totalCount,
    required this.masteredCount,
    required this.todayPracticedCount,
  }) {
    requireHomeTrainingInput(
        totalCount >= 0 && masteredCount >= 0 && todayPracticedCount >= 0);
    requireHomeTrainingInput(
        masteredCount <= totalCount && todayPracticedCount <= totalCount);
  }
  final int totalCount;
  final int masteredCount;
  final int todayPracticedCount;
}

/// One captured Application projection. A successful zero is distinct from
/// failure. Missing/unusable content has no summary/new-count success, while
/// Category review may still succeed independently. No loading/UI state,
/// quota, eligibility or FSRS calculation belongs to consumers of this DTO.
final class TodayTrainingSnapshot {
  TodayTrainingSnapshot({
    required this.selection,
    required Iterable<CategoryKey> categories,
    required this.newCount,
    required this.categoryReviewCount,
    required this.summary,
  }) : categories = List.unmodifiable(categories) {
    requireHomeTrainingInput(
        this.categories.toSet().length == this.categories.length);
    requireHomeTrainingInput(selection.categoryKey == null ||
        this.categories.contains(selection.categoryKey));
    if (selection.state != TrainingCurrentContentState.usable) {
      requireHomeTrainingInput(newCount is HomeTrainingFailed<TrainingCount> &&
          summary is HomeTrainingFailed<TrainingContentSummary>);
    }
    requireHomeTrainingInput(selection.categoryKey != null ||
        categoryReviewCount is HomeTrainingFailed<TrainingCount>);
  }
  final TrainingCurrentSelection selection;
  final List<CategoryKey> categories;

  /// All eligible NEW in positive-weight members, not questionLimit/queue size.
  final HomeTrainingResult<TrainingCount> newCount;
  final HomeTrainingResult<TrainingCount> categoryReviewCount;
  final HomeTrainingResult<TrainingContentSummary> summary;
}

abstract interface class TodayTrainingQuery {
  /// Read-only; selection fallback never persists, pre-samples or repairs state.
  Future<HomeTrainingResult<TodayTrainingSnapshot>> readCurrent();
}
