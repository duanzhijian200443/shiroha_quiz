import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/retry_file_selection.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';

TaskCenterTaskTarget _target(String id) => TaskCenterTaskTarget(
    taskId: id,
    expectedAttemptNumber: 2,
    expectedAttemptToken: 'attempt-2',
    expectedTraceId: 'trace-2',
    expectedReviewRevision: 3);

const _noActions = TaskCenterActionEligibility(
    cancel: false,
    retry: false,
    delete: false,
    review: false,
    clearCompleted: false);

TaskCenterItem _item(TaskCenterDetailedStatus status, TaskCenterEventKind? kind,
        {String name = '试卷.pdf',
        int? time,
        TaskCenterActionEligibility actions = _noActions}) =>
    TaskCenterItem(
        target: _target('task-a'),
        fileDisplayName: name,
        status: status,
        counts: TaskCenterCounts(questionCount: 10, warningCount: null),
        eventTime: TaskCenterEventTime(kind: kind, utcSeconds: time),
        actions: actions);

final class _TaskCommandFake implements TaskCenterCommand {
  TaskCenterTaskTarget? captured;
  TaskCenterCompletedSnapshot? cleanup;
  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> cancel(
          TaskCenterTaskTarget target) async =>
      _capture(target);
  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
          TaskCenterTaskTarget target) async =>
      _capture(target);
  HomeTrainingResult<HomeTrainingUnit> _capture(TaskCenterTaskTarget target) {
    captured = target;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }

  @override
  Future<TaskCenterRetryResult> retry(TaskCenterTaskTarget target) async {
    captured = target;
    return TaskCenterRetryNeedsFileSelection(RetryFileSelectionRequest(target));
  }

  @override
  Future<HomeTrainingResult<TaskCenterCleanupResult>> clearCompleted(
      TaskCenterCompletedSnapshot snapshot) async {
    cleanup = snapshot;
    return HomeTrainingSuccess(TaskCenterCleanupResult(
        deletedCount: 0, retainedCount: snapshot.targets.length));
  }

  @override
  Future<HomeTrainingResult<TaskCenterReviewNavigationRequest>> requestReview(
          TaskCenterTaskTarget target) async =>
      HomeTrainingSuccess(TaskCenterReviewNavigationRequest(target));
}

void main() {
  test('DTO expresses all detailed/coarse states and exact event-time meaning',
      () {
    final cases = [
      (
        TaskCenterDetailedStatus.queued,
        TaskCenterCoarseStatus.inProgress,
        TaskCenterEventKind.queuedAt
      ),
      (
        TaskCenterDetailedStatus.running,
        TaskCenterCoarseStatus.inProgress,
        TaskCenterEventKind.startedAt
      ),
      (
        TaskCenterDetailedStatus.cancelRequested,
        TaskCenterCoarseStatus.inProgress,
        TaskCenterEventKind.startedAt
      ),
      (
        TaskCenterDetailedStatus.readyForReview,
        TaskCenterCoarseStatus.pendingReview,
        TaskCenterEventKind.parsedAt
      ),
      (
        TaskCenterDetailedStatus.completed,
        TaskCenterCoarseStatus.completed,
        TaskCenterEventKind.completedAt
      ),
      (
        TaskCenterDetailedStatus.failed,
        TaskCenterCoarseStatus.error,
        TaskCenterEventKind.failedAt
      ),
      (TaskCenterDetailedStatus.cancelled, TaskCenterCoarseStatus.error, null),
      (
        TaskCenterDetailedStatus.interrupted,
        TaskCenterCoarseStatus.error,
        null
      ),
    ];
    for (final (status, coarse, eventKind) in cases) {
      final item = _item(status, eventKind);
      expect(item.coarseStatus, coarse);
      expect(item.eventTime.kind, eventKind);
      expect(item.eventTime.utcSeconds, isNull);
      expect(item.counts.questionCount, 10);
      expect(item.counts.warningCount, isNull);
    }
    expect(
        _item(TaskCenterDetailedStatus.completed,
                TaskCenterEventKind.completedAt,
                time: 123)
            .eventTime
            .utcSeconds,
        123);
    expect(
        () => _item(TaskCenterDetailedStatus.readyForReview,
            TaskCenterEventKind.completedAt,
            time: 123),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(
            TaskCenterDetailedStatus.interrupted, TaskCenterEventKind.failedAt),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'read DTO rejects source locations and invalid counts instead of leaking them',
      () {
    for (final path in [
      r'C:\private\exam.pdf',
      '/private/exam.pdf',
      'file:///private/exam.pdf',
      r'\\server\exam.pdf'
    ]) {
      expect(
          () => _item(
              TaskCenterDetailedStatus.queued, TaskCenterEventKind.queuedAt,
              name: path),
          throwsA(isA<HomeTrainingContractException>()));
    }
    expect(() => TaskCenterCounts(questionCount: -1, warningCount: 0),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TaskCenterEventTime(
            kind: TaskCenterEventKind.failedAt, utcSeconds: -1),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(
            TaskCenterDetailedStatus.failed, TaskCenterEventKind.failedAt,
            actions: const TaskCenterActionEligibility(
                cancel: false,
                retry: true,
                delete: true,
                review: false,
                clearCompleted: true)),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('list and completed confirmation snapshot copy immutable exact targets',
      () {
    final items = [
      _item(TaskCenterDetailedStatus.completed, TaskCenterEventKind.completedAt)
    ];
    final list = TaskCenterSnapshot(items);
    items.clear();
    expect(list.items, hasLength(1));
    expect(() => list.items.clear(), throwsUnsupportedError);
    final targets = [_target('task-a')];
    final cleanup =
        TaskCenterCompletedSnapshot(snapshotId: 'snapshot-a', targets: targets);
    targets.add(_target('newly-completed-after-confirmation'));
    expect(cleanup.targets, hasLength(1));
    expect(cleanup.targets.single.expectedAttemptToken, 'attempt-2');
    expect(() => cleanup.targets.clear(), throwsUnsupportedError);
    expect(() => TaskCenterSnapshot([list.items.single, list.items.single]),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('fake commands and navigation retain attempt, trace and revision guards',
      () async {
    final fake = _TaskCommandFake();
    final target = _target('task-a');
    await fake.cancel(target);
    final deleted = await fake.delete(target);
    expect(fake.captured, same(target));
    expect((deleted as HomeTrainingFailed<HomeTrainingUnit>).failure,
        HomeTrainingFailure.stale);
    final retry = await fake.retry(target) as TaskCenterRetryNeedsFileSelection;
    expect(retry.request.target, same(target));
    final reviewed = await fake.requestReview(target)
        as HomeTrainingSuccess<TaskCenterReviewNavigationRequest>;
    expect(reviewed.value.target.expectedAttemptNumber, 2);
    expect(reviewed.value.target.expectedAttemptToken, 'attempt-2');
    expect(reviewed.value.target.expectedTraceId, 'trace-2');
    expect(reviewed.value.target.expectedReviewRevision, 3);
    final snapshot = TaskCenterCompletedSnapshot(
        snapshotId: 'snapshot-a', targets: [target]);
    final cleared = await fake.clearCompleted(snapshot)
        as HomeTrainingSuccess<TaskCenterCleanupResult>;
    expect(fake.cleanup, same(snapshot));
    expect(cleared.value.deletedCount, 0);
    expect(cleared.value.retainedCount, 1);
  });
}
