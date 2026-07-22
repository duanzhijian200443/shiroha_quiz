import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../task_manager.dart';
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
    _taskManager.addTask(ImportTask(
      id: taskId,
      title: '文档解析任务: $sourceDescription',
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
            sourceDescription: sourceDescription,
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
      data: <String, Object?>{'source': sourceDescription},
    );
    try {
      _taskManager.updateProgress(
        handle.taskId,
        '正在调用解析引擎...',
        0.4,
      );
      final result = await AppLogger.span(
        'Import parsing',
        () => parse(handle.taskId),
        module: 'Import',
        data: <String, Object?>{'source': sourceDescription},
      );

      if (result.questions.isEmpty) {
        _taskManager.attachDiagnostics(
          handle.taskId,
          warnings: result.warnings,
          diagnostics: Map<String, dynamic>.from(result.diagnostics),
        );
        _taskManager.failTask(handle.taskId, _emptyResultMessage(result));
        AppLogger.warning(
          'Import produced no questions',
          module: 'Import',
          data: <String, Object?>{'source': sourceDescription},
        );
        return;
      }

      final questions = _attachImportDiagnostics(result);
      _taskManager.requireReview(
        handle.taskId,
        '解析成功，请进行人工校对并入库',
        questions,
        '',
        '',
        warnings: result.warnings,
        diagnostics: Map<String, dynamic>.from(result.diagnostics),
      );
      AppLogger.info(
        'Import is ready for review',
        module: 'Import',
        data: <String, Object?>{
          'source': sourceDescription,
          'questionCount': questions.length,
        },
      );
      onReadyForReview?.call(sourceDescription);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Background import failed',
        module: 'Import',
        error: error,
        stackTrace: stackTrace,
        data: <String, Object?>{'source': sourceDescription},
      );
      _taskManager.failTask(handle.taskId, error.toString());
    }
  }

  String _emptyResultMessage(ImportParseResult result) {
    var message = '解析完毕，但未提取到任何题目';
    if (result.warnings.isNotEmpty) {
      message += '\n${result.warnings.join('\n')}';
    }
    return message;
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
