import '../home_training_result.dart';
import 'retry_file_selection.dart';

enum TaskCenterCoarseStatus { inProgress, pendingReview, completed, error }

/// Safe projection of the existing attempt state, independent of mutable
/// infrastructure attempt enums. Exactly the seven real attempt states; the
/// coarse tab never becomes a derived eighth value.
enum TaskCenterAttemptStatus {
  queued,
  running,
  cancelRequested,
  cancelled,
  readyForReview,
  failed,
  interrupted,
}

enum TaskCenterEventKind {
  queuedAt,
  startedAt,
  parsedAt,
  completedAt,
  failedAt
}

final class TaskCenterEventTime {
  TaskCenterEventTime({required this.kind, required this.utcSeconds}) {
    requireHomeTrainingInput(
        utcSeconds == null || (kind != null && utcSeconds! >= 0));
    requireHomeTrainingInput(
        kind != TaskCenterEventKind.queuedAt || utcSeconds != null);
    requireHomeTrainingInput(
        kind != TaskCenterEventKind.completedAt || utcSeconds != null);
  }
  final TaskCenterEventKind? kind;

  /// queuedAt/completedAt project the existing created_at/completed_at
  /// authority and always carry their recorded time. Only the additive v31
  /// attempt times (startedAt/parsedAt/failedAt) may be missing and remain
  /// null, never substituted with createdAt or legacy completedAt.
  /// Cancelled/interrupted do not masquerade as failed.
  final int? utcSeconds;
}

final class TaskCenterCounts {
  TaskCenterCounts({required this.questionCount, required this.warningCount}) {
    requireHomeTrainingInput(questionCount == null || questionCount! >= 0);
    requireHomeTrainingInput(warningCount == null || warningCount! >= 0);
  }
  final int? questionCount;
  final int? warningCount;
}

final class TaskCenterActionEligibility {
  const TaskCenterActionEligibility(
      {required this.cancel,
      required this.retry,
      required this.delete,
      required this.review,
      required this.clearCompleted});
  final bool cancel;
  final bool retry;
  final bool delete;
  final bool review;
  final bool clearCompleted;
}

/// Immutable safe read projection. No raw diagnostics/error/provider content,
/// mutable task, storage row, platform object or source location is retained.
/// The coarse tab axis and the existing attempt-state axis stay independent
/// projections; action eligibility is application-supplied, never re-derived
/// here from either enum.
final class TaskCenterItem {
  TaskCenterItem({
    required this.target,
    required this.fileDisplayName,
    required this.coarseStatus,
    required this.attemptStatus,
    required this.counts,
    required this.eventTime,
    required this.actions,
  }) {
    requireHomeTrainingInput(isSafeTaskCenterDisplayName(fileDisplayName));
    requireHomeTrainingInput(
        eventTime.kind == _expectedEventKind(coarseStatus, attemptStatus));
    requireHomeTrainingInput(!actions.clearCompleted ||
        coarseStatus == TaskCenterCoarseStatus.completed);
    requireHomeTrainingInput(!actions.review ||
        attemptStatus == TaskCenterAttemptStatus.readyForReview ||
        (attemptStatus == null &&
            coarseStatus == TaskCenterCoarseStatus.pendingReview));
  }
  final TaskCenterTaskTarget target;
  final String fileDisplayName;
  final TaskCenterCoarseStatus coarseStatus;

  /// Null when the task has no authoritative detailed attempt metadata
  /// (legacy/non-OCR tasks), never a fabricated attempt state.
  final TaskCenterAttemptStatus? attemptStatus;
  final TaskCenterCounts counts;
  final TaskCenterEventTime eventTime;
  final TaskCenterActionEligibility actions;

  static TaskCenterEventKind? _expectedEventKind(
      TaskCenterCoarseStatus coarseStatus,
      TaskCenterAttemptStatus? attemptStatus) {
    return switch (attemptStatus) {
      TaskCenterAttemptStatus.queued => TaskCenterEventKind.queuedAt,
      TaskCenterAttemptStatus.running ||
      TaskCenterAttemptStatus.cancelRequested =>
        TaskCenterEventKind.startedAt,
      TaskCenterAttemptStatus.failed => TaskCenterEventKind.failedAt,
      TaskCenterAttemptStatus.cancelled ||
      TaskCenterAttemptStatus.interrupted =>
        null,
      TaskCenterAttemptStatus.readyForReview =>
        coarseStatus == TaskCenterCoarseStatus.completed
            ? TaskCenterEventKind.completedAt
            : TaskCenterEventKind.parsedAt,
      null => switch (coarseStatus) {
          TaskCenterCoarseStatus.completed => TaskCenterEventKind.completedAt,
          TaskCenterCoarseStatus.pendingReview => TaskCenterEventKind.parsedAt,
          TaskCenterCoarseStatus.inProgress ||
          TaskCenterCoarseStatus.error =>
            null,
        },
    };
  }
}

final class TaskCenterSnapshot {
  TaskCenterSnapshot(Iterable<TaskCenterItem> items)
      : items = List.unmodifiable(items) {
    requireHomeTrainingInput(
        this.items.map((item) => item.target.taskId).toSet().length ==
            this.items.length);
  }
  final List<TaskCenterItem> items;
}

/// Captured eligible completed records only, generated by the query authority
/// before user confirmation. No broad 'completed + error' cleanup operation.
final class TaskCenterCompletedSnapshot {
  TaskCenterCompletedSnapshot(
      {required this.snapshotId,
      required Iterable<TaskCenterTaskTarget> targets})
      : targets = List.unmodifiable(targets) {
    requireHomeTrainingInput(isSafeTaskCenterToken(snapshotId));
    requireHomeTrainingInput(
        this.targets.map((target) => target.taskId).toSet().length ==
            this.targets.length);
  }
  final String snapshotId;
  final List<TaskCenterTaskTarget> targets;
}

final class TaskCenterCleanupResult {
  TaskCenterCleanupResult(
      {required this.deletedCount, required this.retainedCount}) {
    requireHomeTrainingInput(deletedCount >= 0 && retainedCount >= 0);
  }
  final int deletedCount;
  final int retainedCount;
}

final class TaskCenterReviewNavigationRequest {
  const TaskCenterReviewNavigationRequest(this.target);
  final TaskCenterTaskTarget target;
}

sealed class TaskCenterRetryResult {
  const TaskCenterRetryResult();
}

final class TaskCenterRetryAccepted extends TaskCenterRetryResult {
  const TaskCenterRetryAccepted();
}

final class TaskCenterRetryNeedsFileSelection extends TaskCenterRetryResult {
  const TaskCenterRetryNeedsFileSelection(this.request);
  final RetryFileSelectionRequest request;
}

final class TaskCenterRetryFailed extends TaskCenterRetryResult {
  const TaskCenterRetryFailed(this.failure);
  final HomeTrainingFailure failure;
}

abstract interface class TaskCenterQuery {
  Future<HomeTrainingResult<TaskCenterSnapshot>> read();
  Future<HomeTrainingResult<TaskCenterItem>> detail(String taskId);
  Future<HomeTrainingResult<TaskCenterCompletedSnapshot>>
      snapshotCompletedForCleanup();
}

/// All commands revalidate captured identity/attempt/revision and current action
/// eligibility/leases. Failures are typed and zero mutation. Accepted retry
/// follows existing attempt increment/token rules and resets current-attempt
/// timestamps. Review navigation is a target request, not parsed review data;
/// its composition bridge preserves existing review CAS/lease/commit authority.
abstract interface class TaskCenterCommand {
  Future<HomeTrainingResult<HomeTrainingUnit>> cancel(
      TaskCenterTaskTarget target);
  Future<TaskCenterRetryResult> retry(TaskCenterTaskTarget target);
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
      TaskCenterTaskTarget target);

  /// After explicit confirmation, revalidate each captured member as still
  /// completed/current-attempt/non-busy/non-leased. Retain all newly completed
  /// tasks outside this snapshot and all changed/noneligible snapshot members.
  /// Deletes only durable task records, never saved learning/source-file data.
  Future<HomeTrainingResult<TaskCenterCleanupResult>> clearCompleted(
      TaskCenterCompletedSnapshot snapshot);
  Future<HomeTrainingResult<TaskCenterReviewNavigationRequest>> requestReview(
      TaskCenterTaskTarget target);
}

/// Display-name admission rejects path separators, control characters and
/// blank values while still admitting ordinary filename characters such as
/// ':' that the stricter taskId/traceId token validator must reject.
bool isSafeTaskCenterDisplayName(String value) =>
    value.trim().isNotEmpty && !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(value);
