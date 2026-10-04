import 'dart:math';

import '../../application/training/training_contracts.dart';
import '../../application/training/training_session_contracts.dart';
import '../../core/review_engine_service.dart';
import '../../data/repositories/training_question_selection.dart';
import '../../domain/training/category_key.dart';

/// Infrastructure adapter for explicit ordinary-training launch admission.
/// Selection owns the short read snapshot; queue replacement is the sole commit
/// point. Navigation, normal attribution composition and route guards remain
/// with the future Presentation owner; StudyPlan's launcher is independent.
final class DefaultTrainingSessionApplicationService
    implements TrainingSessionApplicationService {
  DefaultTrainingSessionApplicationService({
    required TrainingQuestionSelection selection,
    required ReviewEngineService reviewEngine,
    Random Function()? randomFactory,
    DateTime Function()? clock,
  })  : _selection = selection,
        _engine = reviewEngine,
        _randomFactory = randomFactory ?? Random.new,
        _clock = clock ?? DateTime.now;

  final TrainingQuestionSelection _selection;
  final ReviewEngineService _engine;
  final Random Function() _randomFactory;
  final DateTime Function() _clock;

  @override
  Future<TrainingSessionLaunchResult> startNew(
      TrainingContentTarget target) async {
    try {
      return _commit(
          await _selection.selectNewTarget(target, random: _randomFactory()));
    } catch (_) {
      return const TrainingSessionUnavailable();
    }
  }

  @override
  Future<TrainingSessionLaunchResult> startCategoryReview(
      CategoryKey categoryKey) async {
    try {
      final capturedNow = _clock().millisecondsSinceEpoch ~/ 1000;
      return _commit(await _selection.selectCategoryReview(categoryKey,
          nowUnixSeconds: capturedNow));
    } catch (_) {
      return const TrainingSessionUnavailable();
    }
  }

  TrainingSessionLaunchResult _commit(TrainingQuestionSelectionResult result) =>
      switch (result) {
        TrainingQuestionSelectionSuccess(:final questions) => () {
            final ready = TrainingSessionReady(questions.length);
            _engine.initPreparedStudySession(questions);
            return ready;
          }(),
        TrainingQuestionSelectionEmpty() => const TrainingSessionEmpty(),
        TrainingQuestionSelectionStaleConfiguration() =>
          const TrainingSessionStaleConfiguration(),
        TrainingQuestionSelectionUnavailable() =>
          const TrainingSessionUnavailable(),
      };
}
