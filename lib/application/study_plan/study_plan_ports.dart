/// SPL-1 Application-owned read seams and bounded failure types.
///
/// The planning port and the candidate query port are producer-neutral: they
/// never expose SQL rows, `Map` values, repository data models, the
/// `Database`, or raw exceptions across the Application boundary.
library;

import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';

/// Result of one planning-context read.
sealed class StudyPlanPlanningAdmission {
  const StudyPlanPlanningAdmission();
}

/// The target bank is admitted for the source scope and the typed planning
/// context may be used to build a deterministic preview.
final class StudyPlanPlanningAdmitted extends StudyPlanPlanningAdmission {
  const StudyPlanPlanningAdmitted(this.context);

  final StudyPlanPlanningContext context;
}

/// Shared bounded non-enumerating denial.
///
/// Missing bank, empty bank, missing Project, missing `project_banks`
/// relation, and unauthorized targets all map to this one shape so a
/// staging-facing caller can never distinguish "bank exists but is outside
/// this project" from "bank does not exist". Carries no target identity or
/// content.
final class StudyPlanPlanningUnavailable extends StudyPlanPlanningAdmission {
  const StudyPlanPlanningUnavailable();
}

/// Application-owned planning admission/read seam.
abstract interface class StudyPlanPlanningPort {
  /// Loads the typed planning context for [bankName] under [sourceScope] at
  /// [now], or returns the shared unavailable denial.
  ///
  /// Global scope admits any real bank with at least one question; a
  /// Learning Space scope additionally requires the current
  /// `project_banks(projectId, bankName)` relation. No Project ownership is
  /// created or implied.
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  });
}

/// Bounded candidate batch of the three deterministic pools.
///
/// Each pool is ordered by its frozen rule and capped at `maxPerPool` rows:
///
/// - due: `next_review_time ASC, storageId ASC`;
/// - weak: `lapses DESC, difficulty DESC, storageId ASC`;
/// - new: `storageId ASC`.
///
/// Overlap between pools is allowed by contract; selected-storageId dedup is
/// a selection-time (SPL-1-U0) concern.
final class StudyPlanCandidateBatch {
  const StudyPlanCandidateBatch({
    required this.due,
    required this.weak,
    required this.newPool,
  });

  final List<StudyPlanCandidate> due;
  final List<StudyPlanCandidate> weak;
  final List<StudyPlanCandidate> newPool;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanCandidateBatch &&
            _same(due, other.due) &&
            _same(weak, other.weak) &&
            _same(newPool, other.newPool);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(due),
        Object.hashAll(weak),
        Object.hashAll(newPool),
      );

  static bool _same(List<StudyPlanCandidate> a, List<StudyPlanCandidate> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Application-owned producer-neutral candidate query seam.
abstract interface class StudyPlanCandidateQueryPort {
  /// Loads the bounded, deterministic candidate pools for [bankName] at
  /// [nowUnixSeconds].
  ///
  /// [maxPerPool] must be 1..200. The bound is mathematically sufficient:
  /// `dailyTarget` is capped at 200 and selection consumes the ordered pools
  /// with mandatory storageId dedup, so every possible final session of at
  /// most 200 distinct candidates is a prefix of the top-200 of each pool.
  /// Reading more can never change the selection, so candidate reads can
  /// never become an unbounded bank dump.
  Future<StudyPlanCandidateBatch> loadCandidates({
    required String bankName,
    required int nowUnixSeconds,
    required int maxPerPool,
  });
}

/// Fixed repository read failures. Never carries SQL, paths, or raw causes.
enum StudyPlanReadFailure { unavailable }

final class StudyPlanReadException implements Exception {
  const StudyPlanReadException(this.failure);

  final StudyPlanReadFailure failure;

  @override
  String toString() {
    return switch (failure) {
      StudyPlanReadFailure.unavailable =>
        'StudyPlanReadException(unavailable): the study-plan data source is '
            'temporarily unavailable.',
    };
  }
}

/// Bounded Application failure categories aligned with the SPL-1 P0 and D1
/// contracts.
enum StudyPlanFailure {
  invalidPlan,
  targetUnavailable,
  staleScope,
  staleActivePlan,
  alreadyActive,
  superseded,
  persistenceFailed,
  temporarilyUnavailable,
  internalError,
}

final class StudyPlanException implements Exception {
  const StudyPlanException(this.failure);

  final StudyPlanFailure failure;

  @override
  String toString() {
    final message = switch (failure) {
      StudyPlanFailure.invalidPlan => 'The study plan request is invalid.',
      StudyPlanFailure.targetUnavailable =>
        'The study plan target is not available.',
      StudyPlanFailure.staleScope =>
        'The study plan source scope is no longer valid.',
      StudyPlanFailure.staleActivePlan =>
        'The active study plan has changed or is no longer present.',
      StudyPlanFailure.alreadyActive =>
        'An active study plan is already present.',
      StudyPlanFailure.superseded =>
        'The study plan draft has been superseded.',
      StudyPlanFailure.persistenceFailed =>
        'The study plan persistence operation failed.',
      StudyPlanFailure.temporarilyUnavailable =>
        'The study plan data source is temporarily unavailable.',
      StudyPlanFailure.internalError => 'An internal error occurred.',
    };
    return 'StudyPlanException(${failure.name}): $message';
  }
}

/// Result of one durable adoption commit attempt on [StudyPlanPersistencePort].
sealed class StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitResult();
}

/// The plan was successfully committed to durable storage.
final class StudyPlanPersistenceCommitSuccess
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitSuccess(this.activePlan);

  final ActiveStudyPlan activePlan;
}

/// The source conversation, message, or project scope failed admission
/// revalidation during the adoption transaction.
final class StudyPlanPersistenceCommitStaleScope
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitStaleScope();
}

/// The target question bank is missing or empty.
final class StudyPlanPersistenceCommitTargetUnavailable
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitTargetUnavailable();
}

/// No-active CAS failed because an active plan already exists.
final class StudyPlanPersistenceCommitAlreadyActive
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitAlreadyActive();
}

/// Replacement CAS failed because the existing active plan id does not match
/// the expected plan id.
final class StudyPlanPersistenceCommitStaleActivePlan
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitStaleActivePlan();
}

/// An unexpected persistence failure occurred.
final class StudyPlanPersistenceCommitFailed
    extends StudyPlanPersistenceCommitResult {
  const StudyPlanPersistenceCommitFailed();
}

/// Result of one stop attempt on [StudyPlanPersistencePort].
sealed class StudyPlanPersistenceStopResult {
  const StudyPlanPersistenceStopResult();
}

/// The active study plan was successfully deleted.
final class StudyPlanPersistenceStopSuccess
    extends StudyPlanPersistenceStopResult {
  const StudyPlanPersistenceStopSuccess();
}

/// Stop CAS failed because no active plan exists or the active plan id does
/// not match the expected plan id.
final class StudyPlanPersistenceStopStaleActivePlan
    extends StudyPlanPersistenceStopResult {
  const StudyPlanPersistenceStopStaleActivePlan();
}

/// An unexpected persistence failure occurred.
final class StudyPlanPersistenceStopFailed
    extends StudyPlanPersistenceStopResult {
  const StudyPlanPersistenceStopFailed();
}

/// Application-owned durable study plan persistence seam.
abstract interface class StudyPlanPersistencePort {
  Future<ActiveStudyPlan?> loadActivePlan();

  Future<StudyPlanPersistenceCommitResult> commitAdoption({
    required String planId,
    required String bankName,
    String? goal,
    required int dailyTarget,
    required StudyPlanPriority priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required ConversationScope sourceScope,
    required DateTime adoptedAt,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  });

  Future<StudyPlanPersistenceStopResult> stopActivePlan({
    required String expectedPlanId,
  });
}
