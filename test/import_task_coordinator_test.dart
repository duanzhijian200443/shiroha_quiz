import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<ImportTask> _waitForTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.first)) return matches.first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Task did not reach the expected state.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final manager = TaskManager.forTesting();

  setUp(() async {
    await manager.ready;
    manager.tasks.clear();
  });

  tearDown(() {
    manager.tasks.clear();
  });

  test('waits for task manager readiness before creating or parsing a task',
      () async {
    final readiness = Completer<void>();
    var parserCalled = false;
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: readiness.future,
      parser: (request) async {
        parserCalled = true;
        return const ImportParseResult(questions: [
          {
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': ['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          }
        ]);
      },
      taskIdFactory: () => 'task-readiness',
      traceIdFactory: () => 'trace-readiness',
    );

    final pendingDispatch = coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    await Future<void>.delayed(Duration.zero);

    expect(manager.tasks, isEmpty);
    expect(parserCalled, isFalse);

    readiness.complete();
    final handle = await pendingDispatch;
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(parserCalled, isTrue);
    expect(task.traceId, 'trace-readiness');
    expect(task.parseMode, 'ocr');
  });

  test('preserves safe diagnostics and transitions successful parse to review',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [
          {
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': ['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          }
        ],
        warnings: ['synthetic warning'],
        diagnostics: {'safeCount': 1},
      ),
      taskIdFactory: () => 'task-success',
      traceIdFactory: () => 'trace-success',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(task.warnings, ['synthetic warning']);
    expect(task.diagnostics?['safeCount'], 1);
    expect(task.traceId, 'trace-success');
    expect(task.parsedData, hasLength(1));
  });

  test('empty result becomes an error task without entering review', () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => const ImportParseResult(
        questions: [],
        diagnostics: {'status': 'failed_empty_ocr_blocks'},
      ),
      taskIdFactory: () => 'task-empty',
      traceIdFactory: () => 'trace-empty',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const ['fixture.pdf'],
      fileNames: const ['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );

    expect(task.parsedData, isNull);
    expect(task.traceId, 'trace-empty');
    expect(task.diagnostics?['status'], 'failed_empty_ocr_blocks');
  });
}
