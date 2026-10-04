import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

ImportTask _task() =>
    ImportTask(id: 'task', title: 'Synthetic.pdf', createdAt: 50, diagnostics: {
      TaskManager.keyAttemptNumber: 1,
      TaskManager.keyAttemptToken: 'token-1',
      TaskManager.keyTraceId: 'trace-1',
      TaskManager.keyAttemptState: 'queued',
      TaskManager.keyParseMode: 'ocr',
      TaskManager.keyImportStorageRoute: 'legacyV1'
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late TaskManager manager;
  late ImportTask task;
  var now = 100;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    db = await DatabaseHelper.instance.database;
    now = 100;
    manager = TaskManager.forTesting(
        repository: ImportTaskRepository(), nowUtcSeconds: () => now);
    task = _task();
    expect(
        await manager.addAttemptTask(task), ImportAttemptWriteStatus.applied);
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    BackupRestoreMutationGate.resetForTesting();
  });
  Future<Map<String, Object?>> row() async =>
      (await db.query('import_tasks')).single;

  test('exact nullable/integer model round trip', () {
    for (final time in [null, 0, 1700000123]) {
      final source = ImportTask(
          id: 'value',
          title: 'Synthetic',
          attemptStartedAt: time,
          parsedAt: time,
          failedAt: time);
      final restored = ImportTask.fromMap(source.toMap());
      expect(restored.attemptStartedAt, time);
      expect(restored.parsedAt, time);
      expect(restored.failedAt, time);
    }
  });

  test('accepted running time persisted once; repeated callback is a no-op',
      () async {
    expect((await row())['attempt_started_at'], isNull);
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.applied);
    expect(task.attemptStartedAt, 100);
    now = 200;
    final before = await row();
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.applied);
    expect(await row(), before);
    expect(task.attemptStartedAt, 100);
  });

  test('parse success owns parsedAt and failure owns failedAt atomically',
      () async {
    await manager.markAttemptRunning(task.attemptRef!);
    now = 150;
    expect(
        await manager.requireAttemptReview(
            task.attemptRef!,
            'ready',
            [
              {'id': 'q', 'q_num': 1, 'content': 'Synthetic'}
            ],
            'Bank',
            'Math'),
        ImportAttemptWriteStatus.applied);
    expect(task.status, TaskStatus.pendingReview);
    expect(task.attemptState, ImportAttemptState.readyForReview);
    expect((await row())['parsed_at'], 150);
    expect(task.attemptStartedAt, 100);
    expect(task.failedAt, isNull);
    // completed_at remains the existing compatibility retention stamp; the
    // facade uses parsed_at until QuestionRepository commits completed status.
  });

  test(
      'failed -> retry resets all four clocks; old callbacks cannot touch attempt 2',
      () async {
    final old = task.attemptRef!;
    await manager.markAttemptRunning(old);
    now = 170;
    expect(await manager.failAttempt(old, 'synthetic failure'),
        ImportAttemptWriteStatus.applied);
    expect((await row())['failed_at'], 170);
    task.parsedAt = 160;
    await db.update('import_tasks', {'parsed_at': 160});
    const next = ImportAttemptRef(
        taskId: 'task',
        attemptNumber: 2,
        attemptToken: 'token-2',
        traceId: 'trace-2');
    expect(
        await manager.restartAttempt(next,
            parseMode: 'ocr',
            explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly),
        ImportAttemptWriteStatus.applied);
    final before = await row();
    for (final key in [
      'attempt_started_at',
      'parsed_at',
      'failed_at',
      'completed_at'
    ]) {
      expect(before[key], isNull);
    }
    expect(task.attemptState, ImportAttemptState.queued);
    expect(
        await manager.markAttemptRunning(old), ImportAttemptWriteStatus.stale);
    expect(await manager.requireAttemptReview(old, 'old', [], 'Bank', 'Math'),
        ImportAttemptWriteStatus.stale);
    expect(
        await manager.failAttempt(old, 'old'), ImportAttemptWriteStatus.stale);
    expect(await manager.requestAttemptCancellation(old),
        ImportAttemptWriteStatus.stale);
    expect(await manager.finalizeAttemptCancelled(old),
        ImportAttemptWriteStatus.stale);
    await ImportAttemptContext.run(
        attempt: old,
        action: () async {
          manager.requireReview(task.id, 'old', [], 'Bank', 'Math');
          manager.failTask(task.id, 'old');
          manager.updateProgress(task.id, 'old', .9);
          manager.attachDiagnostics(task.id, diagnostics: {'old': true});
          manager.markChunkSuccess(task.id, 'old', []);
        });
    // Wait behind scoped compatibility delegates, using the accepted queue.
    now = 200;
    await manager.updateAttemptProgress(next, 'current', .2);
    final after = await row();
    for (final key in [
      'attempt_started_at',
      'parsed_at',
      'failed_at',
      'completed_at',
      'parsed_data',
      'error_msg',
      'diagnostics'
    ]) {
      expect(after[key], before[key]);
    }
    await manager.markAttemptRunning(next);
    expect(task.attemptStartedAt, 200);
  });

  for (final transition in ['running', 'parse', 'fail', 'retry']) {
    test('$transition persistence failure leaves memory and DB unchanged',
        () async {
      final attempt = task.attemptRef!;
      if (transition == 'retry') {
        await manager.failAttempt(attempt, 'old');
      }
      final before = await row();
      final memory = task.toMap();
      await db.execute(
          "CREATE TRIGGER block_write BEFORE UPDATE ON import_tasks BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
      final status = switch (transition) {
        'running' => await manager.markAttemptRunning(attempt),
        'parse' => await manager.requireAttemptReview(
            attempt, 'ready', [], 'Bank', 'Math'),
        'fail' => await manager.failAttempt(attempt, 'failed'),
        _ => await manager.restartAttempt(
            const ImportAttemptRef(
                taskId: 'task',
                attemptNumber: 2,
                attemptToken: 'token-2',
                traceId: 'trace-2'),
            parseMode: 'ocr',
            explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly),
      };
      expect(status, ImportAttemptWriteStatus.persistenceFailed);
      expect(await row(), before);
      expect(task.toMap(), memory);
    });
  }

  test('cancelled and startup interrupted never get a failed time', () async {
    await manager.requestAttemptCancellation(task.attemptRef!);
    expect(task.attemptState, ImportAttemptState.cancelled);
    expect((await row())['failed_at'], isNull);
    final active = _task()..status = TaskStatus.processing;
    manager = TaskManager.forTesting(
        saveTask: (map) async => db.update('import_tasks', map),
        loadTasks: () async => [active.toMap()]);
    await manager.ready;
    expect(manager.tasks.single.attemptState, ImportAttemptState.interrupted);
    expect(manager.tasks.single.failedAt, isNull);
  });

  test(
      'legacy accepted parse delegates to current writer; synthetic rows get no fake event',
      () async {
    now = 150;
    manager.requireReview(task.id, 'ready', [], 'Bank', 'Math');
    // Readiness is deliberately not a writer barrier; enqueue a current event.
    await manager.updateAttemptProgress(task.attemptRef!, 'ignored', 1);
    expect(task.parsedAt, 150);
    final synthetic =
        ImportTask(id: 'synthetic', title: 'Synthetic', createdAt: 50);
    final legacy = TaskManager.forTesting()..tasks.add(synthetic);
    legacy.requireReview(synthetic.id, 'ready', [], 'Bank', 'Math');
    expect(synthetic.parsedAt, isNull);
    expect(synthetic.diagnostics, isNull);
  });

  test(
      'missing durable row never resurrects from a late accepted attempt write',
      () async {
    await db.delete('import_tasks');
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.stale);
    expect(await db.query('import_tasks'), isEmpty);
    expect(task.attemptStartedAt, isNull);
  });
  test('legacy JSON spacing/key order is not mistaken for attempt drift',
      () async {
    final reversed = Map<String, dynamic>.fromEntries(
        task.diagnostics!.entries.toList().reversed);
    const encoder = JsonEncoder.withIndent('  ');
    await db.update('import_tasks', {'diagnostics': encoder.convert(reversed)});
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.applied);
    expect(task.attemptStartedAt, 100);
  });

  test(
      'durable completed status cannot be overwritten by an old running snapshot',
      () async {
    await db.update('import_tasks',
        {'status': 2, 'completed_at': 300, 'parsed_data': null});
    final before = await row();
    expect(await manager.markAttemptRunning(task.attemptRef!),
        ImportAttemptWriteStatus.stale);
    expect(await row(), before);
    expect(task.attemptStartedAt, isNull);
  });
}
