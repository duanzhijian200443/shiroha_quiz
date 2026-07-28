// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:crypto/crypto.dart';

import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/multi_file_question_merge_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

import 'import_acceptance.dart';
import 'ocr_smoke_report.dart';

typedef OcrSmokeSavedApiKeyLoader = Future<String?> Function();

class OcrSmokePreflightException implements Exception {
  const OcrSmokePreflightException(this.status, {this.causeType});

  final String status;
  final String? causeType;
}

class OcrSmokeFailure {
  const OcrSmokeFailure(this.stage, this.status);

  final String stage;
  final String status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OcrSmokeFailure &&
          runtimeType == other.runtimeType &&
          stage == other.stage &&
          status == other.status;

  @override
  int get hashCode => stage.hashCode ^ status.hashCode;
}

String resolveOcrSmokePdfPath(
  String rawPath, {
  required String repositoryRoot,
}) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw const OcrSmokePreflightException(
      'invalid_pdf_argument',
      causeType: 'InvalidPdfArgument',
    );
  }

  final rootDir = Directory(repositoryRoot).absolute;
  final allowedRoot = p.join(rootDir.path, 'scratch', 'test_pdfs');

  final String resolved;
  if (p.isAbsolute(trimmed)) {
    resolved = p.normalize(trimmed);
  } else if (trimmed.startsWith('scratch') ||
      trimmed.startsWith(r'scratch\') ||
      trimmed.startsWith('scratch/')) {
    resolved = p.normalize(p.join(rootDir.path, trimmed));
  } else {
    resolved = p.normalize(p.join(allowedRoot, trimmed));
  }

  if (!p.extension(resolved).toLowerCase().endsWith('.pdf')) {
    throw const OcrSmokePreflightException(
      'invalid_pdf_extension',
      causeType: 'InvalidPdfExtension',
    );
  }

  final relative = p.relative(resolved, from: allowedRoot);
  if (relative.startsWith('..') || p.isAbsolute(relative)) {
    throw const OcrSmokePreflightException(
      'path_outside_repository_root',
      causeType: 'PathOutsideRepositoryRoot',
    );
  }

  final file = File(resolved);
  if (!file.existsSync()) {
    throw const OcrSmokePreflightException(
      'pdf_not_found',
      causeType: 'PdfNotFound',
    );
  }
  return file.path;
}

OcrSmokeFailure? classifyOcrSmokeResultFailure(
  OcrImportResult result,
) {
  final diagnostics = result.diagnostics;
  final status = diagnostics['status'] as String?;
  final errorType = diagnostics['errorType'] as String?;
  final document = diagnostics['document'] as Map?;
  final regionizer = diagnostics['regionizer'] as Map?;

  if (errorType == 'FileSystemException') {
    return const OcrSmokeFailure('preflight', 'file_read_error');
  }

  if (errorType == 'ZhipuOcrInvalidPdfException') {
    return const OcrSmokeFailure('preflight', 'invalid_pdf');
  }

  if (errorType == 'ZhipuOcrAuthenticationException' ||
      status == 'auth_error') {
    return const OcrSmokeFailure('provider', 'authentication_error');
  }

  if (errorType == 'ZhipuOcrResponseFormatException') {
    return const OcrSmokeFailure('provider', 'response_format_error');
  }

  if (status == 'failed_no_question_regions') {
    return const OcrSmokeFailure('regionizer', 'no_question_regions');
  }

  if (status == 'provider_failed' ||
      status == 'network_error' ||
      status == 'auth_error' ||
      status == 'rate_limit_error') {
    return OcrSmokeFailure(
      'provider',
      status ?? 'provider_failed',
    );
  }

  if (document != null && document['blockCount'] == 0) {
    return const OcrSmokeFailure(
      'provider',
      'empty_document',
    );
  }

  if (regionizer != null && regionizer['regionCount'] == 0) {
    return const OcrSmokeFailure(
      'regionizer',
      'empty_regionizer_output',
    );
  }
  if (status == 'regionizer_failed') {
    return const OcrSmokeFailure(
      'regionizer',
      'regionizer_failed',
    );
  }

  return null;
}

Map<String, dynamic> buildOcrSmokeIndependentParseReport({
  required OcrImportResult result,
  required int durationMs,
}) {
  final diagnostics = result.diagnostics;
  final document = diagnostics['document'] as Map?;
  final regionizer = diagnostics['regionizer'] as Map?;

  final Map<String, dynamic> report = {
    'stage': 'independent_parse',
    'status': diagnostics['status'],
    'durationMs': durationMs,
    if (document != null && document['blockCount'] != null) ...{
      'blockCount': document['blockCount'],
      'ocrBlockCount': document['blockCount'],
    },
    if (regionizer != null) ...{
      for (final entry in regionizer.entries)
        if (entry.key is String) entry.key as String: entry.value,
      'questionCandidateTraceTruncated':
          regionizer['questionCandidateTraceTruncated'] ??
              diagnostics['questionCandidateTraceTruncated'] ??
              false,
      'markerProbeTraceTruncated': regionizer['markerProbeTraceTruncated'] ??
          diagnostics['markerProbeTraceTruncated'] ??
          false,
      if (regionizer['markerProbeTrace'] != null)
        'markerProbeCount': regionizer['markerProbeCount'] ??
            (regionizer['markerProbeTrace'] as List).length,
    },
    'assembledQuestionCount': result.questions.length,
    'finalQuestionCount': result.questions.length,
  };

  for (final entry in diagnostics.entries) {
    final key = entry.key;
    if (key != 'document' &&
        key != 'regionizer' &&
        key != 'Authorization' &&
        key != 'rawResponses' &&
        key != 'status') {
      report.putIfAbsent(key, () => entry.value);
    }
  }

  return report;
}

Map<String, dynamic> buildOcrSmokeTerminalEvent(Map<String, dynamic> event) {
  final stage = event['stage'];
  if (stage == 'preflight') {
    return {
      'stage': 'preflight',
      if (event.containsKey('apiKeyPresent'))
        'apiKeyPresent': event['apiKeyPresent'],
      if (event.containsKey('pdfCount')) 'pdfCount': event['pdfCount'],
      if (event.containsKey('pdfReadable')) 'pdfReadable': event['pdfReadable'],
      if (event.containsKey('status')) 'status': event['status'],
      if (event.containsKey('causeType')) 'causeType': event['causeType'],
    };
  }
  if (stage == 'credential_probe') {
    return {
      'stage': 'credential_probe',
      'status': event['status'],
      'apiKeyPresent': event['apiKeyPresent'],
      if (event['causeType'] != null) 'causeType': event['causeType'],
    };
  }
  if (stage == 'replay_cache') {
    return {
      'stage': 'replay_cache',
      'status': event['status'],
      if (event['caseId'] != null) 'caseId': event['caseId'],
      if (event['fingerprint'] != null) 'fingerprint': event['fingerprint'],
      if (event['causeType'] != null) 'causeType': event['causeType'],
    };
  }
  if (stage == 'independent_parse') {
    final candidates = event['questionCandidateTrace'] as List? ??
        event['questionCandidates'] as List?;
    Map<String, dynamic>? firstAnomaly;
    if (candidates != null) {
      for (final item in candidates) {
        if (item is Map<String, dynamic>) {
          final decision = item['decision'] ?? item['status'];
          if (decision == 'rejected') {
            firstAnomaly = item;
            break;
          }
        }
      }
    }

    return {
      'stage': 'independent_parse',
      'status': event['status'],
      'durationMs': event['durationMs'],
      'ocrBlockCount': event['ocrBlockCount'] ?? event['blockCount'],
      'questionCandidateCount':
          event['questionCandidateCount'] ?? candidates?.length,
      'acceptedNumbers': event['acceptedNumbers'],
      'rejectedCandidateCount': event['rejectedCandidateCount'],
      'duplicateNumbers': event['duplicateNumbers'],
      'missingNumbers': event['missingNumbers'],
      'regionCount': event['regionCount'],
      'assembledQuestionCount': event['assembledQuestionCount'],
      'finalQuestionCount': event['finalQuestionCount'],
      'referenceSectionDetected': event['referenceSectionDetected'],
      'referenceSectionCandidateCount': event['referenceSectionCandidateCount'],
      'questionCandidateTraceTruncated':
          event['questionCandidateTraceTruncated'],
      'markerProbeCount': event['markerProbeCount'],
      'markerProbeTraceTruncated': event['markerProbeTraceTruncated'],
      'firstAnomaly': firstAnomaly != null
          ? {
              'number': firstAnomaly['number'],
              'decision': firstAnomaly['decision'] ?? firstAnomaly['status'],
              'reason': firstAnomaly['reason'],
            }
          : null,
    };
  }
  const safeKeys = {
    'stage',
    'status',
    'causeType',
    'durationMs',
    'apiKeyPresent',
    'pdfCount',
    'pdfReadable',
    'requiresReview',
    'blocked',
    'caseId',
    'fingerprint',
  };
  return {
    for (final entry in event.entries)
      if (safeKeys.contains(entry.key)) entry.key: entry.value,
  };
}

Future<String?> loadSavedOcrApiKey({
  required AiEngineRepository repository,
}) async {
  final profile = await repository.getActiveOcrEngine();
  return profile?.apiKey;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;

  String? repoRootArg;
  for (final arg in args) {
    if (arg.startsWith('--repository-root=')) {
      repoRootArg = arg.substring(18);
    }
  }
  final repoRoot = repoRootArg ??
      environment['SHIROHA_REPOSITORY_ROOT'] ??
      Directory.current.path;

  final environmentApiKey = environment['SHIROHA_OCR_API_KEY'];
  final useSavedAppKey =
      environment['SHIROHA_OCR_USE_SAVED_APP_KEY'] == 'true' &&
          (environmentApiKey == null || environmentApiKey.trim().isEmpty);

  AiEngineRepository? savedKeyRepository;
  if (useSavedAppKey && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final helper = DatabaseHelper.instance;
    savedKeyRepository = AiEngineRepository(store: helper);
  }
  final resolvedSavedKeyRepository = savedKeyRepository;

  final exitCode = await runOcrSmoke(
    args,
    stdout.writeln,
    environment: environment,
    repositoryRoot: repoRoot,
    loadSavedApiKey: resolvedSavedKeyRepository != null
        ? () => loadSavedOcrApiKey(repository: resolvedSavedKeyRepository)
        : null,
    reportWriter: OcrSmokeReportWriter(
      repositoryRoot: repoRoot,
      runId: environment['SHIROHA_OCR_RUN_ID'],
    ),
    buildCacheHit: switch (environment['SHIROHA_OCR_BUILD_CACHE_HIT']) {
      'true' => true,
      'false' => false,
      _ => null,
    },
  );
  exit(exitCode);
}

Future<int> runOcrSmoke(
  List<String> args,
  void Function(String) printLine, {
  required Map<String, String> environment,
  String? repositoryRoot,
  OcrSmokeReportWriter? reportWriter,
  bool? buildCacheHit,
  OcrSmokeSavedApiKeyLoader? loadSavedApiKey,
}) async {
  final events = <Map<String, dynamic>>[];

  void emitEvent(Map<String, dynamic> event) {
    events.add(Map<String, dynamic>.from(event));
    printLine(jsonEncode(buildOcrSmokeTerminalEvent(event)));
  }

  final exitCode = await _runOcrSmokeCore(
    args,
    emitEvent,
    environment: environment,
    repositoryRoot: repositoryRoot,
    loadSavedApiKey: loadSavedApiKey,
  );
  if (reportWriter != null) {
    final result = await reportWriter.write(
      events: events,
      exitCode: exitCode,
      buildCacheHit: buildCacheHit,
    );
    printLine(jsonEncode(
      result.succeeded ? result.terminalEvent : result.failureEvent,
    ));
  }
  return exitCode;
}

Future<int> _runOcrSmokeCore(
  List<String> args,
  void Function(Map<String, dynamic>) printJson, {
  required Map<String, String> environment,
  String? repositoryRoot,
  OcrSmokeSavedApiKeyLoader? loadSavedApiKey,
}) async {
  int exitWithError(
    String status, {
    String stage = 'failed',
    String? causeType,
    int code = 1,
  }) {
    printJson({
      'stage': stage,
      'status': status,
      if (causeType != null) 'causeType': causeType,
    });
    return code;
  }

  String? effectiveRepoRoot = repositoryRoot;
  for (final arg in args) {
    if (arg.startsWith('--repository-root=')) {
      effectiveRepoRoot = arg.substring(18);
    }
  }
  effectiveRepoRoot ??=
      environment['SHIROHA_REPOSITORY_ROOT'] ?? Directory.current.path;
  final rootDir = Directory(effectiveRepoRoot).absolute;
  if (!File(p.join(rootDir.path, 'pubspec.yaml')).existsSync()) {
    return exitWithError(
      'repository_root_invalid',
      stage: 'launcher',
      causeType: 'InvalidRepositoryRoot',
      code: 1,
    );
  }

  final isSavedKeyProbe = args.contains('--saved-key-probe') ||
      environment['SHIROHA_SAVED_KEY_PROBE'] == 'true';
  final writeReplayCacheEnabled = args.contains('--write-replay-cache') ||
      environment['SHIROHA_WRITE_REPLAY_CACHE'] == 'true';

  if (isSavedKeyProbe && writeReplayCacheEnabled) {
    return exitWithError(
      'invalid_arguments',
      stage: 'launcher',
      causeType: 'InvalidArguments',
      code: 2,
    );
  }

  String replayCaseId = environment['SHIROHA_REPLAY_CASE_ID'] ?? '';
  for (final arg in args) {
    if (arg.startsWith('--case-id=')) {
      replayCaseId = arg.substring(10);
    } else if (arg.startsWith('--replay-case-id=')) {
      replayCaseId = arg.substring(17);
    }
  }

  final List<String> pdfArgs = [];
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--repository-root=')) {
      continue;
    } else if (arg == '--write-replay-cache' || arg == '--saved-key-probe') {
      continue;
    } else if (arg.startsWith('--case-id=') ||
        arg.startsWith('--replay-case-id=')) {
      continue;
    } else if (arg.startsWith('--pdf=')) {
      pdfArgs.add(arg.substring(6));
    } else if (arg == '--pdf') {
      if (i + 1 < args.length) {
        pdfArgs.add(args[i + 1]);
        i++;
      } else {
        return exitWithError('invalid_arguments',
            stage: 'launcher', causeType: 'InvalidPdfArgument', code: 1);
      }
    } else if (arg.startsWith('-p=')) {
      pdfArgs.add(arg.substring(3));
    } else if (arg == '-p') {
      if (i + 1 < args.length) {
        pdfArgs.add(args[i + 1]);
        i++;
      } else {
        return exitWithError('invalid_arguments',
            stage: 'launcher', causeType: 'InvalidPdfArgument', code: 1);
      }
    } else if (!arg.startsWith('-')) {
      pdfArgs.add(arg);
    }
  }

  if (writeReplayCacheEnabled) {
    if (pdfArgs.length != 1) {
      return exitWithError(
        'replay_cache_requires_single_pdf',
        stage: 'launcher',
        causeType: 'InvalidReplayCacheRequest',
        code: 2,
      );
    }
    if (replayCaseId.trim().isEmpty) {
      return exitWithError(
        'replay_case_id_required',
        stage: 'launcher',
        causeType: 'InvalidReplayCacheRequest',
        code: 2,
      );
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(replayCaseId)) {
      return exitWithError(
        'invalid_replay_case_id',
        stage: 'launcher',
        causeType: 'InvalidReplayCaseId',
        code: 2,
      );
    }
  }

  var apiKey = environment['SHIROHA_OCR_API_KEY'];
  final environmentApiKeyPresent = apiKey != null && apiKey.trim().isNotEmpty;
  final useSavedAppKey = environment['SHIROHA_OCR_USE_SAVED_APP_KEY'] == 'true';

  if (!environmentApiKeyPresent && useSavedAppKey) {
    try {
      apiKey = await loadSavedApiKey?.call();
    } catch (_) {
      apiKey = null;
    }
  }
  final apiKeyPresent = apiKey != null && apiKey.trim().isNotEmpty;

  if (isSavedKeyProbe) {
    if (apiKeyPresent) {
      printJson({
        'stage': 'credential_probe',
        'status': 'available',
        'apiKeyPresent': true,
      });
      return 0;
    } else {
      printJson({
        'stage': 'credential_probe',
        'status': 'unavailable',
        'apiKeyPresent': false,
        'causeType': 'SavedApiKeyUnavailable',
      });
      return 1;
    }
  }

  printJson({
    'stage': 'preflight',
    'apiKeyPresent': apiKeyPresent,
  });

  if (!apiKeyPresent && useSavedAppKey) {
    return exitWithError(
      'saved_api_key_unavailable',
      stage: 'launcher',
      causeType: 'SavedApiKeyUnavailable',
      code: 1,
    );
  }
  if (!apiKeyPresent) {
    return exitWithError(
      'missing_api_key',
      stage: 'launcher',
      causeType: 'MissingApiKey',
      code: 1,
    );
  }

  if (!isSavedKeyProbe) {
    if (pdfArgs.isEmpty) {
      return exitWithError(
        'invalid_pdf_argument',
        stage: 'launcher',
        causeType: 'InvalidPdfArgument',
        code: 1,
      );
    }
    if (pdfArgs.length > 2) {
      return exitWithError(
        'invalid_arguments',
        stage: 'launcher',
        causeType: 'InvalidArguments',
        code: 1,
      );
    }
  }

  final baseUrl = environment['SHIROHA_OCR_BASE_URL'] ??
      'https://open.bigmodel.cn/api/paas';

  final validPaths = <String>[];
  for (final String pdfArg in pdfArgs) {
    try {
      validPaths.add(
        resolveOcrSmokePdfPath(
          pdfArg,
          repositoryRoot: rootDir.path,
        ),
      );
    } on OcrSmokePreflightException catch (error) {
      return exitWithError(
        error.status,
        stage:
            error.status == 'invalid_pdf_argument' ? 'launcher' : 'preflight',
        causeType: error.causeType,
        code: 1,
      );
    }
  }
  printJson({
    'stage': 'preflight',
    'pdfCount': validPaths.length,
    'pdfReadable': true,
  });

  final profile = AiEngineProfile(
    id: 'smoke-test-ocr',
    engineType: AiEngineType.ocr,
    name: 'smoke-test-zhipu',
    apiKey: apiKey,
    baseUrl: baseUrl,
    modelName: ZhipuOcrClient.model,
    temperature: 0.0,
    reasoningEffort: '',
    isActive: true,
  );

  final repository = _StubAiEngineRepository(profile);
  final repairService =
      SingleQuestionRepairService(engineRepository: repository);

  final capturingClient = _CapturingOcrClient(const ZhipuOcrClient());

  final ocrService = OcrImportService(
    engineRepository: repository,
    ocrClient: capturingClient,
    repairService: repairService,
  );

  final batches = <MultiFileQuestionBatch>[];
  var hasFailure = false;

  for (int i = 0; i < validPaths.length; i++) {
    final fullPath = validPaths[i];
    final fileName = p.basename(fullPath);
    final stopwatch = Stopwatch()..start();

    try {
      final result = await ocrService.tryParse(
        filePath: fullPath,
        sourceName: fileName,
        format: ImportFormat.pdf,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      stopwatch.stop();

      if (result == null) {
        printJson({
          'stage': 'independent_parse',
          'status': 'skipped_null',
          'durationMs': stopwatch.elapsedMilliseconds,
        });
        continue;
      }

      final diagnostics = result.diagnostics;
      final classifiedFailure = classifyOcrSmokeResultFailure(result);
      if (classifiedFailure != null) {
        hasFailure = true;
        printJson({
          'stage': classifiedFailure.stage,
          'status': classifiedFailure.status,
          if (diagnostics['errorType'] case final String errorType)
            'causeType': errorType,
          'durationMs': stopwatch.elapsedMilliseconds,
        });
        continue;
      }
      printJson(buildOcrSmokeIndependentParseReport(
        result: result,
        durationMs: stopwatch.elapsedMilliseconds,
      ));

      batches.add(MultiFileQuestionBatch(
        fileIndex: i,
        questions: result.questions,
      ));
    } on FileSystemException catch (error) {
      stopwatch.stop();
      hasFailure = true;
      printJson({
        'stage': 'preflight',
        'status': 'file_read_error',
        'causeType': error.runtimeType.toString(),
        'durationMs': stopwatch.elapsedMilliseconds,
      });
    } catch (error) {
      stopwatch.stop();
      hasFailure = true;
      final responseFormat =
          error is FormatException || error is ZhipuOcrResponseFormatException;
      printJson({
        'stage': 'provider',
        'status': responseFormat ? 'response_format_error' : 'request_error',
        'causeType': error.runtimeType.toString(),
        'durationMs': stopwatch.elapsedMilliseconds,
      });
    }
  }

  if (validPaths.length == 2 && !hasFailure) {
    try {
      final mergeService = const MultiFileQuestionMergeService();
      final mergeResult = mergeService.merge(batches);
      final metrics = mergeResult.metrics.toMap();

      printJson({
        'stage': 'combined_merge',
        'status': 'success',
        '输入文件数': metrics['inputFileCount'],
        '各文件题目数': metrics['parsedQuestionCountByFile'],
        '最终题目数': metrics['finalQuestionCount'],
        '题号': mergeResult.mergedQuestions.map((q) => q['q_num']).toList(),
        '合并数': metrics['mergedQuestionCount'],
        '残留数': metrics['unmatchedFragmentCount'],
        '冲突数': (metrics['stemConflictCount'] as int) +
            (metrics['answerConflictCount'] as int),
        'requiresReview': metrics['requiresReview'],
        'blocked': metrics['blocked'],
      });
    } catch (e) {
      hasFailure = true;
      printJson({
        'stage': 'combined_merge',
        'status': 'failed_merge_exception',
        'causeType': e.runtimeType.toString(),
      });
    }
  }

  if (hasFailure) return 1;

  // Write replay cache if requested
  if (writeReplayCacheEnabled) {
    if (capturingClient.lastDocument == null) {
      printJson({
        'stage': 'replay_cache',
        'status': 'document_unavailable',
        'causeType': 'ReplayDocumentUnavailable',
      });
      return 1;
    }
    try {
      final pdfFile = File(validPaths.first);
      final pdfBytes = pdfFile.readAsBytesSync();
      final fingerprint = computeReplayCacheFingerprint(
        pdfBytes: pdfBytes,
        documentSchemaVersion: 1,
        ocrModelId: ZhipuOcrClient.model,
      );
      final pdfHash = sha256.convert(pdfBytes).toString();
      writeReplayCache(
        caseId: replayCaseId,
        repositoryRoot: rootDir.path,
        document: capturingClient.lastDocument!,
        fingerprint: fingerprint,
        pdfContentHash: pdfHash,
      );
      printJson({
        'stage': 'replay_cache',
        'status': 'written',
        'caseId': replayCaseId,
        'fingerprint': fingerprint,
      });
    } catch (e) {
      printJson({
        'stage': 'replay_cache',
        'status': 'write_failed',
        'causeType': e.runtimeType.toString(),
      });
      return 1;
    }
  }

  printJson({
    'stage': 'completed',
    'status': 'success',
  });
  return 0;
}

class _StubAiEngineRepository extends AiEngineRepository {
  _StubAiEngineRepository(this._profile)
      : super(store: _OcrSmokeProfileStore(_profile));

  final AiEngineProfile _profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => _profile;
}

class _OcrSmokeProfileStore implements AiEngineStore {
  const _OcrSmokeProfileStore(this.profile);

  final AiEngineProfile profile;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    return profile.engineType == type ? <AiEngineProfile>[profile] : const [];
  }

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    return profile.engineType == type ? profile : null;
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    throw UnsupportedError('Read-only OCR smoke store');
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    throw UnsupportedError('Read-only OCR smoke store');
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    throw UnsupportedError('Read-only OCR smoke store');
  }
}

/// Wraps a ZhipuOcrClient to capture the last OcrDocument returned.
class _CapturingOcrClient extends ZhipuOcrClient {
  _CapturingOcrClient(this._delegate);

  final ZhipuOcrClient _delegate;
  OcrDocument? lastDocument;

  @override
  String get modelId => _delegate.modelId;

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    final doc = await _delegate.parseFile(
      profile: profile,
      filePath: filePath,
      sourceName: sourceName,
      timeout: timeout,
    );
    lastDocument = doc;
    return doc;
  }
}
