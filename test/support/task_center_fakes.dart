import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/application/task_center/retry_file_selection.dart';
import 'package:shiroha_quiz/ui/dependencies/task_center_dependencies.dart';

TaskCenterItem taskItem(String id,
    {TaskCenterCoarseStatus status = TaskCenterCoarseStatus.pendingReview,
    TaskCenterAttemptStatus? attempt = TaskCenterAttemptStatus.readyForReview,
    String name = 'synthetic.pdf',
    int? time = 1791248400,
    bool enabled = true}) {
  final kind = switch (attempt) {
    TaskCenterAttemptStatus.queued => TaskCenterEventKind.queuedAt,
    TaskCenterAttemptStatus.running ||
    TaskCenterAttemptStatus.cancelRequested =>
      TaskCenterEventKind.startedAt,
    TaskCenterAttemptStatus.failed => TaskCenterEventKind.failedAt,
    TaskCenterAttemptStatus.cancelled ||
    TaskCenterAttemptStatus.interrupted =>
      null,
    _ => status == TaskCenterCoarseStatus.completed
        ? TaskCenterEventKind.completedAt
        : TaskCenterEventKind.parsedAt,
  };
  return TaskCenterItem(
      target: TaskCenterTaskTarget(
          taskId: id,
          expectedAttemptNumber: 1,
          expectedAttemptToken: 'token-$id',
          expectedTraceId: 'trace-$id',
          expectedReviewRevision: 3),
      fileDisplayName: name,
      coarseStatus: status,
      attemptStatus: attempt,
      counts: TaskCenterCounts(questionCount: 22, warningCount: 1),
      eventTime: TaskCenterEventTime(
          kind: kind, utcSeconds: kind == null ? null : time),
      actions: TaskCenterActionEligibility(
          cancel: enabled && status == TaskCenterCoarseStatus.inProgress,
          retry: enabled && status == TaskCenterCoarseStatus.error,
          delete: enabled && status == TaskCenterCoarseStatus.completed,
          review: enabled && status == TaskCenterCoarseStatus.pendingReview,
          clearCompleted:
              enabled && status == TaskCenterCoarseStatus.completed));
}

class _Selection implements RetrySourceSelection {}

class TaskCenterFake extends Fake
    implements
        TaskCenterQuery,
        TaskCenterCommand,
        TaskCenterSelectedSourceRetry,
        RetryFileSelectionHost {
  List<TaskCenterItem> items = [
    taskItem('pending'),
    taskItem('done', status: TaskCenterCoarseStatus.completed),
    taskItem('failed',
        status: TaskCenterCoarseStatus.error,
        attempt: TaskCenterAttemptStatus.failed)
  ];
  int reads = 0,
      activeReads = 0,
      maxReads = 0,
      commands = 0,
      picks = 0,
      selectedRetries = 0,
      reviews = 0;
  bool unavailable = false, pickerCancelled = false;
  HomeTrainingFailure? failure;
  final List<TaskCenterTaskTarget> targets = [];
  final List<Completer<HomeTrainingResult<TaskCenterSnapshot>>> readGates = [];
  Completer<void>? actionGate, pickerGate;
  TaskCenterCompletedSnapshot? issued, submitted;
  TaskCenterDependencies get ports => TaskCenterDependencies(
      query: this,
      command: this,
      selectedSourceRetry: this,
      fileSelection: this,
      openReview: (_, request) async {
        reviews++;
        targets.add(request.target);
        return const HomeTrainingSuccess(HomeTrainingUnit());
      });
  @override
  Future<HomeTrainingResult<TaskCenterSnapshot>> read() async {
    reads++;
    activeReads++;
    if (activeReads > maxReads) maxReads = activeReads;
    try {
      if (readGates.isNotEmpty) return await readGates.removeAt(0).future;
      return unavailable
          ? const HomeTrainingFailed(HomeTrainingFailure.unavailable)
          : HomeTrainingSuccess(TaskCenterSnapshot(items));
    } finally {
      activeReads--;
    }
  }

  @override
  Future<HomeTrainingResult<TaskCenterItem>> detail(String id) async =>
      HomeTrainingSuccess(items.firstWhere((i) => i.target.taskId == id));
  @override
  Future<HomeTrainingResult<TaskCenterCompletedSnapshot>>
      snapshotCompletedForCleanup() async {
    issued = TaskCenterCompletedSnapshot(
        snapshotId: 'issued',
        targets:
            items.where((i) => i.actions.clearCompleted).map((i) => i.target));
    return HomeTrainingSuccess(issued!);
  }

  @override
  Future<HomeTrainingResult<TaskCenterCleanupResult>> clearCompleted(
      TaskCenterCompletedSnapshot snapshot) async {
    commands++;
    submitted = snapshot;
    return HomeTrainingSuccess(TaskCenterCleanupResult(
        deletedCount: snapshot.targets.length, retainedCount: 0));
  }

  Future<HomeTrainingResult<HomeTrainingUnit>> mutate(
      TaskCenterTaskTarget target) async {
    commands++;
    targets.add(target);
    await actionGate?.future;
    return failure == null
        ? const HomeTrainingSuccess(HomeTrainingUnit())
        : HomeTrainingFailed(failure!);
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> cancel(
          TaskCenterTaskTarget target) =>
      mutate(target);
  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
          TaskCenterTaskTarget target) =>
      mutate(target);
  @override
  Future<TaskCenterRetryResult> retry(TaskCenterTaskTarget target) async {
    commands++;
    targets.add(target);
    return TaskCenterRetryNeedsFileSelection(RetryFileSelectionRequest(target));
  }

  @override
  Future<RetryFileSelectionResult> select(
      RetryFileSelectionRequest request) async {
    picks++;
    await pickerGate?.future;
    return pickerCancelled
        ? const RetryFileSelectionCancelled()
        : RetryFileSelectionSelected(request: request, selection: _Selection());
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> retryWithSelectedSource(
      RetryFileSelectionSelected selection) {
    selectedRetries++;
    return mutate(selection.request.target);
  }

  @override
  Future<HomeTrainingResult<TaskCenterReviewNavigationRequest>> requestReview(
      TaskCenterTaskTarget target) async {
    commands++;
    targets.add(target);
    return failure == null
        ? HomeTrainingSuccess(TaskCenterReviewNavigationRequest(target))
        : HomeTrainingFailed(failure!);
  }
}
