import '../../domain/training/category_key.dart';
import '../home_training_result.dart';
import 'training_contracts.dart';

sealed class TrainingSessionLaunchResult {
  const TrainingSessionLaunchResult();
}

/// Ready acknowledges a fully prepared queue through the existing non-preview
/// seam; no Question body or second queue representation is exposed here.
final class TrainingSessionReady extends TrainingSessionLaunchResult {
  TrainingSessionReady(this.questionCount) {
    requireHomeTrainingInput(questionCount > 0 && questionCount <= 100);
  }
  final int questionCount;
}

final class TrainingSessionEmpty extends TrainingSessionLaunchResult {
  const TrainingSessionEmpty();
}

final class TrainingSessionStaleConfiguration
    extends TrainingSessionLaunchResult {
  const TrainingSessionStaleConfiguration();
}

final class TrainingSessionUnavailable extends TrainingSessionLaunchResult {
  const TrainingSessionUnavailable();
}

/// Explicit user-action admission only. Implementations re-read target revision,
/// complete bindings, eligibility and ReviewState before preparing the queue.
/// Corrupt/missing typed materialization fails the entire launch. All failures
/// are zero queue replacement; no partial queue or fallback to V1/preview.
/// Both launches retain normal attribution; StudyPlan remains independent.
abstract interface class TrainingSessionApplicationService {
  Future<TrainingSessionLaunchResult> startNew(TrainingContentTarget target);

  /// Complete Category-scoped due pool, independent of current content/weights.
  /// Initial review limit remains 40; captured current time governs due status.
  Future<TrainingSessionLaunchResult> startCategoryReview(
      CategoryKey categoryKey);
}
