/// Initial candidate pool; grading and subsequent FSRS requeues are unchanged.
enum StudySessionPool { mixed, newQuestions, dueReviews }

sealed class StudySessionLaunchResult {
  const StudySessionLaunchResult();
}

final class StudySessionReady extends StudySessionLaunchResult {
  const StudySessionReady(this.questionCount);
  final int questionCount;
}

final class StudySessionEmpty extends StudySessionLaunchResult {
  const StudySessionEmpty();
}

/// Safe failure: no raw storage errors and no partial replacement queue.
final class StudySessionUnavailable extends StudySessionLaunchResult {
  const StudySessionUnavailable();
}

abstract interface class StudySessionLauncher {
  Future<StudySessionLaunchResult> launch({
    required String bankName,
    required StudySessionPool pool,
  });
}
