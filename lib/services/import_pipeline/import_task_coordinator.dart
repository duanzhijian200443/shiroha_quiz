import 'dart:async';

import 'package:path/path.dart' as p;

import '../../application/import_review/typed_review_snapshot.dart';
import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../../data/models/question_identity.dart';
import '../task_manager.dart';
import 'import_attempt_context.dart';
import 'import_failure_classifier.dart';
import 'import_file_detector.dart';
import 'import_format.dart';
import 'import_parse_request.dart';
import 'import_parse_result.dart';
import 'import_question_field_policy.dart';
import 'ocr_request_scheduler.dart';

typedef ImportRequestParser = Future<ImportParseResult> Function(
  ImportParseRequest request,
);

typedef ImportTaskParseAction = Future<ImportParseResult> Function(
  String taskId,
);

class ImportTaskHandle {
  const ImportTaskHandle({
    required this.taskId,
    required this.traceId,
    required this.attemptNumber,
    required this.attemptToken,
    this.correlationId,
    this.parentTraceId,
  });

  final String taskId;
  final String traceId;
  final int attemptNumber;
  final String attemptToken;

  /// OBS-1 correlation identity of this import lineage. Every attempt of one
  /// ImportTask keeps the same correlationId.
  final String? correlationId;

  /// OBS-1 parent trace: the trace that directly triggered this attempt
  /// (null for the initial attempt without an enclosing operation).
  final String? parentTraceId;

  ImportAttemptRef get attempt => ImportAttemptRef(
        taskId: taskId,
        attemptNumber: attemptNumber,
        attemptToken: attemptToken,
        traceId: traceId,
      );
}

class ImportTaskBatchItem {
  const ImportTaskBatchItem({
    required this.sourceDescription,
    required this.mode,
    required this.parse,
    this.explanationRetentionMode = ExplanationRetentionMode.subjectiveOnly,
  });

  final String sourceDescription;
  final ImportParseMode mode;
  final ImportTaskParseAction parse;
  final ExplanationRetentionMode explanationRetentionMode;
}

class ImportTaskBatchHandle {
  const ImportTaskBatchHandle({
    required this.batchId,
    required this.tasks,
  });

  final String batchId;
  final List<ImportTaskHandle> tasks;
}

class ImportTaskCoordinatorDependencyException implements Exception {
  const ImportTaskCoordinatorDependencyException();

  @override
  String toString() => 'ImportTaskCoordinatorDependencyException';
}

class ImportTaskAttemptPersistenceException implements Exception {
  const ImportTaskAttemptPersistenceException();

  @override
  String toString() => 'ImportTaskAttemptPersistenceException';
}

class ImportTaskRetryRejectedException implements Exception {
  const ImportTaskRetryRejectedException();

  @override
  String toString() => 'ImportTaskRetryRejectedException';
}

class ImportTaskCoordinator {
  ImportTaskCoordinator({
    TaskManager? taskManager,
    Future<void>? readiness,
    ImportRequestParser? parser,
    OcrRequestScheduler? requestScheduler,
    String Function()? taskIdFactory,
    String Function()? traceIdFactory,
    String Function()? attemptTokenFactory,
    String Function()? batchIdFactory,
    this.onReadyForReview,
  })  : _taskManager = taskManager ?? TaskManager.instance,
        _readiness = readiness ?? (taskManager ?? TaskManager.instance).ready,
        _parser = parser,
        _requestScheduler = requestScheduler ?? OcrRequestScheduler(),
        _taskIdFactory = taskIdFactory ?? _createTaskId,
        _traceIdFactory = traceIdFactory ?? TraceContext.createTraceId,
        _attemptTokenFactory = attemptTokenFactory ?? ImportAttemptToken.create,
        _batchIdFactory = batchIdFactory ?? _createBatchId;

  static const String keySourceQuestionCount = '_sourceQuestionCount';
  static const String keySourceQuestionNumbers = '_sourceQuestionNumbers';
  static const Set<String> _safeOcrStatuses = <String>{
    'failed_not_configured',
    'failed_empty_ocr_blocks',
    'failed_no_question_regions',
    'failed_no_assembled_questions',
    'failed_request',
  };
  static const Set<String> _safeOcrErrorTypes = <String>{
    'FileSystemException',
    'PathNotFoundException',
    'ZhipuOcrAuthenticationException',
    'ZhipuOcrRequestException',
    'ZhipuOcrResponseFormatException',
    'TimeoutException',
    'SocketException',
    'ClientException',
    'FormatException',
    'StateError',
    'TypeError',
    'RangeError',
    'ArgumentError',
    'UnsupportedError',
    'Exception',
  };
  static const ImportFailureClassification _ocrNotConfiguredFailure =
      ImportFailureClassification(
    type: ImportFailureType.providerRequest,
    errorType: 'OcrNotConfiguredFailure',
    userMessage: '未配置可用的 OCR 引擎，请先完成 OCR 配置',
  );
  static const ImportFailureClassification _ocrEmptyBlocksFailure =
      ImportFailureClassification(
    type: ImportFailureType.providerResponseFormat,
    errorType: 'OcrEmptyBlocksFailure',
    userMessage: 'OCR 未识别到有效文字，请检查文档清晰度后重试',
  );
  static const ImportFailureClassification _ocrNoQuestionRegionsFailure =
      ImportFailureClassification(
    type: ImportFailureType.unknown,
    errorType: 'OcrNoQuestionRegionsFailure',
    userMessage: 'OCR 已返回文字，但未识别到有效题目区域',
  );
  static const ImportFailureClassification _ocrNoAssembledQuestionsFailure =
      ImportFailureClassification(
    type: ImportFailureType.unknown,
    errorType: 'OcrNoAssembledQuestionsFailure',
    userMessage: 'OCR 已返回文字，但未能组装出有效题目',
  );

  final TaskManager _taskManager;
  final Future<void> _readiness;
  final ImportRequestParser? _parser;
  final OcrRequestScheduler _requestScheduler;
  final String Function() _taskIdFactory;
  final String Function() _traceIdFactory;
  final String Function() _attemptTokenFactory;
  final String Function() _batchIdFactory;
  final void Function(String sourceDescription)? onReadyForReview;

  static String _createTaskId() =>
      'task_${DateTime.now().microsecondsSinceEpoch}';
  static String _createBatchId() =>
      'batch_${DateTime.now().microsecondsSinceEpoch}';

  Future<ImportTaskHandle> dispatchRequest({
    required String sourceDescription,
    required List<String> filePaths,
    required List<String> fileNames,
    required ImportParseMode mode,
    required int maxConcurrency,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  }) {
    final parser = _parser;
    if (parser == null) {
      throw const ImportTaskCoordinatorDependencyException();
    }
    return dispatch(
      sourceDescription: sourceDescription,
      mode: mode,
      parse: (taskId) => parser(ImportParseRequest(
        filePaths: List<String>.unmodifiable(filePaths),
        fileNames: List<String>.unmodifiable(fileNames),
        mode: mode,
        maxConcurrency: maxConcurrency,
        taskId: taskId,
        explanationRetentionMode: explanationRetentionMode,
      )),
      explanationRetentionMode: explanationRetentionMode,
    );
  }

  Future<ImportTaskHandle> dispatch({
    required String sourceDescription,
    required ImportParseMode mode,
    required Future<ImportParseResult> Function(String taskId) parse,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  }) async {
    await _readiness;

    final taskId = _taskIdFactory();
    final traceId = _traceIdFactory();
    final attemptToken = _attemptTokenFactory();
    // OBS-1: an initial Import attempt inherits an enclosing operation's
    // correlation when one exists (future Agent-triggered import), otherwise
    // it opens a new root correlation.
    final correlationId =
        TraceContext.correlationId ?? TraceContext.createCorrelationId();
    final parentTraceId = TraceContext.traceId;
    final handle = ImportTaskHandle(
      taskId: taskId,
      traceId: traceId,
      attemptNumber: 1,
      attemptToken: attemptToken,
      correlationId: correlationId,
      parentTraceId: parentTraceId,
    );
    final safeSourceDescription = _safeSourceDescription(sourceDescription);
    final writeStatus = await _taskManager.addAttemptTask(ImportTask(
      id: taskId,
      title: '文档解析任务: $safeSourceDescription',
      progressText: '已进入后台队列...',
      percent: 0.1,
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: traceId,
        TaskManager.keyCorrelationId: correlationId,
        if (parentTraceId != null) TaskManager.keyParentTraceId: parentTraceId,
        TaskManager.keyParseMode: mode.name,
        TaskManager.keyExplanationRetentionMode: explanationRetentionMode.name,
        TaskManager.keyAttemptNumber: handle.attemptNumber,
        TaskManager.keyAttemptToken: handle.attemptToken,
        TaskManager.keyAttemptState: ImportAttemptState.queued.name,
      },
    ));
    if (writeStatus != ImportAttemptWriteStatus.applied) {
      await _taskManager.failAttempt(
        handle.attempt,
        '任务状态保存失败，请稍后重试',
        clearSensitivePayload: true,
        diagnostics: const <String, dynamic>{
          'failedStage': 'task_persistence',
          'errorType': 'ImportTaskPersistenceFailure',
          'status': 'failed',
        },
      );
      throw const ImportTaskAttemptPersistenceException();
    }

    unawaited(Future<void>.microtask(() => _runScheduledTask(
          _ScheduledImportTask(
            handle: handle,
            sourceDescription: safeSourceDescription,
            parse: parse,
          ),
        )));
    return handle;
  }

  Future<ImportTaskBatchHandle> dispatchIndependentBatch({
    required List<ImportTaskBatchItem> items,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'must not be empty');
    }
    await _readiness;

    final existingBatchIds = _taskManager.tasks
        .map((task) => task.batchId)
        .whereType<String>()
        .toSet();
    final batchId = _uniqueValue(_batchIdFactory(), existingBatchIds);
    final reservedTaskIds = _taskManager.tasks.map((task) => task.id).toSet();
    final reservedTraceIds = _taskManager.tasks
        .map((task) => task.traceId)
        .whereType<String>()
        .toSet();
    final reservedAttemptTokens = _taskManager.tasks
        .map((task) => task.attemptToken)
        .whereType<String>()
        .toSet();
    final scheduled = <_ScheduledImportTask>[];
    final tasks = <ImportTask>[];

    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final taskId = _uniqueValue(_taskIdFactory(), reservedTaskIds);
      reservedTaskIds.add(taskId);
      final traceId = _uniqueValue(_traceIdFactory(), reservedTraceIds);
      reservedTraceIds.add(traceId);
      final attemptToken =
          _uniqueValue(_attemptTokenFactory(), reservedAttemptTokens);
      reservedAttemptTokens.add(attemptToken);
      // OBS-1: each ImportTask in a batch ALWAYS owns a fresh correlation
      // (never merged with the product-level batchId and never inherited
      // from an enclosing operation); the enclosing trace becomes the
      // parent of every task in the batch.
      final correlationId = TraceContext.createCorrelationId();
      final parentTraceId = TraceContext.traceId;
      final handle = ImportTaskHandle(
        taskId: taskId,
        traceId: traceId,
        attemptNumber: 1,
        attemptToken: attemptToken,
        correlationId: correlationId,
        parentTraceId: parentTraceId,
      );
      final safeSourceDescription =
          _safeSourceDescription(item.sourceDescription);
      tasks.add(ImportTask(
        id: taskId,
        title: '文档解析任务: $safeSourceDescription',
        progressText: '已进入后台队列...',
        percent: 0.1,
        diagnostics: <String, dynamic>{
          TaskManager.keyTraceId: traceId,
          TaskManager.keyCorrelationId: correlationId,
          if (parentTraceId != null)
            TaskManager.keyParentTraceId: parentTraceId,
          TaskManager.keyParseMode: item.mode.name,
          TaskManager.keyExplanationRetentionMode:
              item.explanationRetentionMode.name,
          TaskManager.keyBatchId: batchId,
          TaskManager.keySelectionIndex: index,
          TaskManager.keyAttemptNumber: handle.attemptNumber,
          TaskManager.keyAttemptToken: handle.attemptToken,
          TaskManager.keyAttemptState: ImportAttemptState.queued.name,
        },
      ));
      scheduled.add(_ScheduledImportTask(
        handle: handle,
        sourceDescription: safeSourceDescription,
        parse: item.parse,
      ));
    }

    final writes = await _taskManager.addAttemptTasksInOrder(tasks);
    if (writes.any((status) => status != ImportAttemptWriteStatus.applied)) {
      for (final item in scheduled) {
        await _taskManager.failAttempt(
          item.handle.attempt,
          '任务状态保存失败，请稍后重试',
          clearSensitivePayload: true,
          diagnostics: const <String, dynamic>{
            'failedStage': 'task_persistence',
            'errorType': 'ImportTaskPersistenceFailure',
            'status': 'failed',
          },
        );
      }
      throw const ImportTaskAttemptPersistenceException();
    }
    final runConcurrently =
        items.every((item) => item.mode == ImportParseMode.ocr);
    if (runConcurrently) {
      unawaited(Future<void>.microtask(() {
        for (final item in scheduled) {
          unawaited(_runScheduledTask(item));
        }
      }));
    } else {
      unawaited(Future<void>.microtask(() async {
        for (final item in scheduled) {
          await _runScheduledTask(item);
        }
      }));
    }
    return ImportTaskBatchHandle(
      batchId: batchId,
      tasks: List<ImportTaskHandle>.unmodifiable(
        scheduled.map((item) => item.handle),
      ),
    );
  }

  Future<ImportAttemptWriteStatus> cancelOcrTask(String taskId) async {
    await _readiness;
    final matches = _taskManager.tasks.where((task) => task.id == taskId);
    if (matches.isEmpty) return ImportAttemptWriteStatus.taskMissing;
    final task = matches.first;
    if (task.parseMode != ImportParseMode.ocr.name) {
      return ImportAttemptWriteStatus.invalidState;
    }
    final attempt = task.attemptRef;
    if (attempt == null) return ImportAttemptWriteStatus.invalidState;

    final persistence = _taskManager.requestAttemptCancellation(attempt);
    _requestScheduler.cancel(
      taskId: attempt.taskId,
      attemptToken: attempt.attemptToken,
    );
    return persistence;
  }

  Future<ImportTaskHandle> retryOcrRequest({
    required String taskId,
    required List<String> filePaths,
    required List<String> fileNames,
  }) async {
    final parser = _parser;
    if (parser == null) {
      throw const ImportTaskCoordinatorDependencyException();
    }
    if (filePaths.isEmpty || filePaths.length != fileNames.length) {
      throw const ImportTaskRetryRejectedException();
    }

    final selectedPaths =
        filePaths.map((path) => path.trim()).toList(growable: false);
    final selectedNames = fileNames
        .map((name) => p.basename(name.trim()))
        .toList(growable: false);
    if (selectedPaths.any((path) => path.isEmpty) ||
        selectedNames.any((name) => name.isEmpty) ||
        selectedPaths.any((path) {
          final format = ImportFileDetector.detect(path);
          return format != ImportFormat.pdf && format != ImportFormat.image;
        })) {
      throw const ImportTaskRetryRejectedException();
    }

    await _readiness;
    final matches = _taskManager.tasks.where((task) => task.id == taskId);
    if (matches.isEmpty ||
        matches.first.parseMode != ImportParseMode.ocr.name) {
      throw const ImportTaskRetryRejectedException();
    }
    final task = matches.first;
    final immutablePaths = List<String>.unmodifiable(selectedPaths);
    final immutableNames = List<String>.unmodifiable(selectedNames);
    final sourceDescription = immutableNames.length == 1
        ? immutableNames.single
        : '${immutableNames.first} 等 ${immutableNames.length} 个文件';

    return retryOcrTask(
      taskId: taskId,
      sourceDescription: sourceDescription,
      explanationRetentionMode: task.explanationRetentionMode,
      parse: (retryTaskId) => parser(ImportParseRequest(
        filePaths: immutablePaths,
        fileNames: immutableNames,
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: retryTaskId,
        explanationRetentionMode: task.explanationRetentionMode,
      )),
    );
  }

  Future<ImportTaskHandle> retryOcrTask({
    required String taskId,
    required String sourceDescription,
    required ImportTaskParseAction parse,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  }) async {
    await _readiness;
    final matches = _taskManager.tasks.where((task) => task.id == taskId);
    if (matches.isEmpty ||
        matches.first.parseMode != ImportParseMode.ocr.name) {
      throw const ImportTaskRetryRejectedException();
    }
    final task = matches.first;
    final reservedTraceIds = _taskManager.tasks
        .where((candidate) => candidate.id != taskId)
        .map((candidate) => candidate.traceId)
        .whereType<String>()
        .toSet();
    final reservedAttemptTokens = _taskManager.tasks
        .where((candidate) => candidate.id != taskId)
        .map((candidate) => candidate.attemptToken)
        .whereType<String>()
        .toSet();
    final traceId = _uniqueValue(_traceIdFactory(), reservedTraceIds);
    final attemptToken =
        _uniqueValue(_attemptTokenFactory(), reservedAttemptTokens);
    // OBS-1 retry lineage: same taskId, same correlationId, new traceId and
    // parent trace pointing at the previous attempt's trace.
    final correlationId =
        task.correlationId ?? TraceContext.createCorrelationId();
    final parentTraceId = task.traceId;
    final handle = ImportTaskHandle(
      taskId: taskId,
      traceId: traceId,
      attemptNumber: task.attemptNumber + 1,
      attemptToken: attemptToken,
      correlationId: correlationId,
      parentTraceId: parentTraceId,
    );
    final writeStatus = await _taskManager.restartAttempt(
      handle.attempt,
      parseMode: ImportParseMode.ocr.name,
      explanationRetentionMode: explanationRetentionMode,
    );
    if (writeStatus != ImportAttemptWriteStatus.applied) {
      throw const ImportTaskRetryRejectedException();
    }

    unawaited(Future<void>.microtask(() => _runScheduledTask(
          _ScheduledImportTask(
            handle: handle,
            sourceDescription: _safeSourceDescription(sourceDescription),
            parse: parse,
          ),
        )));
    return handle;
  }

  Future<void> _runScheduledTask(_ScheduledImportTask item) {
    return ImportAttemptContext.run(
      attempt: item.handle.attempt,
      action: () => TraceContext.run(
        taskId: item.handle.taskId,
        traceId: item.handle.traceId,
        correlationId: item.handle.correlationId,
        parentTraceId: item.handle.parentTraceId,
        operationKind: TraceOperationKind.importAttempt,
        action: () => _runParse(
          handle: item.handle,
          sourceDescription: item.sourceDescription,
          parse: item.parse,
        ),
      ),
    );
  }

  static String _uniqueValue(String candidate, Set<String> reserved) {
    if (!reserved.contains(candidate)) return candidate;
    var suffix = 1;
    while (reserved.contains('${candidate}_$suffix')) {
      suffix++;
    }
    return '${candidate}_$suffix';
  }

  Future<void> _runParse({
    required ImportTaskHandle handle,
    required String sourceDescription,
    required ImportTaskParseAction parse,
  }) async {
    AppLogger.info(
      'Background import dispatched',
      module: 'Import',
      data: const <String, Object?>{'stage': 'import_dispatch'},
    );
    final stopwatch = Stopwatch()..start();
    try {
      final progressStatus = await _taskManager.updateAttemptProgress(
        handle.attempt,
        '正在调用解析引擎...',
        0.4,
      );
      if (progressStatus != ImportAttemptWriteStatus.applied) return;
      AppLogger.info(
        'Import parsing started',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'attemptNumber': handle.attemptNumber,
        },
      );
      final result = await parse(handle.taskId);
      AppLogger.info(
        'Import parsing completed',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'attemptNumber': handle.attemptNumber,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      if (!_taskManager.isCurrentAttempt(handle.attempt)) return;
      if (!_taskManager.isAttemptRunnable(handle.attempt)) {
        await _taskManager.finalizeAttemptCancelled(handle.attempt);
        return;
      }

      if (result.questions.isEmpty) {
        final emptyFailure = _classifyEmptyResult(result);
        await _failSafely(
          handle,
          emptyFailure.failure,
          warningCount: result.warnings.length,
          status: emptyFailure.ocrStatus,
          ocrErrorType: emptyFailure.ocrErrorType,
        );
        AppLogger.warning(
          'Import produced no questions',
          module: 'Import',
          data: <String, Object?>{
            'stage': 'import_parse',
            'status': emptyFailure.ocrStatus ?? 'failed',
            'errorType': emptyFailure.failure.errorType,
            if (emptyFailure.ocrErrorType != null)
              'ocrErrorType': emptyFailure.ocrErrorType,
            'warningCount': result.warnings.length,
          },
        );
        return;
      }

      final questions = _attachImportDiagnostics(result);
      final storageRoute = importStorageRouteSerialization(result.storageRoute);
      final storageReason = normalizeImportStorageReason(result.storageReason);
      final diagnostics = <String, dynamic>{
        ...result.diagnostics,
        TaskManager.keyExplanationRetentionMode:
            result.explanationRetentionMode.name,
        TaskManager.keyImportStorageRoute: storageRoute,
        if (storageReason != null)
          TaskManager.keyImportStorageReason: storageReason,
        keySourceQuestionCount: result.questions.length,
        keySourceQuestionNumbers: result.questions
            .map(
              (question) => QuestionIdentity.tryParseExplicitQuestionNumber(
                question['q_num'],
              ),
            )
            .toList(growable: false),
      };
      final reviewStatus = await _taskManager.requireAttemptReview(
        handle.attempt,
        '解析成功，请进行人工校对并入库',
        questions,
        '',
        '',
        warnings: result.warnings,
        diagnostics: diagnostics,
      );
      if (reviewStatus != ImportAttemptWriteStatus.applied) {
        if (_taskManager.isCurrentAttempt(handle.attempt)) {
          await _taskManager.finalizeAttemptCancelled(handle.attempt);
        }
        return;
      }
      AppLogger.info(
        'Import is ready for review',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'questionCount': questions.length,
        },
      );
      try {
        onReadyForReview?.call(sourceDescription);
      } catch (_) {
        AppLogger.warning(
          'Import review notification failed',
          module: 'Import',
          data: const <String, Object?>{
            'stage': 'review_notification',
            'status': 'failed',
          },
        );
      }
    } on OcrRequestCancelledException {
      await _taskManager.finalizeAttemptCancelled(handle.attempt);
      AppLogger.info(
        'Background import cancelled',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'status': 'cancelled',
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
    } catch (error) {
      if (!_taskManager.isCurrentAttempt(handle.attempt)) return;
      final currentTask = _taskManager.tasks.firstWhere(
        (task) => task.id == handle.taskId,
      );
      if (currentTask.attemptState == ImportAttemptState.cancelRequested ||
          currentTask.attemptState == ImportAttemptState.cancelled) {
        await _taskManager.finalizeAttemptCancelled(handle.attempt);
        return;
      }
      final failure = ImportFailureClassifier.classify(error);
      await _failSafely(handle, failure);
      AppLogger.error(
        'Background import failed',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'status': 'failed',
          'errorType': failure.errorType,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
    }
  }

  static String _safeSourceDescription(String sourceDescription) {
    final basename = p.basename(sourceDescription.trim());
    return basename.isEmpty || basename == '.' ? '导入文件' : basename;
  }

  static _EmptyResultFailure _classifyEmptyResult(ImportParseResult result) {
    Map<Object?, Object?>? ocrDiagnostics;
    for (final entry in result.diagnostics.entries) {
      if (entry.key.startsWith('ocr_import_file_') && entry.value is Map) {
        ocrDiagnostics = entry.value as Map<Object?, Object?>;
        break;
      }
    }

    final rawStatus = ocrDiagnostics?['status'];
    final ocrStatus =
        rawStatus is String && _safeOcrStatuses.contains(rawStatus)
            ? rawStatus
            : null;
    final rawErrorType = ocrDiagnostics?['errorType'];
    final ocrErrorType =
        rawErrorType is String && _safeOcrErrorTypes.contains(rawErrorType)
            ? rawErrorType
            : null;

    final failure = switch (ocrStatus) {
      'failed_not_configured' => _ocrNotConfiguredFailure,
      'failed_empty_ocr_blocks' => _ocrEmptyBlocksFailure,
      'failed_no_question_regions' => _ocrNoQuestionRegionsFailure,
      'failed_no_assembled_questions' => _ocrNoAssembledQuestionsFailure,
      'failed_request' => _classifyOcrRequestFailure(ocrErrorType),
      _ => ImportFailureClassifier.providerResponseFormatFailure,
    };
    return _EmptyResultFailure(
      failure: failure,
      ocrStatus: ocrStatus,
      ocrErrorType: ocrErrorType,
    );
  }

  static ImportFailureClassification _classifyOcrRequestFailure(
    String? errorType,
  ) {
    return switch (errorType) {
      'FileSystemException' ||
      'PathNotFoundException' =>
        ImportFailureClassifier.fileReadFailure,
      'ZhipuOcrResponseFormatException' ||
      'FormatException' =>
        ImportFailureClassifier.providerResponseFormatFailure,
      'ZhipuOcrAuthenticationException' ||
      'ZhipuOcrRequestException' ||
      'TimeoutException' ||
      'SocketException' ||
      'ClientException' =>
        ImportFailureClassifier.providerRequestFailure,
      _ => ImportFailureClassifier.unknownFailure,
    };
  }

  Future<ImportAttemptWriteStatus> _failSafely(
    ImportTaskHandle handle,
    ImportFailureClassification failure, {
    int? warningCount,
    String? status,
    String? ocrErrorType,
  }) {
    return _taskManager.failAttempt(
      handle.attempt,
      failure.userMessage,
      warnings: const <String>[],
      clearSensitivePayload: true,
      diagnostics: <String, dynamic>{
        'traceId': handle.traceId,
        if (handle.correlationId != null)
          TaskManager.keyCorrelationId: handle.correlationId,
        'failedStage': 'import_parse',
        'errorType': failure.errorType,
        'status': status ?? 'failed',
        if (ocrErrorType != null) 'ocrErrorType': ocrErrorType,
        if (warningCount != null) 'warningCount': warningCount,
      },
    );
  }

  List<Map<String, dynamic>> _attachImportDiagnostics(
    ImportParseResult result,
  ) {
    if (result.warnings.isEmpty && result.diagnostics.isEmpty) {
      return result.questions;
    }

    final questions = result.questions
        .map((question) => Map<String, dynamic>.from(question))
        .toList(growable: false);
    questions.first['_import_diagnostics'] = <String>[
      ...result.warnings,
      ..._formatDiagnostics(result.diagnostics),
    ];
    return questions;
  }

  List<String> _formatDiagnostics(Map<String, dynamic> diagnostics) {
    final values = <String>[];

    void flatten(Map<Object?, Object?> map, String prefix) {
      for (final entry in map.entries) {
        final value = entry.value;
        final key = entry.key.toString();
        final nextPrefix = prefix.isEmpty ? '$key ' : '$prefix$key ';
        if (value is Map) {
          flatten(value, nextPrefix);
        } else if (value is List) {
          for (final item in value) {
            values.add('${prefix.isEmpty ? '' : '[$prefix] '}$item');
          }
        } else {
          values.add('${prefix.isEmpty ? '' : '[$prefix] '}$key: $value');
        }
      }
    }

    flatten(diagnostics, '');
    return values;
  }
}

class _ScheduledImportTask {
  const _ScheduledImportTask({
    required this.handle,
    required this.sourceDescription,
    required this.parse,
  });

  final ImportTaskHandle handle;
  final String sourceDescription;
  final ImportTaskParseAction parse;
}

class _EmptyResultFailure {
  const _EmptyResultFailure({
    required this.failure,
    required this.ocrStatus,
    required this.ocrErrorType,
  });

  final ImportFailureClassification failure;
  final String? ocrStatus;
  final String? ocrErrorType;
}
