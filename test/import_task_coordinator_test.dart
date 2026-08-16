import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_failure_classifier.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
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

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> flush() async {}

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }
}

class _FailureCase {
  const _FailureCase({
    required this.name,
    required this.error,
    required this.expectedType,
    required this.expectedMessage,
  });

  final String name;
  final Object error;
  final String expectedType;
  final String expectedMessage;
}

class _EmptyOcrFailureCase {
  const _EmptyOcrFailureCase({
    required this.name,
    required this.status,
    required this.expectedType,
    required this.expectedMessage,
    this.ocrErrorType,
  });

  final String name;
  final String status;
  final String? ocrErrorType;
  final String expectedType;
  final String expectedMessage;
}

const _sensitiveFragments = <String>[
  'fixture-secret',
  'Authorization: Bearer fixture-token',
  r'C:\private\fixture.pdf',
  'OCR-SENSITIVE-CONTENT',
  '{"rawResponse":"PRIVATE"}',
];
final _sensitiveFailureText = _sensitiveFragments.join(' ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final manager = TaskManager.forTesting();
  late _MemoryLogSink logSink;

  setUp(() async {
    await manager.ready;
    manager.tasks.clear();
    logSink = _MemoryLogSink();
    AppLogger.setSink(logSink);
  });

  tearDown(() async {
    await AppLogger.flush();
    AppLogger.setSink(null);
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

  test('persists and restores the request explanation retention mode',
      () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        expect(
          request.explanationRetentionMode,
          ExplanationRetentionMode.allQuestionTypes,
        );
        return ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic question',
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': 'Synthetic explanation',
            },
          ],
          explanationRetentionMode: request.explanationRetentionMode,
        );
      },
      taskIdFactory: () => 'task-retention',
      traceIdFactory: () => 'trace-retention',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (candidate) => candidate.status == TaskStatus.pendingReview,
    );
    final restored = ImportTask.fromMap(task.toMap());

    expect(
      task.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      task.diagnostics?[TaskManager.keyExplanationRetentionMode],
      ExplanationRetentionMode.allQuestionTypes.name,
    );
    expect(
      restored.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
  });

  test(
      'independent OCR batch creates all tasks first and starts parses concurrently',
      () async {
    var taskIndex = 0;
    var traceIndex = 0;
    var activeParses = 0;
    var maxActiveParses = 0;
    var allTasksVisibleAtFirstStart = false;
    final starts = <int>[];
    final allStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'batch-task-${taskIndex++}',
      traceIdFactory: () => 'batch-trace-${traceIndex++}',
      batchIdFactory: () => 'batch-fixture',
    );

    Future<ImportParseResult> parseItem(int index, String taskId) async {
      starts.add(index);
      if (starts.length == 4) {
        allStarted.complete();
      }
      activeParses++;
      maxActiveParses =
          activeParses > maxActiveParses ? activeParses : maxActiveParses;
      if (index == 0) {
        allTasksVisibleAtFirstStart = manager.tasks.length == 4;
      }
      try {
        if (index == 0) {
          await releaseFirst.future;
        }
        if (index == 1) {
          throw StateError('synthetic batch failure');
        }
        return ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '${index + 1}',
              'type': 0,
              'content': 'Synthetic question ${index + 1}',
              'options': const <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': '',
            },
          ],
        );
      } finally {
        activeParses--;
      }
    }

    final batch = await coordinator.dispatchIndependentBatch(
      items: List<ImportTaskBatchItem>.generate(
        4,
        (index) => ImportTaskBatchItem(
          sourceDescription: index < 2 ? 'same.pdf' : 'file-$index.pdf',
          mode: ImportParseMode.ocr,
          parse: (taskId) => parseItem(index, taskId),
        ),
      ),
    );

    expect(batch.batchId, 'batch-fixture');
    expect(batch.tasks.map((handle) => handle.taskId), <String>[
      'batch-task-0',
      'batch-task-1',
      'batch-task-2',
      'batch-task-3',
    ]);
    expect(manager.tasks.map((task) => task.id), <String>[
      'batch-task-0',
      'batch-task-1',
      'batch-task-2',
      'batch-task-3',
    ]);
    expect(
      manager.tasks.map((task) => task.selectionIndex),
      <int?>[0, 1, 2, 3],
    );
    expect(
      manager.tasks.map((task) => task.batchId).toSet(),
      <String?>{'batch-fixture'},
    );
    expect(
      batch.tasks.map((handle) => handle.traceId).toSet(),
      hasLength(4),
    );

    await allStarted.future;
    releaseFirst.complete();
    for (final handle in batch.tasks) {
      await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status != TaskStatus.processing,
      );
    }

    expect(allTasksVisibleAtFirstStart, isTrue);
    expect(starts, <int>[0, 1, 2, 3]);
    expect(maxActiveParses, greaterThan(1));
    expect(
      manager.tasks.map((task) => task.status),
      <TaskStatus>[
        TaskStatus.pendingReview,
        TaskStatus.error,
        TaskStatus.pendingReview,
        TaskStatus.pendingReview,
      ],
    );
    expect(
      manager.tasks.map((task) => task.selectionIndex),
      <int?>[0, 1, 2, 3],
    );
    expect(
      manager.tasks.map((task) => task.batchId).toSet(),
      <String?>{'batch-fixture'},
    );
  });

  test('cancelled old attempt cannot overwrite a successful retry', () async {
    var traceIndex = 0;
    var attemptIndex = 0;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      taskIdFactory: () => 'retry-same-task',
      traceIdFactory: () => 'retry-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-attempt-${attemptIndex++}',
    );

    final firstHandle = await coordinator.dispatch(
      sourceDescription: 'same.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async {
        firstStarted.complete();
        await releaseFirst.future;
        return const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic first attempt',
              'standard_answer': 'A',
            },
          ],
        );
      },
    );
    await firstStarted.future;
    expect(
      await coordinator.cancelOcrTask(firstHandle.taskId),
      ImportAttemptWriteStatus.applied,
    );

    final secondHandle = await coordinator.retryOcrTask(
      taskId: firstHandle.taskId,
      sourceDescription: 'same.pdf',
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '2',
            'content': 'Synthetic second attempt',
            'standard_answer': 'B',
          },
        ],
      ),
    );
    final retried = await _waitForTask(
      manager,
      firstHandle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(secondHandle.taskId, firstHandle.taskId);
    expect(secondHandle.attemptNumber, 2);
    expect(secondHandle.traceId, isNot(firstHandle.traceId));
    expect(secondHandle.attemptToken, isNot(firstHandle.attemptToken));
    expect(retried.attemptState, ImportAttemptState.readyForReview);
    expect(retried.parsedData?.single['q_num'], '2');

    releaseFirst.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final afterOldReturn = manager.tasks.single;
    expect(afterOldReturn.attemptNumber, 2);
    expect(afterOldReturn.traceId, secondHandle.traceId);
    expect(afterOldReturn.attemptToken, secondHandle.attemptToken);
    expect(afterOldReturn.status, TaskStatus.pendingReview);
    expect(afterOldReturn.parsedData?.single['q_num'], '2');
  });

  test('retry request rebuilds OCR parsing from newly selected files',
      () async {
    const sensitiveSelectedPath = r'C:\synthetic-private\replacement.pdf';
    final capturedRequest = Completer<ImportParseRequest>();
    var traceIndex = 0;
    var attemptIndex = 0;
    manager.tasks.add(
      ImportTask(
        id: 'retry-request-task',
        title: 'Synthetic original task',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-request-old-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyExplanationRetentionMode: 'allQuestionTypes',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-request-old-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        capturedRequest.complete(request);
        return const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic replacement question',
              'standard_answer': 'A',
            },
          ],
          explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        );
      },
      traceIdFactory: () => 'retry-request-trace-${traceIndex++}',
      attemptTokenFactory: () => 'retry-request-attempt-${attemptIndex++}',
    );

    final handle = await coordinator.retryOcrRequest(
      taskId: 'retry-request-task',
      filePaths: const <String>[sensitiveSelectedPath],
      fileNames: const <String>['replacement.pdf'],
    );
    final request = await capturedRequest.future;

    expect(handle.taskId, 'retry-request-task');
    expect(handle.attemptNumber, 2);
    expect(handle.traceId, isNot('retry-request-old-trace'));
    expect(handle.attemptToken, isNot('retry-request-old-attempt'));
    expect(request.taskId, 'retry-request-task');
    expect(request.mode, ImportParseMode.ocr);
    expect(request.filePaths, const <String>[sensitiveSelectedPath]);
    expect(request.fileNames, const <String>['replacement.pdf']);
    expect(request.maxConcurrency, 1);
    expect(
      request.explanationRetentionMode,
      ExplanationRetentionMode.allQuestionTypes,
    );
    expect(
      jsonEncode(manager.tasks.single.diagnostics),
      isNot(contains(sensitiveSelectedPath)),
    );
  });

  test('retry request rejects invalid selection before changing attempt',
      () async {
    manager.tasks.add(
      ImportTask(
        id: 'retry-invalid-selection',
        title: 'Synthetic invalid retry',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-invalid-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-invalid-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (_) async => fail('parser must not run'),
    );

    await expectLater(
      coordinator.retryOcrRequest(
        taskId: 'retry-invalid-selection',
        filePaths: const <String>['unsupported.txt'],
        fileNames: const <String>['unsupported.txt'],
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );

    final task = manager.tasks.single;
    expect(task.attemptNumber, 1);
    expect(task.traceId, 'retry-invalid-trace');
    expect(task.attemptToken, 'retry-invalid-attempt');
    expect(task.attemptState, ImportAttemptState.failed);
  });

  test('retry request requires a parser before changing attempt', () async {
    manager.tasks.add(
      ImportTask(
        id: 'retry-missing-parser',
        title: 'Synthetic missing parser',
        status: TaskStatus.error,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'retry-missing-parser-trace',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'retry-missing-parser-attempt',
          TaskManager.keyAttemptState: 'failed',
        },
      ),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
    );

    await expectLater(
      coordinator.retryOcrRequest(
        taskId: 'retry-missing-parser',
        filePaths: const <String>['replacement.pdf'],
        fileNames: const <String>['replacement.pdf'],
      ),
      throwsA(isA<ImportTaskCoordinatorDependencyException>()),
    );

    expect(manager.tasks.single.attemptNumber, 1);
    expect(manager.tasks.single.attemptState, ImportAttemptState.failed);
  });

  for (final mode in <ImportParseMode>[
    ImportParseMode.vision,
    ImportParseMode.text,
  ]) {
    test('independent ${mode.name} batch keeps the existing serial runner',
        () async {
      var taskIndex = 0;
      var traceIndex = 0;
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => '${mode.name}-task-${taskIndex++}',
        traceIdFactory: () => '${mode.name}-trace-${traceIndex++}',
        batchIdFactory: () => '${mode.name}-batch',
      );

      Future<ImportParseResult> parseItem(int index) async {
        if (index == 0) {
          firstStarted.complete();
          await releaseFirst.future;
        } else if (index == 1) {
          secondStarted.complete();
        }
        return ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '${index + 1}',
              'type': 0,
              'content': 'Synthetic question ${index + 1}',
              'options': const <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': '',
            },
          ],
        );
      }

      final batch = await coordinator.dispatchIndependentBatch(
        items: List<ImportTaskBatchItem>.generate(
          3,
          (index) => ImportTaskBatchItem(
            sourceDescription: '${mode.name}-$index.pdf',
            mode: mode,
            parse: (_) => parseItem(index),
          ),
        ),
      );

      await firstStarted.future;
      expect(manager.tasks, hasLength(3));
      expect(secondStarted.isCompleted, isFalse);

      releaseFirst.complete();
      await secondStarted.future;
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }
    });
  }

  test('empty result persists only allowlisted failure diagnostics', () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult(
        questions: const [],
        warnings: <String>[_sensitiveFailureText],
        diagnostics: <String, dynamic>{'rawFailure': _sensitiveFailureText},
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
    expect(task.status, TaskStatus.error);
    expect(task.errorMsg, 'OCR 返回结果格式异常，请稍后重试');
    expect(task.warnings, isEmpty);
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'ProviderResponseFormatFailure');
    expect(task.diagnostics?['status'], 'failed');
    final persisted = jsonEncode(task.toMap());
    for (final fragment in _sensitiveFragments) {
      expect(task.errorMsg, isNot(contains(fragment)));
      expect(jsonEncode(task.diagnostics), isNot(contains(fragment)));
      expect(persisted, isNot(contains(fragment)));
    }
  });

  for (final failure in <_EmptyOcrFailureCase>[
    const _EmptyOcrFailureCase(
      name: 'missing OCR configuration',
      status: 'failed_not_configured',
      expectedType: 'OcrNotConfiguredFailure',
      expectedMessage: '未配置可用的 OCR 引擎，请先完成 OCR 配置',
    ),
    const _EmptyOcrFailureCase(
      name: 'empty OCR blocks',
      status: 'failed_empty_ocr_blocks',
      expectedType: 'OcrEmptyBlocksFailure',
      expectedMessage: 'OCR 未识别到有效文字，请检查文档清晰度后重试',
    ),
    const _EmptyOcrFailureCase(
      name: 'no question regions',
      status: 'failed_no_question_regions',
      expectedType: 'OcrNoQuestionRegionsFailure',
      expectedMessage: 'OCR 已返回文字，但未识别到有效题目区域',
    ),
    const _EmptyOcrFailureCase(
      name: 'no assembled questions',
      status: 'failed_no_assembled_questions',
      expectedType: 'OcrNoAssembledQuestionsFailure',
      expectedMessage: 'OCR 已返回文字，但未能组装出有效题目',
    ),
    const _EmptyOcrFailureCase(
      name: 'provider authentication failure',
      status: 'failed_request',
      ocrErrorType: 'ZhipuOcrAuthenticationException',
      expectedType: 'ProviderRequestFailure',
      expectedMessage: 'OCR 服务请求失败，请检查网络或服务配置',
    ),
    const _EmptyOcrFailureCase(
      name: 'provider response format failure',
      status: 'failed_request',
      ocrErrorType: 'ZhipuOcrResponseFormatException',
      expectedType: 'ProviderResponseFormatFailure',
      expectedMessage: 'OCR 返回结果格式异常，请稍后重试',
    ),
    const _EmptyOcrFailureCase(
      name: 'internal OCR runtime failure',
      status: 'failed_request',
      ocrErrorType: 'StateError',
      expectedType: 'UnknownImportFailure',
      expectedMessage: '导入过程中发生异常，请根据 Trace ID 查看诊断',
    ),
  ]) {
    test(
        'empty OCR ${failure.name} preserves only allowlisted cause diagnostics',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        parser: (request) async => ImportParseResult(
          questions: const <Map<String, dynamic>>[],
          warnings: <String>[_sensitiveFailureText],
          diagnostics: <String, dynamic>{
            'ocr_import_file_0': <String, dynamic>{
              'status': failure.status,
              if (failure.ocrErrorType != null)
                'errorType': failure.ocrErrorType,
              'rawResponse': _sensitiveFailureText,
            },
            'unrelated': <String, dynamic>{
              'status': 'failed_sensitive',
              'errorType': _sensitiveFailureText,
            },
          },
        ),
        taskIdFactory: () => 'task-empty-${failure.name.replaceAll(' ', '-')}',
        traceIdFactory: () => 'trace-empty-ocr',
      );

      final handle = await coordinator.dispatchRequest(
        sourceDescription: r'C:\private\fixture.pdf',
        filePaths: const <String>['fixture.pdf'],
        fileNames: const <String>['fixture.pdf'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
      );
      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.error,
      );
      await AppLogger.flush();

      expect(task.errorMsg, failure.expectedMessage);
      expect(task.diagnostics?['status'], failure.status);
      expect(task.diagnostics?['errorType'], failure.expectedType);
      if (failure.ocrErrorType == null) {
        expect(task.diagnostics, isNot(contains('ocrErrorType')));
      } else {
        expect(
          task.diagnostics?['ocrErrorType'],
          failure.ocrErrorType,
        );
      }

      final persisted = jsonEncode(task.toMap());
      final logs = jsonEncode(
        logSink.records.map((record) => record.toJson()).toList(),
      );
      for (final fragment in _sensitiveFragments) {
        expect(task.errorMsg, isNot(contains(fragment)));
        expect(persisted, isNot(contains(fragment)));
        expect(logs, isNot(contains(fragment)));
      }
    });
  }

  test('default parser span keeps failure details out of logs and task data',
      () async {
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          const <Map<String, dynamic>>[],
      visionParser: (imagePaths) async => const <Map<String, dynamic>>[],
      ocrParser: (
              {required filePath,
              required sourceName,
              required format,
              required ExplanationRetentionMode
                  explanationRetentionMode}) async =>
          throw StateError(_sensitiveFailureText),
    );
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: pipeline.parseFiles,
      taskIdFactory: () => 'task-default-parser',
      traceIdFactory: () => 'trace-default-parser',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: r'C:\private\fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );
    await AppLogger.flush();

    expect(task.traceId, 'trace-default-parser');
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'UnknownImportFailure');
    final logs = jsonEncode(
      logSink.records.map((record) => record.toJson()).toList(),
    );
    for (final fragment in _sensitiveFragments) {
      expect(logs, isNot(contains(fragment)));
      expect(task.errorMsg, isNot(contains(fragment)));
      expect(jsonEncode(task.diagnostics), isNot(contains(fragment)));
    }
  });

  test(
      'final failure clears partial OCR batch data without touching same-name task',
      () async {
    final untouchedTask = ImportTask(
      id: 'task-same-filename',
      title: '文档解析任务: fixture.pdf',
      status: TaskStatus.pendingReview,
      parsedData: const <Map<String, dynamic>>[
        <String, dynamic>{'content': 'other-task-content'},
      ],
      pendingChunks: const <String>['other-task-chunk'],
      failedChunks: const <String>['other-task-failure'],
    );
    manager.addTask(untouchedTask);
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async {
        manager.appendPendingChunks(
          request.taskId,
          'vision',
          <String>[_sensitiveFailureText, 'second-batch'],
        );
        manager.markChunkSuccess(
          request.taskId,
          _sensitiveFailureText,
          <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': _sensitiveFailureText,
              'options': <String>['A', 'B'],
              'standard_answer': 'A',
              'explanation': _sensitiveFailureText,
            },
          ],
        );
        manager.markChunkFailed(request.taskId, 'second-batch');
        throw StateError(_sensitiveFailureText);
      },
      taskIdFactory: () => 'task-partial-batch',
      traceIdFactory: () => 'trace-partial-batch',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.error,
    );

    expect(task.parsedData, isNull);
    expect(task.pendingChunks, isNull);
    expect(task.failedChunks, isNull);
    expect(task.traceId, 'trace-partial-batch');
    expect(task.diagnostics?['failedStage'], 'import_parse');
    expect(task.diagnostics?['errorType'], 'UnknownImportFailure');
    final persisted = jsonEncode(task.toMap());
    for (final fragment in _sensitiveFragments) {
      expect(persisted, isNot(contains(fragment)));
    }

    expect(untouchedTask.status, TaskStatus.pendingReview);
    expect(untouchedTask.parsedData, hasLength(1));
    expect(untouchedTask.pendingChunks, <String>['other-task-chunk']);
    expect(untouchedTask.failedChunks, <String>['other-task-failure']);
  });

  for (final failure in <_FailureCase>[
    _FailureCase(
      name: 'format exception',
      error: FormatException(_sensitiveFailureText),
      expectedType: 'ProviderResponseFormatFailure',
      expectedMessage: 'OCR 返回结果格式异常，请稍后重试',
    ),
    _FailureCase(
      name: 'file system exception',
      error: FileSystemException(_sensitiveFailureText),
      expectedType: 'FileReadFailure',
      expectedMessage: '无法读取导入文件，请检查文件是否仍然存在',
    ),
    _FailureCase(
      name: 'timeout exception',
      error: TimeoutException(_sensitiveFailureText),
      expectedType: 'ProviderRequestFailure',
      expectedMessage: 'OCR 服务请求失败，请检查网络或服务配置',
    ),
    _FailureCase(
      name: 'unknown state error',
      error: StateError(_sensitiveFailureText),
      expectedType: 'UnknownImportFailure',
      expectedMessage: '导入过程中发生异常，请根据 Trace ID 查看诊断',
    ),
    const _FailureCase(
      name: 'cancelled task',
      error: ImportTaskCancelledException(),
      expectedType: 'TaskCancelled',
      expectedMessage: '导入任务已取消',
    ),
  ]) {
    test('${failure.name} is classified without persisting its message',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        parser: (request) async => throw failure.error,
        taskIdFactory: () => 'task-${failure.name.replaceAll(' ', '-')}',
        traceIdFactory: () => 'trace-failure',
      );

      final handle = await coordinator.dispatchRequest(
        sourceDescription: r'C:\private\fixture.pdf',
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
      await AppLogger.flush();

      expect(task.status, TaskStatus.error);
      expect(task.errorMsg, failure.expectedMessage);
      expect(task.traceId, 'trace-failure');
      expect(task.parseMode, 'ocr');
      expect(task.diagnostics?['failedStage'], 'import_parse');
      expect(task.diagnostics?['errorType'], failure.expectedType);
      expect(task.diagnostics?['status'], 'failed');

      final diagnostics = jsonEncode(task.diagnostics);
      final persisted = jsonEncode(task.toMap());
      final logs = jsonEncode(
        logSink.records.map((record) => record.toJson()).toList(),
      );
      for (final fragment in _sensitiveFragments) {
        expect(task.errorMsg, isNot(contains(fragment)));
        expect(diagnostics, isNot(contains(fragment)));
        expect(persisted, isNot(contains(fragment)));
        expect(logs, isNot(contains(fragment)));
      }
    });
  }

  test(
      'route and reason enter task diagnostics only, never the user-visible '
      '_import_diagnostics, and survive reload', () async {
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      parser: (request) async => ImportParseResult.withStorageMetadata(
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic question',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
          },
        ],
        warnings: const <String>['synthetic warning'],
        diagnostics: const <String, dynamic>{'safeCount': 1},
        storageRoute: ImportStorageRoute.legacyV1,
        storageReason: 'typed_candidate_shadow_ready',
      ),
      taskIdFactory: () => 'task-storage-metadata',
      traceIdFactory: () => 'trace-storage-metadata',
    );

    final handle = await coordinator.dispatchRequest(
      sourceDescription: 'fixture.pdf',
      filePaths: const <String>['fixture.pdf'],
      fileNames: const <String>['fixture.pdf'],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
    );
    final task = await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );

    expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'legacyV1');
    expect(
      task.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_shadow_ready',
    );
    final userVisible = task.parsedData!.first['_import_diagnostics'] as List;
    expect(userVisible, isNot(contains('typed_candidate_shadow_ready')));
    expect(userVisible, isNot(contains('_importStorageRoute')));
    expect(userVisible, isNot(contains('_importStorageReason')));
    final restored = ImportTask.fromMap(task.toMap());
    expect(
      restored.diagnostics?[TaskManager.keyImportStorageRoute],
      'legacyV1',
    );
    expect(
      restored.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_shadow_ready',
    );
    expect(restored.parsedData, hasLength(1));
  });

  test('invalid storage reason is rejected at the strict metadata boundary',
      () {
    expect(
      () => ImportParseResult.withStorageMetadata(
        questions: const <Map<String, dynamic>>[],
        storageReason: 'Not A Reason!',
      ),
      throwsA(isA<TypedReviewSnapshotException>()),
    );
  });

  group('OBS-1 import correlation', () {
    test('initial attempt creates task/correlation/trace with attempt 1',
        () async {
      var traceIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => 'obs-initial-task',
        traceIdFactory: () => 'obs-trace-${traceIndex++}',
        attemptTokenFactory: () => 'obs-attempt-1',
      );
      final handle = await coordinator.dispatch(
        sourceDescription: 'same.pdf',
        mode: ImportParseMode.ocr,
        parse: (_) async => const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'content': 'Synthetic question',
              'standard_answer': 'A',
            },
          ],
        ),
      );

      final task = await _waitForTask(
        manager,
        handle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );

      expect(handle.taskId, 'obs-initial-task');
      expect(handle.attemptNumber, 1);
      expect(handle.correlationId, isNotNull);
      expect(
        handle.correlationId,
        matches(RegExp(r'^OBS-[A-Z0-9]{4}-[A-Z0-9]{4}$')),
      );
      expect(handle.parentTraceId, isNull);
      expect(task.correlationId, handle.correlationId);
      expect(task.attemptNumber, 1);
      expect(task.traceId, handle.traceId);

      // The attempt runs inside an importAttempt trace with the correlation.
      final dispatched = logSink.records.where(
        (record) => record.data['stage'] == 'import_dispatch',
      );
      expect(dispatched, isNotEmpty);
      expect(dispatched.first.correlationId, handle.correlationId);
      expect(dispatched.first.traceId, handle.traceId);
      expect(
        dispatched.first.operationKind,
        TraceOperationKind.importAttempt,
      );
      expect(dispatched.first.taskId, handle.taskId);
    });

    test(
        'retry keeps task and correlation, changes trace/token/attempt and '
        'points parent at the previous attempt', () async {
      var traceIndex = 0;
      var attemptIndex = 0;
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        taskIdFactory: () => 'obs-retry-task',
        traceIdFactory: () => 'obs-trace-${traceIndex++}',
        attemptTokenFactory: () => 'obs-attempt-${attemptIndex++}',
      );

      final firstHandle = await coordinator.dispatch(
        sourceDescription: 'same.pdf',
        mode: ImportParseMode.ocr,
        parse: (_) async => throw StateError('synthetic first failure'),
      );
      await _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.status == TaskStatus.error,
      );

      final secondHandle = await coordinator.retryOcrTask(
        taskId: firstHandle.taskId,
        sourceDescription: 'same.pdf',
        parse: (_) async => const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '2',
              'content': 'Synthetic retry question',
              'standard_answer': 'B',
            },
          ],
        ),
      );
      final retried = await _waitForTask(
        manager,
        firstHandle.taskId,
        (task) => task.status == TaskStatus.pendingReview,
      );

      expect(secondHandle.taskId, firstHandle.taskId);
      expect(secondHandle.correlationId, firstHandle.correlationId);
      expect(secondHandle.traceId, isNot(firstHandle.traceId));
      expect(secondHandle.attemptToken, isNot(firstHandle.attemptToken));
      expect(secondHandle.attemptNumber, firstHandle.attemptNumber + 1);
      expect(secondHandle.attemptNumber, 2);
      expect(secondHandle.parentTraceId, firstHandle.traceId);

      expect(retried.correlationId, firstHandle.correlationId);
      expect(retried.traceId, secondHandle.traceId);
      expect(retried.attemptNumber, 2);
      expect(retried.attemptToken, secondHandle.attemptToken);
      expect(
        retried.diagnostics?[TaskManager.keyParentTraceId],
        firstHandle.traceId,
      );

      // Correlation metadata survives progress -> failure -> retry -> review.
      expect(firstHandle.correlationId, isNotNull);
      expect(retried.status, TaskStatus.pendingReview);
    });

    test('batch identity stays independent from per-task correlation',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        batchIdFactory: () => 'obs-batch',
      );
      final batch = await coordinator.dispatchIndependentBatch(
        items: <ImportTaskBatchItem>[
          ImportTaskBatchItem(
            sourceDescription: 'a.pdf',
            mode: ImportParseMode.ocr,
            parse: (_) async => const ImportParseResult(
              questions: <Map<String, dynamic>>[
                <String, dynamic>{'q_num': '1', 'content': 'A'},
              ],
            ),
          ),
          ImportTaskBatchItem(
            sourceDescription: 'b.pdf',
            mode: ImportParseMode.ocr,
            parse: (_) async => const ImportParseResult(
              questions: <Map<String, dynamic>>[
                <String, dynamic>{'q_num': '1', 'content': 'B'},
              ],
            ),
          ),
        ],
      );
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }

      expect(batch.batchId, 'obs-batch');
      expect(batch.tasks, hasLength(2));
      expect(batch.tasks[0].correlationId, isNotNull);
      expect(batch.tasks[1].correlationId, isNotNull);
      expect(
        batch.tasks[0].correlationId,
        isNot(batch.tasks[1].correlationId),
      );
      for (final handle in batch.tasks) {
        expect(handle.correlationId, isNot(batch.batchId));
        final task = manager.tasks.firstWhere(
          (task) => task.id == handle.taskId,
        );
        expect(task.batchId, 'obs-batch');
        expect(task.correlationId, handle.correlationId);
      }
    });

    test('batch tasks inside an enclosing trace still own fresh correlations',
        () async {
      final coordinator = ImportTaskCoordinator(
        taskManager: manager,
        readiness: Future<void>.value(),
        batchIdFactory: () => 'obs-nested-batch',
      );
      final batch = await TraceContext.run(
        correlationId: 'OBS-AAAA-BBBB',
        traceId: 'trace-enclosing',
        operationKind: TraceOperationKind.agentTurn,
        action: () => coordinator.dispatchIndependentBatch(
          items: <ImportTaskBatchItem>[
            ImportTaskBatchItem(
              sourceDescription: 'a.pdf',
              mode: ImportParseMode.ocr,
              parse: (_) async => const ImportParseResult(
                questions: <Map<String, dynamic>>[
                  <String, dynamic>{'q_num': '1', 'content': 'A'},
                ],
              ),
            ),
            ImportTaskBatchItem(
              sourceDescription: 'b.pdf',
              mode: ImportParseMode.ocr,
              parse: (_) async => const ImportParseResult(
                questions: <Map<String, dynamic>>[
                  <String, dynamic>{'q_num': '1', 'content': 'B'},
                ],
              ),
            ),
          ],
        ),
      );
      for (final handle in batch.tasks) {
        await _waitForTask(
          manager,
          handle.taskId,
          (task) => task.status == TaskStatus.pendingReview,
        );
      }

      expect(batch.batchId, 'obs-nested-batch');
      expect(batch.tasks, hasLength(2));
      final first = batch.tasks[0];
      final second = batch.tasks[1];
      expect(first.correlationId, isNot(second.correlationId));
      expect(first.correlationId, isNot('OBS-AAAA-BBBB'));
      expect(second.correlationId, isNot('OBS-AAAA-BBBB'));
      expect(
        first.correlationId,
        matches(RegExp(r'^OBS-[A-Z0-9]{4}-[A-Z0-9]{4}$')),
      );
      // The enclosing trace is the parent of every task in the batch.
      expect(first.parentTraceId, 'trace-enclosing');
      expect(second.parentTraceId, 'trace-enclosing');
      // Persisted metadata matches the handles.
      for (final handle in batch.tasks) {
        final task = manager.tasks.firstWhere(
          (task) => task.id == handle.taskId,
        );
        expect(task.correlationId, handle.correlationId);
        expect(task.parentTraceId, 'trace-enclosing');
        expect(task.batchId, 'obs-nested-batch');
      }
    });
  });
}
