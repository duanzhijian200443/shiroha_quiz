import '../../application/practice/study_session_launch.dart';
import '../../core/review_engine_service.dart';
import '../../data/repositories/review_repository.dart';

/// Prepares a normal Practice session through the existing typed-aware reader.
/// Never grades or writes review state. Empty/failed reads leave the queue alone.
final class OrdinaryStudySessionLauncher implements StudySessionLauncher {
  OrdinaryStudySessionLauncher({
    required ReviewRepository reviewRepository,
    required ReviewEngineService reviewEngine,
    DateTime Function()? clock,
  })  : _repository = reviewRepository,
        _engine = reviewEngine,
        _clock = clock ?? DateTime.now;

  final ReviewRepository _repository;
  final ReviewEngineService _engine;
  final DateTime Function() _clock;

  @override
  Future<StudySessionLaunchResult> launch({
    required String bankName,
    required StudySessionPool pool,
  }) async {
    if (bankName.trim().isEmpty) return const StudySessionUnavailable();
    try {
      final questions = await _repository.getPersistedStudySessionQuestions(
        bankName,
        _clock().millisecondsSinceEpoch ~/ 1000,
        pool: pool,
      );
      if (questions.isEmpty) return const StudySessionEmpty();
      _engine.initPreparedStudySession(questions);
      return StudySessionReady(questions.length);
    } catch (_) {
      return const StudySessionUnavailable();
    }
  }
}
