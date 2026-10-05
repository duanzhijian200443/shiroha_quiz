import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/retry_file_selection.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_center/task_center_file_picker_host.dart';
import 'package:shiroha_quiz/services/task_center/task_center_review_bridge.dart';
import 'package:shiroha_quiz/services/task_center/task_center_facade.dart';
import 'package:shiroha_quiz/ui/composition/task_center_composition.dart';

ImportTask fixture({TaskStatus status = TaskStatus.pendingReview}) =>
    ImportTask(
        id: 'task',
        title: 'synthetic.pdf',
        status: status,
        createdAt: 100,
        completedAt: status == TaskStatus.completed ? 200 : null,
        parsedData: status == TaskStatus.pendingReview
            ? [
                {'content': 'synthetic'}
              ]
            : null,
        diagnostics: {
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'token',
          TaskManager.keyTraceId: 'trace',
          TaskManager.keyAttemptState: 'readyForReview',
          TaskManager.keyReviewDraftRevision: 3
        });

void main() {
  test('TaskCenter Presentation depends only on safe Application seams', () {
    final files = [
      File('lib/ui/pages/task_center_screen.dart'),
      File('lib/ui/dependencies/task_center_dependencies.dart'),
      ...Directory('lib/ui/task_center')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in [
        'TaskManager',
        'ImportTaskCoordinator',
        'DatabaseHelper',
        'file_picker',
        'parsedData',
        'sourcePath',
        'rawDiagnostics',
        "services/",
        "data/",
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: '${file.path} must not consume $forbidden');
      }
    }
    expect(
        File('lib/ui/pages/home_page.dart')
            .readAsStringSync()
            .contains('TaskManager'),
        isFalse);
  });
  test(
      'one production facade owns query/command/selected retry and issued cleanup identity',
      () async {
    final deleted = <String>[];
    final manager = TaskManager.forTesting(deleteTaskPersistence: (id) async {
      deleted.add(id);
      return ImportTaskCleanupStatus.deleted;
    });
    addTearDown(manager.dispose);
    await manager.ready;
    manager.tasks.add(fixture(status: TaskStatus.completed));
    final ports = createTaskCenterDependencies(
        manager: manager,
        coordinator: ImportTaskCoordinator(taskManager: manager));
    expect(identical(ports.query, ports.command), isTrue);
    expect(identical(ports.command, ports.selectedSourceRetry), isTrue);
    final captured = (await ports.query.snapshotCompletedForCleanup()
            as HomeTrainingSuccess<TaskCenterCompletedSnapshot>)
        .value;
    final result = await ports.command.clearCompleted(captured);
    expect(result, isA<HomeTrainingSuccess<TaskCenterCleanupResult>>());
    expect(
        (result as HomeTrainingSuccess<TaskCenterCleanupResult>)
            .value
            .deletedCount,
        1);
    expect(deleted, ['task']);
  });
  for (final key in [
    TaskManager.keyAttemptNumber,
    TaskManager.keyAttemptToken,
    TaskManager.keyTraceId,
    TaskManager.keyReviewDraftRevision
  ]) {
    test(
        'review bridge rejects changed $key after request and before navigation',
        () async {
      final manager = TaskManager.forTesting();
      addTearDown(manager.dispose);
      await manager.ready;
      final task = fixture();
      manager.tasks.add(task);
      final facade = TaskCenterFacade(
          taskManager: manager,
          coordinator: ImportTaskCoordinator(taskManager: manager));
      final request =
          (await facade.requestReview(manager.taskCenterTarget('task')!)
                  as HomeTrainingSuccess<TaskCenterReviewNavigationRequest>)
              .value;
      task.diagnostics![key] = key == TaskManager.keyAttemptNumber
          ? 2
          : key == TaskManager.keyReviewDraftRevision
              ? 4
              : 'changed';
      var navigations = 0;
      final result =
          await TaskCenterReviewBridge(manager).open(request, (_) async {
        navigations++;
      });
      expect((result as HomeTrainingFailed).failure, HomeTrainingFailure.stale);
      expect(navigations, 0);
    });
  }
  test(
      'review bridge preserves current inputs and rejects exact nullable metadata drift',
      () async {
    final manager = TaskManager.forTesting();
    addTearDown(manager.dispose);
    await manager.ready;
    final task = fixture();
    manager.tasks.add(task);
    final request =
        TaskCenterReviewNavigationRequest(manager.taskCenterTarget('task')!);
    final result =
        await TaskCenterReviewBridge(manager).open(request, (current) async {
      expect(current, same(task));
      expect(current.parsedData, same(task.parsedData));
      expect(current.diagnostics, same(task.diagnostics));
    });
    expect(result, isA<HomeTrainingSuccess<HomeTrainingUnit>>());
    task.diagnostics!.remove(TaskManager.keyReviewDraftRevision);
    final absent =
        TaskCenterReviewNavigationRequest(manager.taskCenterTarget('task')!);
    task.diagnostics![TaskManager.keyReviewDraftRevision] = 0;
    final drift = await TaskCenterReviewBridge(manager).open(absent, (_) async {
      fail('no navigation');
    });
    expect((drift as HomeTrainingFailed).failure, HomeTrainingFailure.stale);
  });
  test(
      'picker cancellation/missing paths are zero retry; source stays opaque and tied to request',
      () async {
    final target = TaskCenterTaskTarget(
        taskId: 'task',
        expectedAttemptNumber: null,
        expectedAttemptToken: null,
        expectedTraceId: null,
        expectedReviewRevision: null);
    final request = RetryFileSelectionRequest(target);
    expect(
        await TaskCenterFilePickerHost(picker: () async => null)
            .select(request),
        isA<RetryFileSelectionCancelled>());
    final host = TaskCenterFilePickerHost(
        picker: () async => FilePickerResult([
              PlatformFile(
                  name: 'synthetic.pdf',
                  size: 1,
                  path: 'synthetic-local-source')
            ]),
        exists: (_) async => true);
    final picked = await host.select(request) as RetryFileSelectionSelected;
    expect(picked.request, same(request));
    expect(picked.selection.toString(), 'TaskCenterLocalRetrySource');
    expect(
        await TaskCenterFilePickerHost(
                picker: () async => FilePickerResult(
                    [PlatformFile(name: 'synthetic.pdf', size: 1)]))
            .select(request),
        isA<RetryFileSelectionCancelled>());
    expect(
        await TaskCenterFilePickerHost(
            picker: () async => FilePickerResult([
                  PlatformFile(
                      name: 'synthetic.pdf', size: 1, path: 'synthetic')
                ]),
            exists: (_) async => false).select(request),
        isA<RetryFileSelectionCancelled>());
  });
}
