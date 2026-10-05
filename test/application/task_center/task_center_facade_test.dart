import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/retry_file_selection.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_center/task_center_facade.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

ImportTask _task(String id,
        {TaskStatus status = TaskStatus.completed,
        String? state = 'readyForReview',
        bool metadata = true,
        String? title}) =>
    ImportTask(
        id: id,
        title: title ?? 'paper: chapter 1.pdf',
        status: status,
        createdAt: 50,
        completedAt: status == TaskStatus.completed ? 180 : null,
        attemptStartedAt: 100,
        parsedAt: 150,
        failedAt: 170,
        parsedData: status == TaskStatus.pendingReview ? [] : null,
        diagnostics: metadata
            ? {
                TaskManager.keyAttemptNumber: 1,
                TaskManager.keyAttemptToken: 'token-$id',
                TaskManager.keyTraceId: 'trace-$id',
                TaskManager.keyParseMode: 'ocr',
                TaskManager.keyImportStorageRoute: 'legacyV1',
                if (state != null) TaskManager.keyAttemptState: state
              }
            : null);

T _success<T>(HomeTrainingResult<T> result) =>
    (result as HomeTrainingSuccess<T>).value;
HomeTrainingFailure _failure<T>(HomeTrainingResult<T> result) =>
    (result as HomeTrainingFailed<T>).failure;

class _HeldDelete extends ImportTaskRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<HomeTrainingFailure?> deleteTaskCenterTarget(
      TaskCenterTaskTarget target,
      {required bool completedOnly}) async {
    entered.complete();
    await release.future;
    return super.deleteTaskCenterTarget(target, completedOnly: completedOnly);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late TaskManager manager;
  late TaskCenterFacade facade;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    db = await DatabaseHelper.instance.database;
    manager = TaskManager.forTesting(repository: ImportTaskRepository());
    facade = TaskCenterFacade(
        taskManager: manager,
        coordinator: ImportTaskCoordinator(taskManager: manager),
        snapshotIdFactory: () => 'snapshot');
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    BackupRestoreMutationGate.resetForTesting();
  });
  Future<ImportTask> add(ImportTask task) async {
    await db.insert('import_tasks', task.toMap());
    manager.tasks.add(task);
    return task;
  }

  Future<TaskCenterItem> item(String id) async =>
      _success(await facade.detail(id));
  Future<TaskCenterCompletedSnapshot> snapshot() async =>
      _success(await facade.snapshotCompletedForCleanup());

  test('legacy title prefix is corrected only in safe read projection',
      () async {
    final task =
        await add(_task('legacy', title: '文档解析任务: study: chapter.pdf'));
    expect((await item(task.id)).fileDisplayName, 'study: chapter.pdf');
    expect(task.title, '文档解析任务: study: chapter.pdf');
    final row =
        (await db.query('import_tasks', where: 'id = ?', whereArgs: [task.id]))
            .single;
    expect(row['title'], task.title);
  });

  for (final state in TaskCenterAttemptStatus.values) {
    test('safe projection and actions for ${state.name}', () async {
      final status = switch (state) {
        TaskCenterAttemptStatus.queued ||
        TaskCenterAttemptStatus.running ||
        TaskCenterAttemptStatus.cancelRequested =>
          TaskStatus.processing,
        TaskCenterAttemptStatus.readyForReview => TaskStatus.pendingReview,
        _ => TaskStatus.error,
      };
      final task = await add(_task('task', status: status, state: state.name));
      final projected = await item(task.id);
      expect(projected.attemptStatus, state);
      expect(projected.coarseStatus.index, status.index);
      final (kind, time) = switch (state) {
        TaskCenterAttemptStatus.queued => (TaskCenterEventKind.queuedAt, 50),
        TaskCenterAttemptStatus.running ||
        TaskCenterAttemptStatus.cancelRequested =>
          (TaskCenterEventKind.startedAt, 100),
        TaskCenterAttemptStatus.readyForReview => (
            TaskCenterEventKind.parsedAt,
            150
          ),
        TaskCenterAttemptStatus.failed => (TaskCenterEventKind.failedAt, 170),
        _ => (null, null),
      };
      expect(projected.eventTime.kind, kind);
      expect(projected.eventTime.utcSeconds, time);
      expect(
          projected.actions.cancel,
          state == TaskCenterAttemptStatus.queued ||
              state == TaskCenterAttemptStatus.running);
      expect(
          projected.actions.retry,
          [
            TaskCenterAttemptStatus.failed,
            TaskCenterAttemptStatus.cancelled,
            TaskCenterAttemptStatus.interrupted
          ].contains(state));
      expect(projected.actions.review,
          state == TaskCenterAttemptStatus.readyForReview);
      expect(projected.actions.clearCompleted, isFalse);
    });
  }

  test(
      'legacy absence stays null; unknown times never borrow completed/created time',
      () async {
    for (final state in ['running', 'readyForReview', 'failed']) {
      final task = _task(state,
          state: state,
          status: state == 'readyForReview'
              ? TaskStatus.pendingReview
              : state == 'failed'
                  ? TaskStatus.error
                  : TaskStatus.processing)
        ..attemptStartedAt = null
        ..parsedAt = null
        ..failedAt = null
        ..completedAt = 180;
      await add(task);
      expect((await item(task.id)).eventTime.utcSeconds, isNull);
    }
    await add(_task('legacy', status: TaskStatus.error, metadata: false));
    final legacy = await item('legacy');
    expect(legacy.attemptStatus, isNull);
    expect(legacy.target.expectedAttemptNumber, isNull);
    expect(legacy.target.expectedReviewRevision, isNull);
    expect(legacy.eventTime.kind, isNull);
    await add(_task('completed', metadata: false));
    expect((await item('completed')).eventTime.utcSeconds, 180);
    final list = _success(await facade.read());
    expect(() => list.items.clear(), throwsUnsupportedError);
  });

  for (final title in ['C:\\private\\a.pdf', '/tmp/a.pdf', 'bad\nname', '  ']) {
    test('unsafe display metadata fails closed', () async {
      await add(_task('unsafe', title: title));
      expect(_failure(await facade.detail('unsafe')),
          HomeTrainingFailure.unavailable);
      expect(_failure(await facade.read()), HomeTrainingFailure.unavailable);
    });
  }

  test(
      'all target commands reject captured absence after a new attempt/review identity',
      () async {
    final task =
        await add(_task('legacy', status: TaskStatus.error, metadata: false));
    final target = (await item(task.id)).target;
    task.diagnostics = _task(task.id, state: 'failed').diagnostics;
    await db.update('import_tasks', task.toMap());
    expect(_failure(await facade.cancel(target)), HomeTrainingFailure.stale);
    expect((await facade.retry(target) as TaskCenterRetryFailed).failure,
        HomeTrainingFailure.stale);
    expect(_failure(await facade.delete(target)), HomeTrainingFailure.stale);
    expect(_failure(await facade.requestReview(target)),
        HomeTrainingFailure.stale);
    final selected = RetryFileSelectionSelected(
        request: RetryFileSelectionRequest(target),
        selection: TaskCenterLocalRetrySource(
            paths: ['/ephemeral/a.pdf'], names: ['a.pdf']));
    expect(_failure(await facade.retryWithSelectedSource(selected)),
        HomeTrainingFailure.stale);
    expect(await db.query('import_tasks'), hasLength(1));
  });

  test('durable-only target drift is stale even when manager projection is old',
      () async {
    final task = await add(_task('task', status: TaskStatus.pendingReview));
    final target = (await item(task.id)).target;
    final diagnostics = {
      ...task.diagnostics!,
      TaskManager.keyReviewDraftRevision: 1
    };
    await db.update('import_tasks', {'diagnostics': jsonEncode(diagnostics)});
    expect(_failure(await facade.requestReview(target)),
        HomeTrainingFailure.stale);
    expect(_failure(await facade.delete(target)), HomeTrainingFailure.stale);
  });

  test('review request carries only exact target; active leases block it',
      () async {
    final task = await add(_task('review', status: TaskStatus.pendingReview));
    final target = (await item(task.id)).target;
    final request = _success(await facade.requestReview(target));
    expect(request.target, same(target));
    final lease = await manager.beginLegacyCommitAttempt(
        taskId: task.id,
        attemptToken: task.attemptToken,
        attemptNumber: task.attemptNumber,
        traceId: task.traceId,
        expectedReviewDraftRevision: 0,
        storageRoute: 'legacyV1',
        storageReason: null);
    expect(lease.status, LegacyCommitLeaseStatus.acquired);
    expect((await item(task.id)).actions.review, isFalse);
    expect(_failure(await facade.requestReview(target)),
        HomeTrainingFailure.conflict);
    manager.releaseLegacyCommitLease(lease.lease!);
  });

  test('snapshot cleanup removes only captured eligible completed rows',
      () async {
    await add(_task('A'));
    await add(_task('B'));
    await add(_task('C', status: TaskStatus.error, state: 'failed'));
    await add(_task('D', status: TaskStatus.pendingReview));
    final captured = await snapshot();
    expect(captured.targets.map((t) => t.taskId), ['A', 'B']);
    expect(() => captured.targets.clear(), throwsUnsupportedError);
    await add(_task('E'));
    await db.insert('questions', {
      'id': 'q',
      'bank_name': 'Bank',
      'content': 'Synthetic',
      'type': 0,
      'standard_answer': 'A',
      'created_at': 50
    });
    final before = await db.query('questions');
    final result = _success(await facade.clearCompleted(captured));
    expect(result.deletedCount, 2);
    expect(result.retainedCount, 0);
    expect(manager.tasks.map((t) => t.id), ['C', 'D', 'E']);
    expect((await db.query('import_tasks', orderBy: 'id')).map((r) => r['id']),
        ['C', 'D', 'E']);
    expect(await db.query('questions'), before);
    expect(_failure(await facade.clearCompleted(captured)),
        HomeTrainingFailure.stale);
    final forged = TaskCenterCompletedSnapshot(
        snapshotId: 'forged', targets: [(await item('E')).target]);
    expect(_failure(await facade.clearCompleted(forged)),
        HomeTrainingFailure.stale);
    expect(await db.query('import_tasks'), hasLength(3));
  });

  test(
      'changed captured members retained; delete failure never removes projection',
      () async {
    final a = await add(_task('A'));
    await add(_task('B'));
    final captured = await snapshot();
    a.diagnostics![TaskManager.keyReviewDraftRevision] = 1;
    await db
        .update('import_tasks', a.toMap(), where: 'id = ?', whereArgs: ['A']);
    await db.execute(
        "CREATE TRIGGER block_delete BEFORE DELETE ON import_tasks BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    final result = _success(await facade.clearCompleted(captured));
    expect(result.deletedCount, 0);
    expect(result.retainedCount, 2);
    expect(manager.tasks, hasLength(2));
    expect(await db.query('import_tasks'), hasLength(2));
  });

  test(
      'cleanup reservation excludes review/retry/lease/late writers until durable delete',
      () async {
    final repository = _HeldDelete();
    manager = TaskManager.forTesting(repository: repository);
    facade = TaskCenterFacade(
        taskManager: manager,
        coordinator: ImportTaskCoordinator(taskManager: manager));
    final task = await add(_task('A'));
    final target = (await item(task.id)).target;
    final clearing = facade.clearCompleted(await snapshot());
    await repository.entered.future;
    expect((await item(task.id)).actions.delete, isFalse);
    expect(_failure(await facade.delete(target)), HomeTrainingFailure.conflict);
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.taskMissing);
    expect(
        await manager.restartAttempt(
            const ImportAttemptRef(
                taskId: 'A',
                attemptNumber: 2,
                attemptToken: 'new',
                traceId: 'new'),
            parseMode: 'ocr',
            explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly),
        ImportAttemptWriteStatus.taskMissing);
    final review = await manager.saveReviewDraft(task.id,
        questions: [],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly);
    expect(review.status, ReviewDraftSaveStatus.taskMissing);
    final lease = await manager.beginLegacyCommitAttempt(
        taskId: task.id,
        attemptToken: task.attemptToken,
        attemptNumber: task.attemptNumber,
        traceId: task.traceId,
        expectedReviewDraftRevision: 0,
        storageRoute: 'legacyV1',
        storageReason: null);
    expect(lease.status, isNot(LegacyCommitLeaseStatus.acquired));
    manager.updateProgress(task.id, 'late', .9);
    repository.release.complete();
    expect(_success(await clearing).deletedCount, 1);
    manager.updateProgress(task.id, 'later', 1);
    expect(await db.query('import_tasks'), isEmpty);
    expect(manager.tasks, isEmpty);
  });

  test('active write tail is not eligible for completed snapshot', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    manager = TaskManager.forTesting(saveTask: (_) async {
      entered.complete();
      await release.future;
    });
    final task = _task('A');
    manager.tasks.add(task);
    facade = TaskCenterFacade(
        taskManager: manager,
        coordinator: ImportTaskCoordinator(taskManager: manager));
    manager.updateProgress(task.id, 'writing', .1);
    await entered.future;
    expect((await snapshot()).targets, isEmpty);
    release.complete();
  });

  test(
      'retry needs explicit file selection; stale picker result cannot start parser',
      () async {
    final task =
        await add(_task('task', status: TaskStatus.error, state: 'failed'));
    final target = (await item(task.id)).target;
    final before = await db.query('import_tasks');
    final result =
        await facade.retry(target) as TaskCenterRetryNeedsFileSelection;
    expect(result.request.target, same(target));
    expect(await db.query('import_tasks'), before);
    task.diagnostics![TaskManager.keyAttemptNumber] = 2;
    await db.update('import_tasks', task.toMap());
    final source = TaskCenterLocalRetrySource(
        paths: ['/ephemeral/a.pdf'], names: ['a.pdf']);
    expect(source.toString(), isNot(contains('ephemeral')));
    expect(
        _failure(await facade.retryWithSelectedSource(
            RetryFileSelectionSelected(
                request: result.request, selection: source))),
        HomeTrainingFailure.stale);
  });

  test(
      'selected source reaches ingestion only; retry resets before work actually starts',
      () async {
    final task =
        await add(_task('task', status: TaskStatus.error, state: 'failed'));
    final target = (await item(task.id)).target;
    final parsed = Completer<ImportParseResult>();
    final entered = Completer<void>();
    final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        parser: (request) {
          expect(request.filePaths, ['/ephemeral/a.pdf']);
          entered.complete();
          return parsed.future;
        });
    facade = TaskCenterFacade(taskManager: manager, coordinator: coordinator);
    final result = await facade.retryWithSelectedSource(
        RetryFileSelectionSelected(
            request: RetryFileSelectionRequest(target),
            selection: TaskCenterLocalRetrySource(
                paths: ['/ephemeral/a.pdf'], names: ['a.pdf'])));
    expect(result, isA<HomeTrainingSuccess<HomeTrainingUnit>>());
    await entered.future;
    expect(task.attemptNumber, 2);
    expect(task.parsedAt, isNull);
    expect(task.failedAt, isNull);
    expect(task.completedAt, isNull);
    final raw = jsonEncode(await db.query('import_tasks'));
    expect(raw, isNot(contains('/ephemeral')));
    expect((await item(task.id)).fileDisplayName, 'paper: chapter 1.pdf');
    parsed.completeError(const FormatException());
    // Failure event serializes after the parser resolves; wait for it without a sleep.
    final settled = Completer<void>();
    void listener() {
      if (task.attemptState == ImportAttemptState.failed &&
          !settled.isCompleted) {
        settled.complete();
      }
    }

    manager.addListener(listener);
    await settled.future;
    manager.removeListener(listener);
  });

  test('mutation gate prevents delete while a B0 maintenance lease exists',
      () async {
    await add(_task('A'));
    final target = (await item('A')).target;
    BackupRestoreMutationGate.instance.tryEnterQuiescence();
    try {
      expect(_failure(await facade.delete(target)),
          HomeTrainingFailure.unavailable);
    } finally {
      BackupRestoreMutationGate.instance.exitQuiescence();
    }
    expect(await db.query('import_tasks'), hasLength(1));
    expect(manager.tasks, hasLength(1));
  });
  test('durable-only coarse status change blocks a review request', () async {
    final task = await add(_task('task', status: TaskStatus.pendingReview));
    final target = (await item(task.id)).target;
    await db.update('import_tasks', {'status': 2, 'completed_at': 200});
    expect(_failure(await facade.requestReview(target)),
        HomeTrainingFailure.conflict);
  });

  test(
      'loading failure or malformed diagnostics is unavailable, not an empty success',
      () async {
    for (final malformed in [false, true]) {
      manager = TaskManager.forTesting(loadTasks: () async {
        if (!malformed) throw const FormatException();
        return [
          {..._task('bad').toMap(), 'diagnostics': 'null'}
        ];
      });
      facade = TaskCenterFacade(
          taskManager: manager,
          coordinator: ImportTaskCoordinator(taskManager: manager));
      expect(_failure(await facade.read()), HomeTrainingFailure.unavailable);
    }
  });

  test('queued review writer excludes completed cleanup candidates', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    manager = TaskManager.forTesting(saveTask: (_) async {
      entered.complete();
      await release.future;
    });
    final review = _task('review', status: TaskStatus.pendingReview);
    manager.tasks.addAll([review, _task('completed')]);
    facade = TaskCenterFacade(
        taskManager: manager,
        coordinator: ImportTaskCoordinator(taskManager: manager));
    final writing = manager.saveReviewDraft(review.id,
        questions: [],
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly);
    await entered.future;
    expect((await snapshot()).targets, isEmpty);
    release.complete();
    expect((await writing).status, ReviewDraftSaveStatus.saved);
  });
}
