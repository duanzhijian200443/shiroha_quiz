import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/import_task_cleanup.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ImportTask _finalTask(
  String id, {
  TaskStatus status = TaskStatus.error,
  Map<String, dynamic>? diagnostics,
}) {
  return ImportTask(
    id: id,
    title: 'Synthetic $id',
    status: status,
    completedAt: 1700000100,
    parsedData: status == TaskStatus.pendingReview
        ? <Map<String, dynamic>>[
            <String, dynamic>{'q_num': 1, 'content': 'Synthetic draft'},
          ]
        : null,
    diagnostics: diagnostics,
  );
}

ImportTask _activeTask(String id, ImportAttemptState state) {
  return ImportTask(
    id: id,
    title: 'Synthetic $id',
    status: TaskStatus.processing,
    diagnostics: <String, dynamic>{
      TaskManager.keyTraceId: 'trace-$id',
      TaskManager.keyParseMode: 'ocr',
      TaskManager.keyAttemptNumber: 1,
      TaskManager.keyAttemptToken: 'attempt-$id',
      TaskManager.keyAttemptState: state.name,
    },
  );
}

ImportTask _typedPendingTask(String id) {
  return ImportTask(
    id: id,
    title: 'Synthetic $id',
    status: TaskStatus.pendingReview,
    parsedData: <Map<String, dynamic>>[
      <String, dynamic>{'q_num': 1, 'content': 'Synthetic typed draft'},
    ],
    diagnostics: <String, dynamic>{
      TaskManager.keyTraceId: 'trace-$id',
      TaskManager.keyAttemptNumber: 1,
      TaskManager.keyAttemptToken: 'attempt-$id',
      TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      TaskManager.keyImportStorageRoute: 'typedV2',
      TaskManager.keyImportStorageReason: 'typed_candidate_ready',
      TaskManager.keyReviewDraftRevision: 1,
    },
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    BackupRestoreMutationGate.resetForTesting();
  });

  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test('delete DB failure keeps durable and memory task visible', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask('delete-failure');
    await db.insert('import_tasks', task.toMap());
    await db.execute('''
      CREATE TRIGGER d4d1_block_import_task_delete
      BEFORE DELETE ON import_tasks
      BEGIN SELECT RAISE(ABORT, 'd4d1_synthetic_delete_failure'); END;
    ''');

    // The save override only enables the real repository-backed cleanup path;
    // it is never called by this test.
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(task);

    final result = await manager.deleteTask('delete-failure');

    expect(result, ImportTaskCleanupStatus.failed);
    expect(manager.tasks.map((task) => task.id), <String>['delete-failure']);
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>['delete-failure'],
      ),
      hasLength(1),
    );

    await db.execute('DROP TRIGGER d4d1_block_import_task_delete');
    expect(await manager.deleteTask(task.id), ImportTaskCleanupStatus.deleted);
    expect(manager.tasks, isEmpty);
  });

  test('delete success removes the durable projection after DB success',
      () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask('delete-success');
    await db.insert('import_tasks', task.toMap());
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(task);

    final result = await manager.deleteTask('delete-success');

    expect(result, ImportTaskCleanupStatus.deleted);
    expect(manager.tasks, isEmpty);
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>['delete-success'],
      ),
      isEmpty,
    );
  });

  test('already absent is an explicit successful cleanup outcome', () async {
    final manager = TaskManager.forTesting(
      deleteTaskPersistence: (_) async => ImportTaskCleanupStatus.alreadyAbsent,
    )..tasks.add(_finalTask('already-absent'));

    expect(
      await manager.deleteTask('already-absent'),
      ImportTaskCleanupStatus.alreadyAbsent,
    );
    expect(manager.tasks, isEmpty);
  });

  test('active task states fail closed before any DB cleanup', () async {
    for (final state in <ImportAttemptState>[
      ImportAttemptState.queued,
      ImportAttemptState.running,
      ImportAttemptState.cancelRequested,
    ]) {
      var deleteCalls = 0;
      final task = _activeTask('active-${state.name}', state);
      final manager = TaskManager.forTesting(
        deleteTaskPersistence: (_) async {
          deleteCalls++;
          return ImportTaskCleanupStatus.deleted;
        },
      )..tasks.add(task);

      expect(
        await manager.deleteTask(task.id),
        ImportTaskCleanupStatus.busy,
        reason: state.name,
      );
      expect(deleteCalls, 0, reason: state.name);
      expect(manager.tasks, hasLength(1), reason: state.name);
    }
  });

  test('durable active attempt diagnostics fail closed before delete',
      () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask(
      'durable-active-attempt',
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.cancelRequested.name,
      },
    );
    await db.insert('import_tasks', task.toMap());
    final repository =
        ImportTaskRepository(databaseHelper: DatabaseHelper.instance);

    expect(
      await repository.deleteImportTask(task.id),
      ImportTaskDeletePersistenceStatus.busy,
    );
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>[task.id],
      ),
      hasLength(1),
    );
  });

  test('pendingReview cleanup is busy and preserves the durable draft',
      () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask(
      'pending-review-cleanup',
      status: TaskStatus.pendingReview,
    );
    await db.insert('import_tasks', task.toMap());
    final before = await db.query(
      'import_tasks',
      where: 'id = ?',
      whereArgs: <Object?>[task.id],
    );
    var deleteCalls = 0;
    final manager = TaskManager.forTesting(
      deleteTaskPersistence: (_) async {
        deleteCalls++;
        return ImportTaskCleanupStatus.deleted;
      },
    )..tasks.add(task);

    expect(await manager.deleteTask(task.id), ImportTaskCleanupStatus.busy);
    expect(deleteCalls, 0);
    expect(manager.tasks, contains(same(task)));
    expect(task.parsedData, isNotEmpty);
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>[task.id],
      ),
      before,
    );
  });

  test('pendingReview readyForReview cleanup is also busy', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask(
      'pending-review-ready-cleanup',
      status: TaskStatus.pendingReview,
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    await db.insert('import_tasks', task.toMap());
    var deleteCalls = 0;
    final manager = TaskManager.forTesting(
      deleteTaskPersistence: (_) async {
        deleteCalls++;
        return ImportTaskCleanupStatus.deleted;
      },
    )..tasks.add(task);

    expect(await manager.deleteTask(task.id), ImportTaskCleanupStatus.busy);
    expect(deleteCalls, 0);
    expect(manager.tasks, contains(same(task)));
    expect(task.parsedData, isNotEmpty);
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>[task.id],
      ),
      hasLength(1),
    );
    expect(
      await ImportTaskRepository(
        databaseHelper: DatabaseHelper.instance,
      ).deleteImportTask(task.id),
      ImportTaskDeletePersistenceStatus.busy,
    );
  });

  test('completed historical readyForReview remains cleanup eligible',
      () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask(
      'completed-ready-cleanup',
      status: TaskStatus.completed,
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    await db.insert('import_tasks', task.toMap());
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(task);

    expect(await manager.deleteTask(task.id), ImportTaskCleanupStatus.deleted);
    expect(manager.tasks, isEmpty);
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>[task.id],
      ),
      isEmpty,
    );
  });

  test('settled error attempts remain cleanup eligible', () async {
    for (final state in <ImportAttemptState>[
      ImportAttemptState.failed,
      ImportAttemptState.cancelled,
      ImportAttemptState.interrupted,
    ]) {
      var deleteCalls = 0;
      final task = _finalTask(
        'settled-error-${state.name}',
        diagnostics: <String, dynamic>{
          TaskManager.keyAttemptState: state.name,
        },
      );
      final manager = TaskManager.forTesting(
        deleteTaskPersistence: (_) async {
          deleteCalls++;
          return ImportTaskCleanupStatus.deleted;
        },
      )..tasks.add(task);

      expect(
        await manager.deleteTask(task.id),
        ImportTaskCleanupStatus.deleted,
        reason: state.name,
      );
      expect(deleteCalls, 1, reason: state.name);
      expect(manager.tasks, isEmpty, reason: state.name);
    }
  });

  test('error readyForReview is busy at application and database boundaries',
      () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final task = _finalTask(
      'error-ready-cleanup',
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    await db.insert('import_tasks', task.toMap());
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(task);

    expect(await manager.deleteTask(task.id), ImportTaskCleanupStatus.busy);
    expect(manager.tasks, contains(same(task)));
    expect(
      await ImportTaskRepository(
        databaseHelper: DatabaseHelper.instance,
      ).deleteImportTask(task.id),
      ImportTaskDeletePersistenceStatus.busy,
    );
    expect(
      await db.query(
        'import_tasks',
        where: 'id = ?',
        whereArgs: <Object?>[task.id],
      ),
      hasLength(1),
    );
  });

  test('clearCompleted keeps review-protected final rows', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final completedReady = _finalTask(
      'clear-completed-ready',
      status: TaskStatus.completed,
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    final errorReady = _finalTask(
      'clear-error-ready',
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    final review = _finalTask(
      'clear-pending-review',
      status: TaskStatus.pendingReview,
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    );
    for (final task in <ImportTask>[completedReady, errorReady, review]) {
      await db.insert('import_tasks', task.toMap());
    }
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(completedReady)
      ..tasks.add(errorReady)
      ..tasks.add(review);

    expect(
      await manager.clearCompletedTasks(),
      ImportTaskCleanupStatus.deleted,
    );
    expect(manager.tasks.map((task) => task.id), <String>[
      'clear-error-ready',
      'clear-pending-review',
    ]);
    expect(
      (await db.query('import_tasks', orderBy: 'id')).map((row) => row['id']),
      <Object?>['clear-error-ready', 'clear-pending-review'],
    );
  });

  test('pending ReviewDraft write keeps ordinary cleanup busy', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    var saveCalls = 0;
    var deleteCalls = 0;
    final task = _finalTask('review-delete', status: TaskStatus.pendingReview);
    final manager = TaskManager.forTesting(
      saveTask: (_) async {
        saveCalls++;
        if (saveCalls == 1) {
          writeStarted.complete();
          await releaseWrite.future;
        }
      },
      deleteTaskPersistence: (_) async {
        deleteCalls++;
        return ImportTaskCleanupStatus.deleted;
      },
    )..tasks.add(task);

    final draftWrite = manager.saveReviewDraft(
      'review-delete',
      questions: const <Map<String, dynamic>>[
        <String, dynamic>{'q_num': 1, 'content': 'Updated synthetic draft'},
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    await writeStarted.future;

    expect(
      await manager.deleteTask(task.id),
      ImportTaskCleanupStatus.busy,
    );
    expect(deleteCalls, 0);
    expect(manager.tasks, hasLength(1));
    expect(task.parsedData?.single['content'], 'Synthetic draft');

    releaseWrite.complete();

    expect((await draftWrite).status, ReviewDraftSaveStatus.saved);
    expect(task.parsedData?.single['content'], 'Updated synthetic draft');
    expect(manager.tasks, contains(same(task)));
  });

  test('active attempt cleanup waits for a settled state before delete',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final events = <String>[];
    var saveCalls = 0;
    final manager = TaskManager.forTesting(
      saveTask: (_) async {
        saveCalls++;
        events.add('save-$saveCalls');
        if (saveCalls == 1) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
      deleteTaskPersistence: (_) async {
        events.add('delete');
        return ImportTaskCleanupStatus.deleted;
      },
    );
    const attempt = ImportAttemptRef(
      taskId: 'attempt-delete',
      attemptNumber: 1,
      attemptToken: 'attempt-1',
      traceId: 'trace-1',
    );
    final initialWrite = manager.addAttemptTask(
      ImportTask(
        id: attempt.taskId,
        title: 'Synthetic attempt-delete',
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-1',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'attempt-1',
          TaskManager.keyAttemptState: 'running',
        },
      ),
    );
    await firstWriteStarted.future;

    final failedSnapshot = manager.failAttempt(attempt, 'synthetic failure');
    final deleteWhileActive = manager.deleteTask(attempt.taskId);
    releaseFirstWrite.complete();

    expect(await initialWrite, ImportAttemptWriteStatus.applied);
    expect(await deleteWhileActive, ImportTaskCleanupStatus.busy);
    expect(await failedSnapshot, ImportAttemptWriteStatus.applied);
    expect(manager.tasks, hasLength(1));
    expect(events, isNot(contains('delete')));

    expect(
      await manager.deleteTask(attempt.taskId),
      ImportTaskCleanupStatus.deleted,
    );
    expect(manager.tasks, isEmpty);
    expect(events.last, 'delete');
  });

  test('typed commit lease makes pending cleanup busy with zero mutation',
      () async {
    var deleteCalls = 0;
    final manager = TaskManager.forTesting(
      deleteTaskPersistence: (_) async {
        deleteCalls++;
        return ImportTaskCleanupStatus.deleted;
      },
    )..tasks.add(_typedPendingTask('typed-lease-delete'));

    final leaseResult = await manager.beginTypedCommitAttempt(
      taskId: 'typed-lease-delete',
      attemptToken: 'attempt-typed-lease-delete',
      attemptNumber: 1,
      expectedReviewDraftRevision: 1,
    );
    expect(leaseResult.status, TypedCommitLeaseStatus.acquired);

    // Model the durable typed commit publishing `completed` before the
    // lease-cleanup tail has released the task-scoped arbitration lease.
    manager.tasks.single.status = TaskStatus.completed;
    expect(
      await manager.deleteTask('typed-lease-delete'),
      ImportTaskCleanupStatus.busy,
    );
    expect(deleteCalls, 0);
    expect(manager.tasks, hasLength(1));
    manager.releaseTypedCommitLease(leaseResult.lease!);
  });

  test('clearCompleted DB failure keeps all memory projections', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final completed = _finalTask('clear-completed');
    final error = _finalTask('clear-error');
    final review = _finalTask('clear-review', status: TaskStatus.pendingReview);
    for (final task in <ImportTask>[completed, error, review]) {
      await db.insert('import_tasks', task.toMap());
    }
    await db.execute('''
      CREATE TRIGGER d4d1_block_clear_completed
      BEFORE DELETE ON import_tasks
      BEGIN SELECT RAISE(ABORT, 'd4d1_synthetic_clear_failure'); END;
    ''');

    // The save override only enables the real repository-backed cleanup path;
    // it is never called by this test.
    final manager = TaskManager.forTesting(saveTask: (_) async {})
      ..tasks.add(completed)
      ..tasks.add(error)
      ..tasks.add(review);

    final result = await manager.clearCompletedTasks();

    expect(result, ImportTaskCleanupStatus.failed);
    expect(
      manager.tasks.map((task) => task.id),
      containsAll(<String>['clear-completed', 'clear-error', 'clear-review']),
    );
    expect(await db.query('import_tasks'), hasLength(3));
  });

  test('retention cleanup failure does not block task loading', () async {
    final persisted = _finalTask('retention-survivor').toMap();
    final manager = TaskManager.forTesting(
      loadTasks: () async => <Map<String, dynamic>>[persisted],
      deleteOldImportTasks: (_) async {
        throw StateError('synthetic retention failure');
      },
    );

    await manager.ready;

    expect(
        manager.tasks.map((task) => task.id), <String>['retention-survivor']);
  });

  test('retention deletes only old settled final workflow rows', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    final oldFinal = _finalTask('retention-old-final').toMap();
    final oldError = _finalTask('retention-old-error').toMap();
    final oldErrorReview = _finalTask(
      'retention-old-error-review',
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    ).toMap();
    final oldCompletedReady = _finalTask(
      'retention-old-completed-ready',
      status: TaskStatus.completed,
      diagnostics: <String, dynamic>{
        TaskManager.keyAttemptState: ImportAttemptState.readyForReview.name,
      },
    ).toMap();
    final oldReview = _finalTask(
      'retention-old-review',
      status: TaskStatus.pendingReview,
    ).toMap();
    final oldActive = ImportTask(
      id: 'retention-old-active',
      title: 'Synthetic retention-old-active',
      status: TaskStatus.processing,
      completedAt: 1700000000,
      diagnostics: const <String, dynamic>{
        TaskManager.keyAttemptState: 'running',
      },
    ).toMap();
    await db.insert('import_tasks', oldFinal);
    await db.insert('import_tasks', oldError);
    await db.insert('import_tasks', oldErrorReview);
    await db.insert('import_tasks', oldCompletedReady);
    await db.insert('import_tasks', oldReview);
    await db.insert('import_tasks', oldActive);

    final repository =
        ImportTaskRepository(databaseHelper: DatabaseHelper.instance);
    final deleted = await repository.deleteOldImportTasks(1700000200);

    expect(
      deleted,
      containsAll(<String>[
        'retention-old-final',
        'retention-old-error',
        'retention-old-completed-ready',
      ]),
    );
    expect(
      (await db.query('import_tasks', orderBy: 'id')).map((row) => row['id']),
      <Object?>[
        'retention-old-active',
        'retention-old-error-review',
        'retention-old-review',
      ],
    );
  });

  test('all cleanup paths preserve Questions and typed sidecars', () async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final db = await DatabaseHelper.instance.database;
    for (final suffix in <String>['one', 'two']) {
      final questionId = 'cleanup-question-$suffix';
      await db.insert('questions', <String, Object?>{
        'id': questionId,
        'type': 0,
        'content': 'Synthetic cleanup question $suffix',
        'options': jsonEncode(<String>['A', 'B']),
        'standard_answer': 'A',
        'explanation': 'Synthetic explanation',
        'raw_explanation': 'Synthetic raw explanation',
        'created_at': 1700000000,
        'bank_name': 'Synthetic cleanup bank',
      });
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': questionId,
        'payload_schema_version': 2,
        'payload_json': '{"synthetic":true}',
      });
    }
    final beforeQuestions = await db.query('questions', orderBy: 'id');
    final beforeSidecars =
        await db.query('question_v2_payloads', orderBy: 'question_id');

    final taskOne = _finalTask('cleanup-task-one');
    final taskTwo = _finalTask('cleanup-task-two');
    final taskThree = _finalTask('cleanup-task-three');
    await db.insert('import_tasks', taskOne.toMap());
    await db.insert('import_tasks', taskTwo.toMap());
    final repository =
        ImportTaskRepository(databaseHelper: DatabaseHelper.instance);
    final manager = TaskManager.forTesting(
      deleteTaskPersistence: (id) async {
        final result = await repository.deleteImportTask(id);
        return switch (result) {
          ImportTaskDeletePersistenceStatus.deleted =>
            ImportTaskCleanupStatus.deleted,
          ImportTaskDeletePersistenceStatus.alreadyAbsent =>
            ImportTaskCleanupStatus.alreadyAbsent,
          ImportTaskDeletePersistenceStatus.busy =>
            ImportTaskCleanupStatus.busy,
        };
      },
      clearCompletedPersistence: (excludedIds, candidateIds) {
        return repository.clearCompletedImportTasks(
          excludedIds: excludedIds,
          candidateIds: candidateIds,
        );
      },
    )
      ..tasks.add(taskOne)
      ..tasks.add(taskTwo);

    expect(
      await manager.deleteTask(taskOne.id),
      ImportTaskCleanupStatus.deleted,
    );
    expect(
        await manager.clearCompletedTasks(), ImportTaskCleanupStatus.deleted);
    await db.insert('import_tasks', taskThree.toMap());
    expect(
      await repository.deleteOldImportTasks(1700000200),
      contains(taskThree.id),
    );
    expect(await db.query('import_tasks'), isEmpty);

    final afterQuestions = await db.query('questions', orderBy: 'id');
    final afterSidecars =
        await db.query('question_v2_payloads', orderBy: 'question_id');
    expect(afterQuestions, beforeQuestions);
    expect(afterSidecars, beforeSidecars);
  });
}
