import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
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
              required format}) async =>
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
}
