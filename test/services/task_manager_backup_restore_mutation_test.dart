import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

Matcher _restoreBlocked() => throwsA(
      isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      ),
    );

ImportTask _reviewTask() => ImportTask(
      id: 'review-task',
      title: 'Synthetic review task',
      status: TaskStatus.pendingReview,
      parsedData: <Map<String, dynamic>>[
        <String, dynamic>{
          TaskManager.keyReviewItemId: 'review-item-1',
          'content': 'Synthetic question',
        },
      ],
    );

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('review-draft persistence holds the lease until the writer completes',
      () async {
    final release = Completer<void>();
    final saved = <Map<String, dynamic>>[];
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        saved.add(Map<String, dynamic>.from(taskMap));
        await release.future;
      },
    )..tasks.add(_reviewTask());

    final pending = manager.saveReviewDraft(
      'review-task',
      questions: <Map<String, dynamic>>[
        <String, dynamic>{
          TaskManager.keyReviewItemId: 'review-item-1',
          'content': 'Updated question',
        },
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    await Future<void>.delayed(Duration.zero);
    expect(saved, hasLength(1));
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainCompleted = false;
    unawaited(drained.then((_) => drainCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);

    release.complete();
    expect((await pending).saved, isTrue);
    await drained;
    expect(drainCompleted, isTrue);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);

    await manager.resetTransientStateForRestore();
    expect(manager.tasks, isEmpty);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('review draft and Task Center deletes reject new writes in maintenance',
      () async {
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(_reviewTask());

    await BackupRestoreMutationGate.instance.enterQuiescence();
    expect(
      () => manager.saveReviewDraft(
        'review-task',
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{'content': 'Blocked'},
        ],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      _restoreBlocked(),
    );
    await expectLater(manager.deleteTask('review-task'), _restoreBlocked());
    await expectLater(manager.clearCompletedTasks(), _restoreBlocked());
    expect(manager.tasks, hasLength(1));
    BackupRestoreMutationGate.instance.exitQuiescence();
  });
}
