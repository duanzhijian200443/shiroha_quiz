// R7C.1 TaskManager typed commit lease and durable completion contract.
// Synthetic in-memory fixtures only; no database, Provider, Replay or
// network path is touched.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

const _taskId = 'lease-task';
const _attemptToken = 'lease-attempt-1';
const _revision = 1;

ImportTask _typedTask({
  String id = _taskId,
  String token = _attemptToken,
  int number = 1,
  int revision = _revision,
  TaskStatus status = TaskStatus.pendingReview,
  String? attemptState,
  String route = 'typedV2',
  String? reason = 'typed_candidate_ready',
  bool withParsedData = true,
}) {
  return ImportTask(
    id: id,
    title: 'Synthetic typed import',
    status: status,
    parsedData: withParsedData
        ? <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': 1,
              'type': 3,
              'content': 'Synthetic stem',
              'standard_answer': 'Conclusion',
            },
          ]
        : null,
    diagnostics: <String, dynamic>{
      TaskManager.keyAttemptToken: token,
      TaskManager.keyAttemptNumber: number,
      TaskManager.keyAttemptState:
          attemptState ?? ImportAttemptState.readyForReview.name,
      TaskManager.keyImportStorageRoute: route,
      if (reason != null) TaskManager.keyImportStorageReason: reason,
      TaskManager.keyReviewDraftRevision: revision,
    },
  );
}

Future<TypedCommitLeaseResult> _begin(
  TaskManager manager, {
  String taskId = _taskId,
  String attemptToken = _attemptToken,
  int attemptNumber = 1,
  int expectedRevision = _revision,
}) {
  return manager.beginTypedCommitAttempt(
    taskId: taskId,
    attemptToken: attemptToken,
    attemptNumber: attemptNumber,
    expectedReviewDraftRevision: expectedRevision,
  );
}

ImportTask _legacyTask({
  String? token,
  int? number,
  String? trace = 'legacy-trace-1',
  int revision = 1,
}) {
  return ImportTask(
    id: 'legacy-lease-task',
    title: 'Synthetic legacy import',
    status: TaskStatus.pendingReview,
    parsedData: <Map<String, dynamic>>[
      <String, dynamic>{'content': 'Synthetic legacy stem'},
    ],
    diagnostics: <String, dynamic>{
      if (token != null) TaskManager.keyAttemptToken: token,
      if (number != null) TaskManager.keyAttemptNumber: number,
      if (trace != null) TaskManager.keyTraceId: trace,
      TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      TaskManager.keyReviewDraftRevision: revision,
    },
  );
}

Future<LegacyCommitLeaseResult> _beginLegacy(
  TaskManager manager, {
  String? token,
  int? number,
  String? trace = 'legacy-trace-1',
  int revision = 1,
}) {
  return manager.beginLegacyCommitAttempt(
    taskId: 'legacy-lease-task',
    attemptToken: token,
    attemptNumber: number,
    traceId: trace,
    expectedReviewDraftRevision: revision,
    storageRoute: 'legacyV1',
    storageReason: null,
  );
}

void main() {
  test('matching pendingReview attempt acquires a lease', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.acquired);
    final lease = result.lease!;
    expect(lease.taskId, _taskId);
    expect(lease.attemptToken, _attemptToken);
    expect(lease.attemptNumber, 1);
    expect(lease.reviewDraftRevision, _revision);
    expect(lease.storageRoute, 'typedV2');
    expect(lease.storageReason, 'typed_candidate_ready');
    expect(lease.leaseId, isNotEmpty);
  });

  test('missing task is rejected', () async {
    final manager = TaskManager.forTesting();

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskMissing);
  });

  test('completed task is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(status: TaskStatus.completed));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('processing task is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(status: TaskStatus.processing));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('error task is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(status: TaskStatus.error));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('stale attemptToken is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(token: 'lease-attempt-B'));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.staleAttempt);
  });

  test('stale attemptNumber is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(number: 2));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.staleAttempt);
  });

  test('wrong route is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(route: 'legacyV1'));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('wrong reason is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(reason: 'typed_candidate_shadow_ready'));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('wrong attemptState is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(
      _typedTask(attemptState: ImportAttemptState.failed.name),
    );

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('missing parsedData is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(withParsedData: false));

    final result = await _begin(manager);

    expect(result.status, TypedCommitLeaseStatus.taskNotPendingReview);
  });

  test('revision zero is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(revision: 0));

    final result = await _begin(manager, expectedRevision: 0);

    expect(result.status, TypedCommitLeaseStatus.staleReviewDraft);
  });

  test('stale revision is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask(revision: 2));

    final result = await _begin(manager, expectedRevision: 1);

    expect(result.status, TypedCommitLeaseStatus.staleReviewDraft);
  });

  test('a second lease for the same task is rejected', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());

    final first = await _begin(manager);
    expect(first.status, TypedCommitLeaseStatus.acquired);
    final second = await _begin(manager);

    expect(second.status, TypedCommitLeaseStatus.commitInProgress);
  });

  test('saveReviewDraft during an active lease returns commitInProgress',
      () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    await _begin(manager);

    final result = await manager.saveReviewDraft(
      _taskId,
      questions: <Map<String, dynamic>>[
        <String, dynamic>{'q_num': 1, 'content': 'Synthetic stem'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(result.status, ReviewDraftSaveStatus.commitInProgress);
  });

  test('answer distillation merge during an active lease is rejected',
      () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    await _begin(manager);

    final result = await manager.mergeReviewDraftAnswerDistillation(
      _taskId,
      reviewItemId: 'review-item-1',
      expectedRevision: _revision,
      status: 'ai_applied',
      standardAnswer: 'Answer',
    );

    expect(result.status, ReviewDraftSaveStatus.commitInProgress);
  });

  test('lease waits for queued review draft writes and uses their revision',
      () async {
    final saveGate = Completer<void>();
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async => saveGate.future,
    );
    manager.tasks.add(_typedTask());

    final pendingSave = manager.saveReviewDraft(
      _taskId,
      questions: <Map<String, dynamic>>[
        <String, dynamic>{'q_num': 1, 'content': 'Latest synthetic stem'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    final leaseFuture = _begin(manager, expectedRevision: 2);

    saveGate.complete();
    final saveResult = await pendingSave;
    final leaseResult = await leaseFuture;

    expect(saveResult.status, ReviewDraftSaveStatus.saved);
    expect(saveResult.revision, 2);
    expect(leaseResult.status, TypedCommitLeaseStatus.acquired);
    expect(leaseResult.lease!.reviewDraftRevision, 2,
        reason: 'the lease must observe the latest flushed revision');
  });

  test('after a failed lease is released the draft can be saved again',
      () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final first = await _begin(manager);
    manager.releaseTypedCommitLease(first.lease!);

    final result = await manager.saveReviewDraft(
      _taskId,
      questions: <Map<String, dynamic>>[
        <String, dynamic>{'q_num': 1, 'content': 'Retry stem'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(result.status, ReviewDraftSaveStatus.saved);
  });

  test('after a failed lease is released a new commit can begin', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final first = await _begin(manager);
    manager.releaseTypedCommitLease(first.lease!);

    final retry = await _begin(manager);

    expect(retry.status, TypedCommitLeaseStatus.acquired);
  });

  test('durable completion only updates memory and never persists', () async {
    var saveCalls = 0;
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        saveCalls++;
      },
    );
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    final status = manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: '已成功导入题库: Synthetic Bank',
      completedAt: 1700000000,
    );
    await Future<void>.delayed(Duration.zero);

    expect(status, TypedDurableCompletionStatus.applied);
    expect(saveCalls, 0,
        reason: 'durable completion must never write to the database');
    expect(manager.tasks.single.status, TaskStatus.completed);
  });

  test('durable completion clears parsedData', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    expect(manager.tasks.single.parsedData, isNull);
  });

  test('durable completion uses the transaction completedAt', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000123,
    );

    expect(manager.tasks.single.completedAt, 1700000123);
  });

  test('durable completion keeps the diagnostics metadata', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    final task = manager.tasks.single;
    expect(task.diagnostics?[TaskManager.keyAttemptToken], _attemptToken);
    expect(task.diagnostics?[TaskManager.keyAttemptNumber], 1);
    expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'typedV2');
    expect(task.diagnostics?[TaskManager.keyReviewDraftRevision], _revision);
  });

  test('a stale lease cannot complete another attempt', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    final task = manager.tasks.single;
    task.diagnostics = <String, dynamic>{
      ...?task.diagnostics,
      TaskManager.keyAttemptToken: 'lease-attempt-2',
      TaskManager.keyAttemptNumber: 2,
    };

    final status = manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    expect(status, TypedDurableCompletionStatus.staleLease);
    expect(manager.tasks.single.status, isNot(TaskStatus.completed));
  });

  test('duplicate memory application of the same lease is idempotent',
      () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;
    manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    final second = manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    expect(second, TypedDurableCompletionStatus.alreadyCompleted);
    expect(manager.tasks.single.status, TaskStatus.completed);
  });

  test('durable completion with a removed task stays a safe success', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;
    manager.tasks.clear();

    final status = manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );

    expect(status, TypedDurableCompletionStatus.taskRemovedDurable);
  });

  test('queued review draft writes cannot resurrect pendingReview', () async {
    final manager = TaskManager.forTesting();
    manager.tasks.add(_typedTask());
    final lease = (await _begin(manager)).lease!;

    final blocked = await manager.saveReviewDraft(
      _taskId,
      questions: <Map<String, dynamic>>[
        <String, dynamic>{'q_num': 1, 'content': 'Old snapshot'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    expect(blocked.status, ReviewDraftSaveStatus.commitInProgress);

    manager.applyDurableTypedCommitCompletion(
      lease: lease,
      completionText: 'done',
      completedAt: 1700000000,
    );
    await Future<void>.delayed(Duration.zero);

    expect(manager.tasks.single.status, TaskStatus.completed);
    expect(manager.tasks.single.parsedData, isNull);
  });

  test('legacy compatibility lease captures exact nullable identity', () async {
    final manager = TaskManager.forTesting()..tasks.add(_legacyTask());

    final result = await _beginLegacy(manager);

    expect(result.status, LegacyCommitLeaseStatus.acquired);
    expect(result.lease!.attemptToken, isNull);
    expect(result.lease!.attemptNumber, isNull);
    expect(result.lease!.traceId, 'legacy-trace-1');
    expect(result.lease!.reviewDraftRevision, 1);
    expect(result.lease!.storageRoute, 'legacyV1');
  });

  test('legacy null identity is not a wildcard for a newer attempt', () async {
    final manager = TaskManager.forTesting()
      ..tasks.add(
        _legacyTask(
          token: 'new-attempt',
          number: 2,
          trace: 'new-trace',
        ),
      );

    final result = await _beginLegacy(manager, trace: null);

    expect(result.status, LegacyCommitLeaseStatus.staleAttempt);
  });

  test('legacy lease blocks draft writes and a competing typed commit',
      () async {
    final manager = TaskManager.forTesting()..tasks.add(_legacyTask());
    final lease = (await _beginLegacy(manager)).lease!;

    final save = await manager.saveReviewDraft(
      'legacy-lease-task',
      questions: const <Map<String, dynamic>>[
        <String, dynamic>{'content': 'must not race'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    final typed = await manager.beginTypedCommitAttempt(
      taskId: 'legacy-lease-task',
      attemptToken: 'irrelevant',
      attemptNumber: 1,
      expectedReviewDraftRevision: 1,
    );

    expect(save.status, ReviewDraftSaveStatus.commitInProgress);
    expect(typed.status, TypedCommitLeaseStatus.commitInProgress);
    manager.releaseLegacyCommitLease(lease);
  });

  test('legacy durable completion is memory-only and prevents resurrection',
      () async {
    var persistenceCalls = 0;
    final manager = TaskManager.forTesting(
      saveTask: (_) async => persistenceCalls++,
    )..tasks.add(_legacyTask());
    final lease = (await _beginLegacy(manager)).lease!;

    final status = manager.applyDurableLegacyCommitCompletion(
      lease: lease,
      completionText: 'legacy done',
      completedAt: 1700000000,
    );
    final blocked = await manager.saveReviewDraft(
      'legacy-lease-task',
      questions: const <Map<String, dynamic>>[
        <String, dynamic>{'content': 'stale resurrection'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(status, TypedDurableCompletionStatus.applied);
    expect(persistenceCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.completed);
    expect(manager.tasks.single.parsedData, isNull);
    expect(blocked.status, ReviewDraftSaveStatus.commitInProgress);
  });
}
