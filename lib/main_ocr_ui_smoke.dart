import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

final class _OcrUiSmokeCredentialStore implements EngineCredentialStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    return _values[engineId];
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    _values[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    _values.remove(engineId);
  }
}

const _apiKeyEnvironmentName = 'SHIROHA_OCR_API_KEY';
const _runtimeDirectoryEnvironmentName = 'SHIROHA_UI_SMOKE_RUNTIME_DIR';
const _smokeBankName = 'OCR UI Smoke';
const _smokeFolderName = 'Isolated Smoke';

class OcrUiSmokeArgumentException implements Exception {
  const OcrUiSmokeArgumentException();
}

class OcrUiSmokeConfig {
  const OcrUiSmokeConfig({
    required this.relativePdfPath,
    required this.resolvedPdfPath,
    required this.fileName,
    required this.commit,
    required this.expectedQuestionCount,
    required this.expectedNumbers,
    required this.closeOnSuccess,
  });

  final String relativePdfPath;
  final String resolvedPdfPath;
  final String fileName;
  final bool commit;
  final int? expectedQuestionCount;
  final List<int> expectedNumbers;
  final bool closeOnSuccess;

  OcrUiSmokeConfig withResolvedPdfPath(String path) {
    return OcrUiSmokeConfig(
      relativePdfPath: relativePdfPath,
      resolvedPdfPath: path,
      fileName: fileName,
      commit: commit,
      expectedQuestionCount: expectedQuestionCount,
      expectedNumbers: expectedNumbers,
      closeOnSuccess: closeOnSuccess,
    );
  }

  factory OcrUiSmokeConfig.parse(
    List<String> args, {
    required String repositoryRoot,
  }) {
    String? pdfArgument;
    var commit = false;
    var closeOnSuccess = false;
    int? expectedQuestionCount;
    var expectedNumbers = const <int>[];

    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (argument.startsWith('--pdf=')) {
        if (pdfArgument != null) throw const OcrUiSmokeArgumentException();
        pdfArgument = argument.substring('--pdf='.length);
      } else if (argument == '--pdf') {
        if (pdfArgument != null || index + 1 >= args.length) {
          throw const OcrUiSmokeArgumentException();
        }
        pdfArgument = args[++index];
      } else if (argument == '--commit') {
        commit = true;
      } else if (argument == '--close-on-success') {
        closeOnSuccess = true;
      } else if (argument.startsWith('--expected-question-count=')) {
        final value = int.tryParse(
          argument.substring('--expected-question-count='.length),
        );
        if (value == null || value <= 0 || expectedQuestionCount != null) {
          throw const OcrUiSmokeArgumentException();
        }
        expectedQuestionCount = value;
      } else if (argument.startsWith('--expected-numbers=')) {
        if (expectedNumbers.isNotEmpty) {
          throw const OcrUiSmokeArgumentException();
        }
        expectedNumbers = _parseExpectedNumbers(
          argument.substring('--expected-numbers='.length),
        );
      } else {
        throw const OcrUiSmokeArgumentException();
      }
    }

    final rawPdf = pdfArgument?.trim();
    if (rawPdf == null ||
        rawPdf.isEmpty ||
        p.isAbsolute(rawPdf) ||
        rawPdf.contains('"') ||
        p.split(rawPdf).contains('..') ||
        p.extension(rawPdf).toLowerCase() != '.pdf') {
      throw const OcrUiSmokeArgumentException();
    }

    final normalizedRelative = p.normalize(rawPdf);
    final pdfRoot = p.normalize(
      p.join(repositoryRoot, 'scratch', 'test_pdfs'),
    );
    final resolvedPdf = p.normalize(p.join(pdfRoot, normalizedRelative));
    if (!p.isWithin(pdfRoot, resolvedPdf)) {
      throw const OcrUiSmokeArgumentException();
    }

    return OcrUiSmokeConfig(
      relativePdfPath: normalizedRelative.replaceAll('\\', '/'),
      resolvedPdfPath: resolvedPdf,
      fileName: p.basename(resolvedPdf),
      commit: commit,
      expectedQuestionCount: expectedQuestionCount,
      expectedNumbers: List<int>.unmodifiable(expectedNumbers),
      closeOnSuccess: closeOnSuccess,
    );
  }

  static List<int> _parseExpectedNumbers(String raw) {
    if (raw.trim().isEmpty) throw const OcrUiSmokeArgumentException();
    final values = <int>[];
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      final rangeMatch = RegExp(r'^(\d+)-(\d+)$').firstMatch(trimmed);
      if (rangeMatch != null) {
        final start = int.parse(rangeMatch.group(1)!);
        final end = int.parse(rangeMatch.group(2)!);
        if (start <= 0 || end < start) {
          throw const OcrUiSmokeArgumentException();
        }
        values.addAll(List<int>.generate(end - start + 1, (i) => start + i));
        continue;
      }
      final value = int.tryParse(trimmed);
      if (value == null || value <= 0) {
        throw const OcrUiSmokeArgumentException();
      }
      values.add(value);
    }
    if (values.toSet().length != values.length) {
      throw const OcrUiSmokeArgumentException();
    }
    return values;
  }
}

bool isOcrUiSmokeApiKeyPresent(Map<String, String> environment) {
  return environment[_apiKeyEnvironmentName]?.trim().isNotEmpty == true;
}

class OcrUiSmokeEngineConfigurationException implements Exception {
  const OcrUiSmokeEngineConfigurationException();

  @override
  String toString() => 'OcrUiSmokeEngineConfigurationException';
}

Future<AiEngineProfile> configureOcrUiSmokeEngine({
  required AiEngineRepository repository,
  required AiEngineProfile profile,
}) async {
  await repository.saveEngine(profile);
  await repository.setActiveEngine(profile.id, AiEngineType.ocr);
  final activeProfile = await repository.getActiveOcrEngine();
  if (activeProfile == null || activeProfile.id != profile.id) {
    throw const OcrUiSmokeEngineConfigurationException();
  }
  return activeProfile;
}

class OcrUiSmokeEvent {
  const OcrUiSmokeEvent({
    required this.stage,
    required this.status,
    this.apiKeyPresent,
    this.fileName,
    this.traceId,
    this.taskId,
    this.screen,
    this.questionCount,
    this.importMode,
    this.databaseProfile,
    this.durationMs,
    this.rawQuestionNumberCount,
    this.finalQuestionCount,
    this.duplicateQuestionNumberCount,
    this.missingQuestionNumberCount,
    this.unexpectedQuestionNumberCount,
    this.qualityGateBlocked,
    this.warningCount,
    this.causeType,
  });

  final String stage;
  final String status;
  final bool? apiKeyPresent;
  final String? fileName;
  final String? traceId;
  final String? taskId;
  final String? screen;
  final int? questionCount;
  final String? importMode;
  final String? databaseProfile;
  final int? durationMs;
  final int? rawQuestionNumberCount;
  final int? finalQuestionCount;
  final int? duplicateQuestionNumberCount;
  final int? missingQuestionNumberCount;
  final int? unexpectedQuestionNumberCount;
  final bool? qualityGateBlocked;
  final int? warningCount;
  final String? causeType;

  Map<String, Object?> toSafeJson() => <String, Object?>{
        'stage': _safeToken(stage) ?? 'failed',
        'status': _safeToken(status) ?? 'unknown_failure',
        if (apiKeyPresent != null) 'apiKeyPresent': apiKeyPresent,
        if (fileName != null) 'fileName': p.basename(fileName!),
        if (_safeToken(traceId) case final value?) 'traceId': value,
        if (_safeToken(taskId) case final value?) 'taskId': value,
        if (_safeToken(screen) case final value?) 'screen': value,
        if (questionCount != null) 'questionCount': questionCount,
        if (_safeToken(importMode) case final value?) 'importMode': value,
        if (_safeToken(databaseProfile) case final value?)
          'databaseProfile': value,
        if (durationMs != null) 'durationMs': durationMs,
        if (rawQuestionNumberCount != null)
          'rawQuestionNumberCount': rawQuestionNumberCount,
        if (finalQuestionCount != null)
          'finalQuestionCount': finalQuestionCount,
        if (duplicateQuestionNumberCount != null)
          'duplicateQuestionNumberCount': duplicateQuestionNumberCount,
        if (missingQuestionNumberCount != null)
          'missingQuestionNumberCount': missingQuestionNumberCount,
        if (unexpectedQuestionNumberCount != null)
          'unexpectedQuestionNumberCount': unexpectedQuestionNumberCount,
        if (qualityGateBlocked != null)
          'qualityGateBlocked': qualityGateBlocked,
        if (warningCount != null) 'warningCount': warningCount,
        if (causeType != null)
          'causeType': RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(causeType!)
              ? causeType
              : 'UnknownFailure',
      };

  static String? _safeToken(String? value) {
    if (value == null ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value) ||
        value.length > 128) {
      return null;
    }
    return value;
  }
}

class OcrUiSmokeEventWriter {
  const OcrUiSmokeEventWriter(this._writeLine);

  final void Function(String line) _writeLine;

  void emit(OcrUiSmokeEvent event) {
    _writeLine(jsonEncode(event.toSafeJson()));
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  const writer = OcrUiSmokeEventWriter(_writeSmokeLine);
  late OcrUiSmokeConfig config;
  try {
    config = OcrUiSmokeConfig.parse(
      args,
      repositoryRoot: Directory.current.path,
    );
  } on OcrUiSmokeArgumentException {
    writer.emit(const OcrUiSmokeEvent(
      stage: 'failed',
      status: 'invalid_arguments',
      causeType: 'OcrUiSmokeArgumentException',
    ));
    exitCode = 2;
    return;
  }

  final environment = Platform.environment;
  final apiKeyPresent = isOcrUiSmokeApiKeyPresent(environment);
  writer.emit(OcrUiSmokeEvent(
    stage: 'preflight',
    status: apiKeyPresent ? 'success' : 'missing_api_key',
    apiKeyPresent: apiKeyPresent,
    fileName: config.fileName,
  ));
  if (!apiKeyPresent) {
    exitCode = 2;
    return;
  }
  if (!File(config.resolvedPdfPath).existsSync()) {
    writer.emit(OcrUiSmokeEvent(
      stage: 'failed',
      status: 'pdf_not_found',
      fileName: config.fileName,
      causeType: 'FileSystemException',
    ));
    exitCode = 2;
    return;
  }

  try {
    final privatePdfRoot = Directory(
      p.join(Directory.current.path, 'scratch', 'test_pdfs'),
    ).resolveSymbolicLinksSync();
    final resolvedPdf = File(config.resolvedPdfPath).resolveSymbolicLinksSync();
    if (!p.isWithin(privatePdfRoot, resolvedPdf)) {
      writer.emit(OcrUiSmokeEvent(
        stage: 'failed',
        status: 'pdf_outside_private_root',
        fileName: config.fileName,
        causeType: 'FileSystemException',
      ));
      exitCode = 2;
      return;
    }
    config = config.withResolvedPdfPath(resolvedPdf);
  } on FileSystemException {
    writer.emit(OcrUiSmokeEvent(
      stage: 'failed',
      status: 'pdf_resolution_failed',
      fileName: config.fileName,
      causeType: 'FileSystemException',
    ));
    exitCode = 2;
    return;
  }

  final runtimePath = environment[_runtimeDirectoryEnvironmentName];
  if (runtimePath == null || runtimePath.trim().isEmpty) {
    writer.emit(const OcrUiSmokeEvent(
      stage: 'failed',
      status: 'missing_runtime_directory',
      causeType: 'StateError',
    ));
    exitCode = 2;
    return;
  }

  try {
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );
    await AppLogger.initialize(directory: Directory(runtimePath));

    final databaseHelper = DatabaseHelper.instance;
    final engineRepository = AiEngineRepository(
      store: databaseHelper,
      credentialStore: _OcrUiSmokeCredentialStore(),
    );
    final apiKey = environment[_apiKeyEnvironmentName]!.trim();
    final profile = AiEngineProfile(
      id: 'ocr-ui-smoke',
      engineType: AiEngineType.ocr,
      name: 'OCR UI Smoke',
      apiKey: apiKey,
      baseUrl: environment['SHIROHA_OCR_BASE_URL'] ??
          'https://open.bigmodel.cn/api/paas',
      modelName: 'glm-4v',
      temperature: 0,
      reasoningEffort: '',
      isActive: true,
    );
    await configureOcrUiSmokeEngine(
      repository: engineRepository,
      profile: profile,
    );

    final taskManager = TaskManager.instance;
    await taskManager.ready;
    final aiService = AiService(
      engineRepository: engineRepository,
      taskManager: taskManager,
    );
    final importPipelineService = ImportPipelineService(
      aiService: aiService,
      engineRepository: engineRepository,
      taskManager: taskManager,
    );
    final questionRepository = QuestionRepository.instance;
    final commitService = ImportCommitService(
      questionRepository: questionRepository,
      taskManager: taskManager,
    );

    runApp(OcrUiSmokeApp(
      config: config,
      taskCoordinator: ImportTaskCoordinator(
        taskManager: taskManager,
        parser: importPipelineService.parseFiles,
      ),
      commitService: commitService,
      taskManager: taskManager,
      eventWriter: writer,
      questionRepository: questionRepository,
    ));
  } catch (error) {
    writer.emit(OcrUiSmokeEvent(
      stage: 'failed',
      status: 'startup_failed',
      fileName: config.fileName,
      causeType: error.runtimeType.toString(),
    ));
    exitCode = 1;
  }
}

void _writeSmokeLine(String line) => stdout.writeln(line);

class OcrUiSmokeApp extends StatefulWidget {
  const OcrUiSmokeApp({
    super.key,
    required this.config,
    required this.taskCoordinator,
    required this.commitService,
    required this.taskManager,
    required this.eventWriter,
    required this.questionRepository,
  });

  final OcrUiSmokeConfig config;
  final ImportTaskCoordinator taskCoordinator;
  final ImportCommitService commitService;
  final TaskManager taskManager;
  final OcrUiSmokeEventWriter eventWriter;
  final QuestionRepository questionRepository;

  @override
  State<OcrUiSmokeApp> createState() => _OcrUiSmokeAppState();
}

class _OcrUiSmokeAppState extends State<OcrUiSmokeApp> {
  final Stopwatch _stopwatch = Stopwatch();
  Widget _screen = const _SmokeProgressScreen();
  String? _taskId;
  bool _handledTerminalState = false;

  @override
  void initState() {
    super.initState();
    widget.taskManager.addListener(_onTaskChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startImport());
  }

  @override
  void dispose() {
    widget.taskManager.removeListener(_onTaskChanged);
    super.dispose();
  }

  Future<void> _startImport() async {
    _stopwatch.start();
    try {
      final handle = await widget.taskCoordinator.dispatchRequest(
        sourceDescription: widget.config.fileName,
        filePaths: <String>[widget.config.resolvedPdfPath],
        fileNames: <String>[widget.config.fileName],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      _taskId = handle.taskId;
      widget.eventWriter.emit(OcrUiSmokeEvent(
        stage: 'import_started',
        status: 'processing',
        fileName: widget.config.fileName,
        traceId: handle.traceId,
        taskId: handle.taskId,
        importMode: ImportParseMode.ocr.name,
        databaseProfile: 'isolated_smoke',
      ));
      _onTaskChanged();
    } catch (error) {
      _showFailure('dispatch_failed', error.runtimeType.toString());
    }
  }

  void _onTaskChanged() {
    final taskId = _taskId;
    if (taskId == null || _handledTerminalState) return;
    final matches = widget.taskManager.tasks.where((task) => task.id == taskId);
    if (matches.isEmpty) return;
    final task = matches.first;
    if (task.status == TaskStatus.pendingReview) {
      _handledTerminalState = true;
      unawaited(_openReview(task));
    } else if (task.status == TaskStatus.error) {
      _handledTerminalState = true;
      _showFailure('import_failed', 'ImportTaskFailure', task: task);
    }
  }

  Future<void> _openReview(ImportTask task) async {
    final questions = task.parsedData ?? const <Map<String, dynamic>>[];
    final staging = ImportStagingScreen(
      parsedQuestions: questions,
      taskId: task.id,
      warnings: task.warnings,
      diagnostics: task.diagnostics,
      initialExplanationRetentionMode: task.explanationRetentionMode,
      questionRepository: widget.questionRepository,
      commitService: widget.commitService,
    );
    if (!mounted) return;

    FlutterErrorDetails? firstFrameError;
    try {
      firstFrameError = await _showScreenAndWaitForFirstFrame(staging);
    } catch (error) {
      if (!mounted) return;
      _showFailure(
        'review_screen_switch_failed',
        error.runtimeType.toString(),
        task: task,
      );
      return;
    }
    if (!mounted) return;
    if (firstFrameError != null) {
      _showFailure(
        'review_screen_build_failed',
        firstFrameError.exception.runtimeType.toString(),
        task: task,
      );
      return;
    }

    final metrics = _questionNumberMetrics(task, questions);
    final qualityGateBlocked = _isQualityGateBlocked(task);
    final expectationFailure = _expectationFailure(
      questions.length,
      metrics,
    );
    if (expectationFailure != null) {
      _emitBlocked(
        task,
        expectationFailure,
        questions.length,
        metrics,
        qualityGateBlocked: qualityGateBlocked,
      );
      return;
    }

    if (qualityGateBlocked) {
      _emitBlocked(
        task,
        'quality_gate_blocked',
        questions.length,
        metrics,
        qualityGateBlocked: true,
      );
      return;
    }

    if (!widget.config.commit) {
      _emitUiReady(
        task: task,
        screen: 'import_review',
        questionCount: questions.length,
        metrics: metrics,
      );
      return;
    }

    try {
      await widget.commitService.commit(
        bankName: _smokeBankName,
        folderName: _smokeFolderName,
        questions: QuestionDraft.listFromMaps(questions),
        taskId: task.id,
        diagnostics: task.diagnostics ?? const <String, dynamic>{},
      );
    } on ImportCommitBlockedException {
      _emitBlocked(
        task,
        'quality_gate_blocked',
        questions.length,
        metrics,
        qualityGateBlocked: true,
      );
      return;
    } catch (error) {
      _showFailure(
        'commit_failed',
        error.runtimeType.toString(),
        task: task,
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _screen = QuestionListScreen(
        bankName: _smokeBankName,
        questionRepository: widget.questionRepository,
        onLoadFinished: (count) {
          if (count == null) {
            _showFailure('question_list_load_failed', 'RepositoryReadFailure');
            return;
          }
          _emitUiReady(
            task: task,
            screen: 'question_list',
            questionCount: count,
            metrics: metrics,
          );
        },
      );
    });
  }

  Future<FlutterErrorDetails?> _showScreenAndWaitForFirstFrame(
    Widget screen,
  ) async {
    if (!mounted) return null;

    FlutterErrorDetails? firstFrameError;
    final previousHandler = FlutterError.onError;
    late final void Function(FlutterErrorDetails details) frameHandler;
    frameHandler = (details) {
      firstFrameError ??= details;
      previousHandler?.call(details);
    };
    FlutterError.onError = frameHandler;
    try {
      setState(() => _screen = screen);
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      if (identical(FlutterError.onError, frameHandler)) {
        FlutterError.onError = previousHandler;
      }
    }
    return firstFrameError;
  }

  String? _expectationFailure(
    int finalQuestionCount,
    _QuestionNumberMetrics metrics,
  ) {
    if (metrics.duplicateCount != 0) {
      return 'duplicate_question_numbers';
    }
    final expectedNumbers = widget.config.expectedNumbers;
    if (expectedNumbers.isNotEmpty) {
      final sameOrder = metrics.numbers.length == expectedNumbers.length &&
          Iterable<int>.generate(expectedNumbers.length).every(
            (index) => metrics.numbers[index] == expectedNumbers[index],
          );
      if (finalQuestionCount != expectedNumbers.length ||
          metrics.numbers.length != expectedNumbers.length ||
          !sameOrder) {
        return 'unexpected_question_numbers';
      }
    }
    final expectedCount = widget.config.expectedQuestionCount;
    if (expectedCount != null && finalQuestionCount != expectedCount) {
      return 'expected_question_count_mismatch';
    }
    return null;
  }

  void _emitBlocked(
    ImportTask task,
    String status,
    int questionCount,
    _QuestionNumberMetrics metrics, {
    required bool qualityGateBlocked,
  }) {
    _stopwatch.stop();
    widget.eventWriter.emit(OcrUiSmokeEvent(
      stage: 'validation',
      status: status,
      fileName: widget.config.fileName,
      traceId: task.traceId,
      taskId: task.id,
      screen: 'import_review',
      questionCount: questionCount,
      importMode: ImportParseMode.ocr.name,
      databaseProfile: 'isolated_smoke',
      durationMs: _stopwatch.elapsedMilliseconds,
      rawQuestionNumberCount: metrics.rawNumberCount,
      finalQuestionCount: questionCount,
      duplicateQuestionNumberCount: metrics.duplicateCount,
      missingQuestionNumberCount: metrics.missingCount,
      unexpectedQuestionNumberCount: metrics.unexpectedCount,
      qualityGateBlocked: qualityGateBlocked,
      warningCount: task.warnings?.length ?? 0,
    ));
  }

  void _emitUiReady({
    required ImportTask task,
    required String screen,
    required int questionCount,
    required _QuestionNumberMetrics metrics,
  }) {
    if (_stopwatch.isRunning) _stopwatch.stop();
    widget.eventWriter.emit(OcrUiSmokeEvent(
      stage: 'ui_ready',
      status: 'success',
      fileName: widget.config.fileName,
      traceId: task.traceId,
      taskId: task.id,
      screen: screen,
      questionCount: questionCount,
      importMode: ImportParseMode.ocr.name,
      databaseProfile: 'isolated_smoke',
      durationMs: _stopwatch.elapsedMilliseconds,
      rawQuestionNumberCount: metrics.rawNumberCount,
      finalQuestionCount: questionCount,
      duplicateQuestionNumberCount: metrics.duplicateCount,
      missingQuestionNumberCount: metrics.missingCount,
      unexpectedQuestionNumberCount: metrics.unexpectedCount,
      qualityGateBlocked: false,
      warningCount: task.warnings?.length ?? 0,
    ));
    if (widget.config.closeOnSuccess) {
      unawaited(stdout.flush().then((_) => exit(0)));
    }
  }

  void _showFailure(
    String status,
    String causeType, {
    ImportTask? task,
  }) {
    if (_stopwatch.isRunning) _stopwatch.stop();
    widget.eventWriter.emit(OcrUiSmokeEvent(
      stage: 'failed',
      status: status,
      fileName: widget.config.fileName,
      traceId: task?.traceId,
      taskId: task?.id ?? _taskId,
      importMode: ImportParseMode.ocr.name,
      databaseProfile: 'isolated_smoke',
      durationMs: _stopwatch.elapsedMilliseconds,
      causeType: causeType,
    ));
    if (mounted) {
      setState(() => _screen = const _SmokeFailureScreen());
    }
  }

  bool _isQualityGateBlocked(ImportTask task) {
    final qualityGate = task.diagnostics?['qualityGate'];
    return qualityGate is Map && qualityGate['blocked'] == true;
  }

  _QuestionNumberMetrics _questionNumberMetrics(
    ImportTask task,
    List<Map<String, dynamic>> questions,
  ) {
    final sourceNumbers =
        task.diagnostics?[ImportTaskCoordinator.keySourceQuestionNumbers];
    final rawNumbers = sourceNumbers is List
        ? sourceNumbers
        : questions.map((question) => question['q_num']).toList();
    final numbers = rawNumbers
        .map(QuestionIdentity.tryParseExplicitQuestionNumber)
        .whereType<int>()
        .toList(growable: false);
    final unique = numbers.toSet();
    final expected = widget.config.expectedNumbers.toSet();
    return _QuestionNumberMetrics(
      numbers: numbers,
      rawNumberCount: numbers.length,
      duplicateCount: numbers.length - unique.length,
      missingCount:
          expected.isEmpty ? null : expected.difference(unique).length,
      unexpectedCount:
          expected.isEmpty ? null : unique.difference(expected).length,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shiroha Quiz OCR UI Smoke',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: _screen,
    );
  }
}

class _QuestionNumberMetrics {
  const _QuestionNumberMetrics({
    required this.numbers,
    required this.rawNumberCount,
    required this.duplicateCount,
    required this.missingCount,
    required this.unexpectedCount,
  });

  final List<int> numbers;
  final int rawNumberCount;
  final int duplicateCount;
  final int? missingCount;
  final int? unexpectedCount;
}

class _SmokeProgressScreen extends StatelessWidget {
  const _SmokeProgressScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在执行隔离 OCR 导入…'),
          ],
        ),
      ),
    );
  }
}

class _SmokeFailureScreen extends StatelessWidget {
  const _SmokeFailureScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('OCR UI 冒烟失败，请根据结构化状态诊断。')),
    );
  }
}
