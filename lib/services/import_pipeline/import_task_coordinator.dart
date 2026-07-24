import 'package:path/path.dart' as p;

import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../../data/models/question_identity.dart';
import '../task_manager.dart';
import 'import_failure_classifier.dart';
import 'import_parse_request.dart';
import 'import_parse_result.dart';
import 'import_pipeline_service.dart';

typedef ImportRequestParser = Future<ImportParseResult> Function(
  ImportParseRequest request,
);

class ImportTaskHandle {
  const ImportTaskHandle({required this.taskId, required this.traceId});

  final String taskId;
  final String traceId;
}

class ImportTaskCoordinator {
  ImportTaskCoordinator({
    TaskManager? taskManager,
    Future<void>? readiness,
    ImportRequestParser? parser,
    String Function()? taskIdFactory,
    String Function()? traceIdFactory,
    this.onReadyForReview,
  })  : _taskManager = taskManager ?? TaskManager.instance,
        _readiness = readiness ?? (taskManager ?? TaskManager.instance).ready,
        _parser = parser ?? ImportPipelineService.instance.parseFiles,
        _taskIdFactory = taskIdFactory ?? _createTaskId,
        _traceIdFactory = traceIdFactory ?? TraceContext.createTraceId;

  static final ImportTaskCoordinator instance = ImportTaskCoordinator();
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
  final ImportRequestParser _parser;
  final String Function() _taskIdFactory;
  final String Function() _traceIdFactory;
  final void Function(String sourceDescription)? onReadyForReview;

  static String _createTaskId() =>
      'task_${DateTime.now().millisecondsSinceEpoch}';

  Future<ImportTaskHandle> dispatchRequest({
    required String sourceDescription,
    required List<String> filePaths,
    required List<String> fileNames,
    required ImportParseMode mode,
    required int maxConcurrency,
  }) {
    return dispatch(
      sourceDescription: sourceDescription,
      mode: mode,
      parse: (taskId) => _parser(ImportParseRequest(
        filePaths: List<String>.unmodifiable(filePaths),
        fileNames: List<String>.unmodifiable(fileNames),
        mode: mode,
        maxConcurrency: maxConcurrency,
        taskId: taskId,
      )),
    );
  }

  Future<ImportTaskHandle> dispatch({
    required String sourceDescription,
    required ImportParseMode mode,
    required Future<ImportParseResult> Function(String taskId) parse,
  }) async {
    await _readiness;

    final taskId = _taskIdFactory();
    final traceId = _traceIdFactory();
    final handle = ImportTaskHandle(taskId: taskId, traceId: traceId);
    final safeSourceDescription = _safeSourceDescription(sourceDescription);
    _taskManager.addTask(ImportTask(
      id: taskId,
      title: '文档解析任务: $safeSourceDescription',
      progressText: '已进入后台队列...',
      percent: 0.1,
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: traceId,
        TaskManager.keyParseMode: mode.name,
      },
    ));

    Future<void>.microtask(() => TraceContext.run(
          taskId: taskId,
          traceId: traceId,
          action: () => _runParse(
            handle: handle,
            sourceDescription: safeSourceDescription,
            parse: parse,
          ),
        ));
    return handle;
  }

  Future<void> _runParse({
    required ImportTaskHandle handle,
    required String sourceDescription,
    required Future<ImportParseResult> Function(String taskId) parse,
  }) async {
    AppLogger.info(
      'Background import dispatched',
      module: 'Import',
      data: const <String, Object?>{'stage': 'import_dispatch'},
    );
    final stopwatch = Stopwatch()..start();
    try {
      _taskManager.updateProgress(
        handle.taskId,
        '正在调用解析引擎...',
        0.4,
      );
      AppLogger.info(
        'Import parsing started',
        module: 'Import',
        data: const <String, Object?>{'stage': 'import_parse'},
      );
      final result = await parse(handle.taskId);
      AppLogger.info(
        'Import parsing completed',
        module: 'Import',
        data: <String, Object?>{
          'stage': 'import_parse',
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );

      if (result.questions.isEmpty) {
        final emptyFailure = _classifyEmptyResult(result);
        _failSafely(
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
      final diagnostics = Map<String, dynamic>.from(result.diagnostics)
        ..[keySourceQuestionCount] = result.questions.length
        ..[keySourceQuestionNumbers] = result.questions
            .map(
              (question) => QuestionIdentity.tryParseExplicitQuestionNumber(
                question['q_num'],
              ),
            )
            .toList(growable: false);
      _taskManager.requireReview(
        handle.taskId,
        '解析成功，请进行人工校对并入库',
        questions,
        '',
        '',
        warnings: result.warnings,
        diagnostics: diagnostics,
      );
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
    } catch (error) {
      final failure = ImportFailureClassifier.classify(error);
      _failSafely(handle, failure);
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

  void _failSafely(
    ImportTaskHandle handle,
    ImportFailureClassification failure, {
    int? warningCount,
    String? status,
    String? ocrErrorType,
  }) {
    _taskManager.failTask(
      handle.taskId,
      failure.userMessage,
      warnings: const <String>[],
      clearSensitivePayload: true,
      diagnostics: <String, dynamic>{
        'traceId': handle.traceId,
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
