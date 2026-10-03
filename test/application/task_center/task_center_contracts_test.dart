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

TaskCenterItem _item(TaskCenterCoarseStatus coarseStatus,
        TaskCenterAttemptStatus? attemptStatus, TaskCenterEventKind? kind,
        {String name = '试卷.pdf',
        int? time,
        TaskCenterActionEligibility actions = _noActions}) =>
    TaskCenterItem(
        target: _target('task-a'),
        fileDisplayName: name,
        coarseStatus: coarseStatus,
        attemptStatus: attemptStatus,
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
  test('coarse tab and existing attempt state stay independent axes', () {
    final cases = <(
      TaskCenterCoarseStatus,
      TaskCenterAttemptStatus?,
      TaskCenterEventKind?,
      int?
    )>[
      (
        TaskCenterCoarseStatus.inProgress,
        TaskCenterAttemptStatus.queued,
        TaskCenterEventKind.queuedAt,
        101
      ),
      (
        TaskCenterCoarseStatus.inProgress,
        TaskCenterAttemptStatus.running,
        TaskCenterEventKind.startedAt,
        null
      ),
      (
        TaskCenterCoarseStatus.inProgress,
        TaskCenterAttemptStatus.cancelRequested,
        TaskCenterEventKind.startedAt,
        102
      ),
      (
        TaskCenterCoarseStatus.pendingReview,
        TaskCenterAttemptStatus.readyForReview,
        TaskCenterEventKind.parsedAt,
        103
      ),
      (
        TaskCenterCoarseStatus.error,
        TaskCenterAttemptStatus.readyForReview,
        TaskCenterEventKind.parsedAt,
        null
      ),
      (
        TaskCenterCoarseStatus.completed,
        TaskCenterAttemptStatus.readyForReview,
        TaskCenterEventKind.completedAt,
        104
      ),
      (
        TaskCenterCoarseStatus.error,
        TaskCenterAttemptStatus.failed,
        TaskCenterEventKind.failedAt,
        null
      ),
      (
        TaskCenterCoarseStatus.error,
        TaskCenterAttemptStatus.cancelled,
        null,
        null
      ),
      (
        TaskCenterCoarseStatus.error,
        TaskCenterAttemptStatus.interrupted,
        null,
        null
      ),
      (TaskCenterCoarseStatus.inProgress, null, null, null),
      (
        TaskCenterCoarseStatus.pendingReview,
        null,
        TaskCenterEventKind.parsedAt,
        null
      ),
      (
        TaskCenterCoarseStatus.completed,
        null,
        TaskCenterEventKind.completedAt,
        105
      ),
      (TaskCenterCoarseStatus.error, null, null, null),
    ];
    for (final (coarse, attempt, kind, time) in cases) {
      final item = _item(coarse, attempt, kind, time: time);
      expect(item.coarseStatus, coarse);
      expect(item.attemptStatus, attempt);
      expect(item.eventTime.kind, kind);
      expect(item.eventTime.utcSeconds, time);
      expect(item.counts.questionCount, 10);
      expect(item.counts.warningCount, isNull);
    }

    // Previously inexpressible: an error task still holding a parsed review
    // candidate keeps the coarse 'error' tab while the attempt truth and the
    // application-supplied eligibility stay intact.
    final protected = _item(TaskCenterCoarseStatus.error,
        TaskCenterAttemptStatus.readyForReview, TaskCenterEventKind.parsedAt,
        time: 8,
        actions: const TaskCenterActionEligibility(
            cancel: false,
            retry: false,
            delete: false,
            review: true,
            clearCompleted: false));
    expect(protected.coarseStatus, TaskCenterCoarseStatus.error);
    expect(protected.attemptStatus, TaskCenterAttemptStatus.readyForReview);
    expect(protected.actions.review, isTrue);
    expect(protected.actions.delete, isFalse);

    // Legacy/non-OCR reviewable tasks stay expressible without a fabricated
    // attempt state.
    expect(
        _item(TaskCenterCoarseStatus.pendingReview, null,
                TaskCenterEventKind.parsedAt,
                actions: const TaskCenterActionEligibility(
                    cancel: false,
                    retry: false,
                    delete: false,
                    review: true,
                    clearCompleted: false))
            .actions
            .review,
        isTrue);
  });

  test(
      'event time kind is pinned per axis pair, existing authority times are '
      'mandatory', () {
    expect(
        () => TaskCenterEventTime(
            kind: TaskCenterEventKind.queuedAt, utcSeconds: null),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TaskCenterEventTime(
            kind: TaskCenterEventKind.completedAt, utcSeconds: null),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.inProgress,
            TaskCenterAttemptStatus.queued, TaskCenterEventKind.queuedAt),
        throwsA(isA<HomeTrainingContractException>()));

    // Cross-axis or unsupported event-time claims stay rejected.
    expect(
        () => _item(
            TaskCenterCoarseStatus.pendingReview,
            TaskCenterAttemptStatus.readyForReview,
            TaskCenterEventKind.startedAt,
            time: 7),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.inProgress,
            TaskCenterAttemptStatus.queued, TaskCenterEventKind.startedAt,
            time: 7),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.error,
            TaskCenterAttemptStatus.interrupted, TaskCenterEventKind.failedAt,
            time: 7),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.inProgress, null,
            TaskCenterEventKind.queuedAt,
            time: 7),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(
            TaskCenterCoarseStatus.error, null, TaskCenterEventKind.failedAt,
            time: 7),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'read DTO rejects source locations and invalid counts instead of leaking them',
      () {
    for (final path in [
      r'C:\private\exam.pdf',
      '/private/exam.pdf',
      'file:///private/exam.pdf',
      r'\\server\exam.pdf',
      'exam\n.pdf'
    ]) {
      expect(
          () => _item(TaskCenterCoarseStatus.inProgress,
              TaskCenterAttemptStatus.queued, TaskCenterEventKind.queuedAt,
              name: path, time: 1),
          throwsA(isA<HomeTrainingContractException>()));
    }
    expect(() => TaskCenterCounts(questionCount: -1, warningCount: 0),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TaskCenterEventTime(
            kind: TaskCenterEventKind.failedAt, utcSeconds: -1),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.error,
            TaskCenterAttemptStatus.failed, TaskCenterEventKind.failedAt,
            time: 2,
            actions: const TaskCenterActionEligibility(
                cancel: false,
                retry: true,
                delete: true,
                review: false,
                clearCompleted: true)),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(
            TaskCenterCoarseStatus.error,
            TaskCenterAttemptStatus.readyForReview,
            TaskCenterEventKind.parsedAt,
            time: 2,
            actions: const TaskCenterActionEligibility(
                cancel: false,
                retry: false,
                delete: false,
                review: false,
                clearCompleted: true)),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => _item(TaskCenterCoarseStatus.error,
            TaskCenterAttemptStatus.failed, TaskCenterEventKind.failedAt,
            time: 2,
            actions: const TaskCenterActionEligibility(
                cancel: false,
                retry: true,
                delete: true,
                review: true,
                clearCompleted: false)),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('display name admits ordinary filenames and rejects path leakage', () {
    expect(isSafeTaskCenterDisplayName('chapter:1.pdf'), isTrue);
    expect(isSafeTaskCenterDisplayName('2024: 期末 试卷.pdf'), isTrue);
    expect(isSafeTaskCenterDisplayName(r'C:\exam.pdf'), isFalse);
    expect(isSafeTaskCenterDisplayName(r'..\exam.pdf'), isFalse);
    expect(isSafeTaskCenterDisplayName('/exam.pdf'), isFalse);
    expect(isSafeTaskCenterDisplayName('file:///exam.pdf'), isFalse);
    expect(isSafeTaskCenterDisplayName(''), isFalse);
    expect(isSafeTaskCenterDisplayName('   '), isFalse);
    expect(isSafeTaskCenterDisplayName('exam\u0000.pdf'), isFalse);
    expect(
        _item(
                TaskCenterCoarseStatus.pendingReview,
                TaskCenterAttemptStatus.readyForReview,
                TaskCenterEventKind.parsedAt,
                time: 3,
                name: 'chapter:1.pdf')
            .fileDisplayName,
        'chapter:1.pdf');
  });

  test('list and completed confirmation snapshot copy immutable exact targets',
      () {
    final items = [
      _item(
          TaskCenterCoarseStatus.completed,
          TaskCenterAttemptStatus.readyForReview,
          TaskCenterEventKind.completedAt,
          time: 4)
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
