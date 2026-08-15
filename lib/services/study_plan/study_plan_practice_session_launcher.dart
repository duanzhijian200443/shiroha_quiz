/// Narrow SPL-1-U0 Practice session adapter.
///
/// Bridges the Application selection boundary (ordered storage IDs only) to
/// the existing Practice interaction:
///
/// ```text
/// ordered storage IDs
/// -> ReviewRepository exact-order materialization
/// -> ReviewEngineService prepared session queue
/// -> existing PracticePage normal review mode
/// ```
///
/// This adapter is deliberately narrow: it never selects candidates, never
/// queries the StudyPlan, never writes review state, never changes FSRS, and
/// never persists selected IDs. The Presentation layer never decodes database
/// rows itself.
library;

import '../../core/review_engine_service.dart';
import '../../data/repositories/review_repository.dart';

/// Result of one 特训 session launch attempt.
sealed class StudyPlanPracticeLaunchResult {
  const StudyPlanPracticeLaunchResult();
}

/// The exact ordered session queue was injected into the review engine and
/// PracticePage may open in normal review mode.
final class StudyPlanPracticeLaunchSuccess
    extends StudyPlanPracticeLaunchResult {
  const StudyPlanPracticeLaunchSuccess(this.questionCount);

  final int questionCount;
}

/// Bounded preparation failure: missing/corrupt selected IDs, engine
/// unavailability, or any database failure. Zero partial queue was injected;
/// the user may press 开始特训 again to obtain a fresh selection.
final class StudyPlanPracticeLaunchFailed
    extends StudyPlanPracticeLaunchResult {
  const StudyPlanPracticeLaunchFailed();
}

class StudyPlanPracticeSessionLauncher {
  StudyPlanPracticeSessionLauncher({
    ReviewRepository? reviewRepository,
    ReviewEngineService? reviewEngine,
  })  : _reviewRepository = reviewRepository ?? ReviewRepository.instance,
        _reviewEngine = reviewEngine ?? ReviewEngineService();

  final ReviewRepository _reviewRepository;
  final ReviewEngineService _reviewEngine;

  /// Materializes [selectedStorageIds] in the exact requested order and
  /// injects them as the prepared session queue of the review engine.
  ///
  /// On any bounded failure the current engine queue is left untouched
  /// (zero partial prepared queue).
  Future<StudyPlanPracticeLaunchResult> launch(
    List<String> selectedStorageIds,
  ) async {
    if (selectedStorageIds.isEmpty) {
      return const StudyPlanPracticeLaunchFailed();
    }
    final materialization = await _reviewRepository.materializeStudyPlanSession(
      selectedStorageIds,
    );
    return switch (materialization) {
      StudyPlanSessionMaterializationSuccess(:final questions) => () {
          _reviewEngine.initPreparedStudySession(questions);
          return StudyPlanPracticeLaunchSuccess(questions.length);
        }(),
      StudyPlanSessionMaterializationUnavailable() =>
        const StudyPlanPracticeLaunchFailed(),
    };
  }
}
