enum StudyActivityScene {
  ordinaryPractice,
  categoryReview,
  studyPlanPractice,
  mockExam,

  /// Definition only; no entry or lifecycle activation in Home Training V3.
  singleQuestionStudy,
}

enum StudyActivityLifecycleStatus { active, paused, ended, interrupted }

enum StudyActivityEndReason {
  exited,
  queueFinished,
  submitted,
  processInterrupted,
  snapshotInterrupted,
}

/// Frozen status x endedAt x reason matrix. No timers, routes or persistence.
final class StudyActivityLifecycle {
  StudyActivityLifecycle({
    required this.status,
    required this.endedAtUtcMs,
    required this.endReason,
  }) {
    final valid = switch (status) {
      StudyActivityLifecycleStatus.active ||
      StudyActivityLifecycleStatus.paused =>
        endedAtUtcMs == null && endReason == null,
      StudyActivityLifecycleStatus.ended => endedAtUtcMs != null &&
          (endReason == StudyActivityEndReason.exited ||
              endReason == StudyActivityEndReason.queueFinished ||
              endReason == StudyActivityEndReason.submitted),
      StudyActivityLifecycleStatus.interrupted => endedAtUtcMs != null &&
          (endReason == StudyActivityEndReason.processInterrupted ||
              endReason == StudyActivityEndReason.snapshotInterrupted),
    };
    if (!valid || (endedAtUtcMs != null && endedAtUtcMs! < 0)) {
      throw const FormatException('Invalid StudyActivity lifecycle.');
    }
  }
  final StudyActivityLifecycleStatus status;
  final int? endedAtUtcMs;
  final StudyActivityEndReason? endReason;

  bool get isTerminal =>
      status == StudyActivityLifecycleStatus.ended ||
      status == StudyActivityLifecycleStatus.interrupted;
}
