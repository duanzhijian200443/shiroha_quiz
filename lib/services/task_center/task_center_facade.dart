import 'dart:math';
import '../../application/home_training_result.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../../application/task_center/retry_file_selection.dart';
import '../task_manager.dart';
import '../import_pipeline/import_task_coordinator.dart';

/// Infrastructure adapter for the frozen Application boundary. No mutable
/// task or ingestion location escapes through its read/navigation results.
final class TaskCenterFacade
    implements
        TaskCenterQuery,
        TaskCenterCommand,
        TaskCenterSelectedSourceRetry {
  TaskCenterFacade(
      {required TaskManager taskManager,
      required ImportTaskCoordinator coordinator,
      String Function()? snapshotIdFactory})
      : _manager = taskManager,
        _coordinator = coordinator,
        _snapshotIdFactory = snapshotIdFactory ?? _newSnapshotId;

  final TaskManager _manager;
  final ImportTaskCoordinator _coordinator;
  final String Function() _snapshotIdFactory;
  final Expando<bool> _issuedCleanupSnapshots = Expando();
  static final _random = Random.secure();
  static String _newSnapshotId() =>
      'cleanup-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(0x7fffffff)}';

  TaskCenterItem _project(ImportTask task) {
    final target = _manager.taskCenterTarget(task.id);
    if (target == null || !isSafeTaskCenterDisplayName(task.title)) {
      throw const HomeTrainingContractException(
          HomeTrainingFailure.unavailable);
    }
    final raw = task.diagnostics?[TaskManager.keyAttemptState];
    final states = TaskCenterAttemptStatus.values.where((s) => s.name == raw);
    if (raw != null && states.isEmpty) {
      throw const HomeTrainingContractException(
          HomeTrainingFailure.unavailable);
    }
    final attempt = states.isEmpty ? null : states.single;
    final coarse = TaskCenterCoarseStatus.values[task.status.index];
    final (kind, time) = switch (attempt) {
      TaskCenterAttemptStatus.queued => (
          TaskCenterEventKind.queuedAt,
          task.createdAt
        ),
      TaskCenterAttemptStatus.running ||
      TaskCenterAttemptStatus.cancelRequested =>
        (TaskCenterEventKind.startedAt, task.attemptStartedAt),
      TaskCenterAttemptStatus.failed => (
          TaskCenterEventKind.failedAt,
          task.failedAt
        ),
      TaskCenterAttemptStatus.cancelled ||
      TaskCenterAttemptStatus.interrupted =>
        (null, null),
      TaskCenterAttemptStatus.readyForReview || null => switch (task.status) {
          TaskStatus.completed => (
              TaskCenterEventKind.completedAt,
              task.completedAt
            ),
          TaskStatus.pendingReview => (
              TaskCenterEventKind.parsedAt,
              task.parsedAt
            ),
          _ => (null, null),
        },
    };
    final busy = _manager.isTaskCenterBusy(task.id);
    final ocr = task.parseMode == 'ocr';
    final retry = !busy &&
        ocr &&
        (attempt == TaskCenterAttemptStatus.failed ||
            attempt == TaskCenterAttemptStatus.cancelled ||
            attempt == TaskCenterAttemptStatus.interrupted);
    final review = !busy &&
        task.status == TaskStatus.pendingReview &&
        (attempt == TaskCenterAttemptStatus.readyForReview || attempt == null);
    final terminal =
        task.status == TaskStatus.completed || task.status == TaskStatus.error;
    final activeAttempt = attempt == TaskCenterAttemptStatus.queued ||
        attempt == TaskCenterAttemptStatus.running ||
        attempt == TaskCenterAttemptStatus.cancelRequested;
    final delete = !busy &&
        terminal &&
        !activeAttempt &&
        !(task.status == TaskStatus.error &&
            attempt == TaskCenterAttemptStatus.readyForReview);
    return TaskCenterItem(
        target: target,
        fileDisplayName: task.title,
        coarseStatus: coarse,
        attemptStatus: attempt,
        counts: TaskCenterCounts(
            questionCount: task.parsedData?.length,
            warningCount: task.warnings?.length),
        eventTime: TaskCenterEventTime(kind: kind, utcSeconds: time),
        actions: TaskCenterActionEligibility(
            cancel: !busy &&
                ocr &&
                task.attemptRef != null &&
                (attempt == TaskCenterAttemptStatus.queued ||
                    attempt == TaskCenterAttemptStatus.running),
            retry: retry,
            delete: delete,
            review: review,
            clearCompleted: delete && task.status == TaskStatus.completed));
  }

  @override
  Future<HomeTrainingResult<TaskCenterSnapshot>> read() async {
    try {
      await _manager.ready;
      if (!_manager.taskCenterAvailable) {
        return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
      }
      return HomeTrainingSuccess(
          TaskCenterSnapshot(_manager.tasks.map(_project)));
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  @override
  Future<HomeTrainingResult<TaskCenterItem>> detail(String taskId) async {
    try {
      await _manager.ready;
      if (!_manager.taskCenterAvailable) {
        return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
      }
      final tasks = _manager.tasks.where((t) => t.id == taskId);
      if (tasks.isEmpty) {
        return const HomeTrainingFailed(HomeTrainingFailure.notFound);
      }
      return HomeTrainingSuccess(_project(tasks.single));
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  @override
  Future<HomeTrainingResult<TaskCenterCompletedSnapshot>>
      snapshotCompletedForCleanup() async {
    final result = await read();
    if (result is HomeTrainingFailed<TaskCenterSnapshot>) {
      return HomeTrainingFailed(result.failure);
    }
    try {
      final snapshot = TaskCenterCompletedSnapshot(
          snapshotId: _snapshotIdFactory(),
          targets: (result as HomeTrainingSuccess<TaskCenterSnapshot>)
              .value
              .items
              .where((item) => item.actions.clearCompleted)
              .map((item) => item.target));
      _issuedCleanupSnapshots[snapshot] = true;
      return HomeTrainingSuccess(snapshot);
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  Future<HomeTrainingResult<TaskCenterItem>> _admit(TaskCenterTaskTarget target,
      bool Function(TaskCenterActionEligibility) eligible) async {
    try {
      final failure = await _manager.validateTaskCenterTarget(target);
      if (failure != null) return HomeTrainingFailed(failure);
      final result = await detail(target.taskId);
      if (result is HomeTrainingSuccess<TaskCenterItem>) {
        if (!_manager.matchesTaskCenterTarget(target)) {
          return const HomeTrainingFailed(HomeTrainingFailure.stale);
        }
        return eligible(result.value.actions)
            ? result
            : const HomeTrainingFailed(HomeTrainingFailure.conflict);
      }
      return result;
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  HomeTrainingResult<HomeTrainingUnit> _unit(HomeTrainingFailure? failure) =>
      failure == null
          ? const HomeTrainingSuccess(HomeTrainingUnit())
          : HomeTrainingFailed(failure);

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> cancel(
      TaskCenterTaskTarget target) async {
    final admission = await _admit(target, (a) => a.cancel);
    if (admission is HomeTrainingFailed<TaskCenterItem>) {
      return HomeTrainingFailed(admission.failure);
    }
    try {
      final status = await _coordinator.cancelOcrTask(target.taskId,
          expectedTarget: target);
      return _unit(switch (status) {
        ImportAttemptWriteStatus.applied => null,
        ImportAttemptWriteStatus.stale ||
        ImportAttemptWriteStatus.taskMissing =>
          HomeTrainingFailure.stale,
        ImportAttemptWriteStatus.invalidState => HomeTrainingFailure.conflict,
        ImportAttemptWriteStatus.persistenceFailed =>
          HomeTrainingFailure.unavailable,
      });
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  @override
  Future<TaskCenterRetryResult> retry(TaskCenterTaskTarget target) async {
    final admission = await _admit(target, (a) => a.retry);
    return admission is HomeTrainingFailed<TaskCenterItem>
        ? TaskCenterRetryFailed(admission.failure)
        : TaskCenterRetryNeedsFileSelection(RetryFileSelectionRequest(target));
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> retryWithSelectedSource(
      RetryFileSelectionSelected selected) async {
    final target = selected.request.target;
    final admission = await _admit(target, (a) => a.retry);
    if (admission is HomeTrainingFailed<TaskCenterItem>) {
      return HomeTrainingFailed(admission.failure);
    }
    final source = selected.selection;
    if (source is! TaskCenterLocalRetrySource) {
      return const HomeTrainingFailed(HomeTrainingFailure.invalidInput);
    }
    try {
      await _coordinator.retryOcrRequest(
          taskId: target.taskId,
          expectedTarget: target,
          filePaths: source._paths,
          fileNames: source._names);
      return _unit(null);
    } catch (_) {
      return _unit(_manager.matchesTaskCenterTarget(target)
          ? HomeTrainingFailure.unavailable
          : HomeTrainingFailure.stale);
    }
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
      TaskCenterTaskTarget target) async {
    final admission = await _admit(target, (a) => a.delete);
    if (admission is HomeTrainingFailed<TaskCenterItem>) {
      return HomeTrainingFailed(admission.failure);
    }
    return _unit(
        await _manager.deleteTaskCenterTarget(target, completedOnly: false));
  }

  @override
  Future<HomeTrainingResult<TaskCenterCleanupResult>> clearCompleted(
      TaskCenterCompletedSnapshot snapshot) async {
    if (_issuedCleanupSnapshots[snapshot] != true) {
      return const HomeTrainingFailed(HomeTrainingFailure.stale);
    }
    _issuedCleanupSnapshots[snapshot] = false;
    var deleted = 0;
    for (final target in snapshot.targets) {
      final failure =
          await _manager.deleteTaskCenterTarget(target, completedOnly: true);
      if (failure == null) deleted++;
    }
    return HomeTrainingSuccess(TaskCenterCleanupResult(
        deletedCount: deleted,
        retainedCount: snapshot.targets.length - deleted));
  }

  @override
  Future<HomeTrainingResult<TaskCenterReviewNavigationRequest>> requestReview(
      TaskCenterTaskTarget target) async {
    final admission = await _admit(target, (a) => a.review);
    return admission is HomeTrainingFailed<TaskCenterItem>
        ? HomeTrainingFailed(admission.failure)
        : HomeTrainingSuccess(TaskCenterReviewNavigationRequest(target));
  }
}

/// Explicit picker/ingestion compatibility boundary. Never stored in a task,
/// read DTO, diagnostics or loggable representation; no platform picker needed.
final class TaskCenterLocalRetrySource implements RetrySourceSelection {
  TaskCenterLocalRetrySource(
      {required Iterable<String> paths, required Iterable<String> names})
      : _paths = List.unmodifiable(paths),
        _names = List.unmodifiable(names);
  final List<String> _paths;
  final List<String> _names;
  @override
  String toString() => 'TaskCenterLocalRetrySource';
}
