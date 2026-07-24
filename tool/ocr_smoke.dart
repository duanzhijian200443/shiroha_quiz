// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/multi_file_question_merge_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

import 'import_acceptance.dart' show writeReplayCache, computeReplayCacheFingerprint;
import 'ocr_smoke_report.dart';

typedef OcrSmokeSavedApiKeyLoader = Future<String?> Function();

class OcrSmokePreflightException implements Exception {
  const OcrSmokePreflightException(this.status, this.causeType);

  final String status;
  final String causeType;
}

class OcrSmokeFailure {
  const OcrSmokeFailure(this.stage, this.status);

  final String stage;
  final String status;

  @override
  bool operator ==(Object other) =>
      other is OcrSmokeFailure &&
      other.stage == stage &&
      other.status == status;

  @override
  int get hashCode => Object.hash(stage, status);
}

String resolveOcrSmokePdfPath(
  String pdfArgument, {
  required String repositoryRoot,
}) {
  final rawPath = pdfArgument.trim();
  if (rawPath.isEmpty || p.extension(rawPath).toLowerCase() != '.pdf') {
    throw const OcrSmokePreflightException(
      'invalid_pdf_argument',
      'InvalidPdfArgument',
    );
  }

  final allowedRoot = p.normalize(
    p.absolute(p.join(repositoryRoot, 'scratch', 'test_pdfs')),
  );
  final rawSegments = p.split(p.normalize(rawPath));
  if (rawSegments.contains('..')) {
    throw const OcrSmokePreflightException(
      'pdf_outside_allowed_root',
      'PdfOutsideAllowedRoot',
    );
  }

  final isRepositoryRelative = rawSegments.length >= 2 &&
      rawSegments[0].toLowerCase() == 'scratch' &&
      rawSegments[1].toLowerCase() == 'test_pdfs';
  final candidate = p.normalize(
    p.isAbsolute(rawPath)
        ? rawPath
        : p.join(isRepositoryRelative ? repositoryRoot : allowedRoot, rawPath),
  );
  if (!p.isWithin(allowedRoot, candidate)) {
    throw const OcrSmokePreflightException(
      'pdf_outside_allowed_root',
      'PdfOutsideAllowedRoot',
    );
  }

  final entityType = FileSystemEntity.typeSync(candidate, followLinks: true);
  if (entityType == FileSystemEntityType.notFound) {
    throw const OcrSmokePreflightException(
      'pdf_not_found',
      'FileSystemException',
    );
  }
  if (entityType != FileSystemEntityType.file) {
    throw const OcrSmokePreflightException(
      'file_read_error',
      'FileSystemException',
    );
  }

  try {
    final resolvedRoot = Directory(allowedRoot).resolveSymbolicLinksSync();
    final resolvedFile = File(candidate).resolveSymbolicLinksSync();
    if (!p.isWithin(resolvedRoot, resolvedFile)) {
      throw const OcrSmokePreflightException(
        'pdf_outside_allowed_root',
        'PdfOutsideAllowedRoot',
      );
    }
    final file = File(resolvedFile);
    if (file.lengthSync() <= 0) {
      throw const OcrSmokePreflightException(
        'file_read_error',
        'FileSystemException',
      );
    }
    final handle = file.openSync(mode: FileMode.read);
    handle.closeSync();
    return resolvedFile;
  } on OcrSmokePreflightException {
    rethrow;
  } on FileSystemException {
    throw const OcrSmokePreflightException(
      'file_read_error',
      'FileSystemException',
    );
  }
}

OcrSmokeFailure? classifyOcrSmokeResultFailure(OcrImportResult result) {
  final status = result.diagnostics['status'];
  if (status == 'failed_no_question_regions') {
    return const OcrSmokeFailure('regionizer', 'no_question_regions');
  }
  if (status != 'failed_request') return null;

  return switch (result.diagnostics['errorType']) {
    'FileSystemException' ||
    'PathNotFoundException' =>
      const OcrSmokeFailure('preflight', 'file_read_error'),
    'ZhipuOcrAuthenticationException' =>
      const OcrSmokeFailure('provider', 'authentication_error'),
    'ZhipuOcrResponseFormatException' ||
    'FormatException' =>
      const OcrSmokeFailure('provider', 'response_format_error'),
    _ => const OcrSmokeFailure('provider', 'request_error'),
  };
}

class _StubAiEngineRepository extends AiEngineRepository {
  _StubAiEngineRepository(this.profile);
  final AiEngineProfile profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => null;
}

Map<String, dynamic> buildOcrSmokeIndependentParseReport({
  required OcrImportResult result,
  required int durationMs,
}) {
  final diagnostics = result.diagnostics;
  final docDiagnostics = diagnostics['document'] as Map?;
  final regionizerDiagnostics = diagnostics['regionizer'] as Map?;
  final candidateTrace =
      regionizerDiagnostics?['questionCandidateTrace'] as List?;
  final markerProbeTrace = regionizerDiagnostics?['markerProbeTrace'] as List?;
  final acceptedNumbers =
      _safeIntegerList(regionizerDiagnostics?['acceptedNumbers']);
  final missingNumbers = <int>{
    ...?_safeIntegerList(regionizerDiagnostics?['missingNumbers']),
    ...?_safeIntegerList(regionizerDiagnostics?['tailMissingNumbers']),
  }.toList()
    ..sort();

  return {
    'stage': 'independent_parse',
    'status': diagnostics['status'],
    'usedOcr': result.usedOcr,
    'pageCount': docDiagnostics?['pageCount'],
    'blockCount': docDiagnostics?['blockCount'],
    'unitCount': regionizerDiagnostics?['unitCount'],
    'regionCount': regionizerDiagnostics?['regionCount'],
    'acceptedNumbers': acceptedNumbers,
    'duplicateNumbers': _duplicateNumbers(acceptedNumbers),
    'missingNumbers': regionizerDiagnostics == null ? null : missingNumbers,
    'tailMissingNumbers': regionizerDiagnostics?['tailMissingNumbers'],
    'sectionHeadingCount': regionizerDiagnostics?['sectionHeadingCount'],
    'numberedFieldCandidateCount':
        regionizerDiagnostics?['numberedFieldCandidateCount'],
    'splitUnitCount': regionizerDiagnostics?['splitUnitCount'],
    'markdownPrefixedCandidateCount':
        regionizerDiagnostics?['markdownPrefixedCandidateCount'],
    'blockStartCandidateCount':
        regionizerDiagnostics?['blockStartCandidateCount'],
    'internalLineCandidateCount':
        regionizerDiagnostics?['internalLineCandidateCount'],
    'parenthesizedArabicCandidateCount':
        regionizerDiagnostics?['parenthesizedArabicCandidateCount'],
    'parenthesizedArabicAcceptedCount':
        regionizerDiagnostics?['parenthesizedArabicAcceptedCount'],
    'parenthesizedArabicRejectedCount':
        regionizerDiagnostics?['parenthesizedArabicRejectedCount'],
    'romanSubquestionCount': regionizerDiagnostics?['romanSubquestionCount'],
    'sequenceAcceptedCount': regionizerDiagnostics?['sequenceAcceptedCount'],
    'sequenceRejectedCount': regionizerDiagnostics?['sequenceRejectedCount'],
    'questionCount': result.questions.length,
    'questionNumbers': result.questions.map((q) => q['q_num']).toList(),
    'assembledQuestionCount': diagnostics['assembledQuestionCount'],
    'finalQuestionCount': diagnostics['finalQuestionCount'],
    'warningCount': result.warnings.length,
    'documentRole': diagnostics['documentRole'],
    'documentRoleConfidence': diagnostics['documentRoleConfidence'],
    'explicitAnswerMarkerCount': diagnostics['explicitAnswerMarkerCount'],
    'explicitExplanationMarkerCount':
        diagnostics['explicitExplanationMarkerCount'],
    'documentQuestionCount': diagnostics['documentQuestionCount'],
    'documentNonEmptyStemCount': diagnostics['documentNonEmptyStemCount'],
    'documentSectionHeadingCount': diagnostics['documentSectionHeadingCount'],
    'localNonEmptyAnswerCount': diagnostics['localNonEmptyAnswerCount'],
    'localNonEmptyExplanationCount':
        diagnostics['localNonEmptyExplanationCount'],
    'finalNonEmptyAnswerCount': diagnostics['finalNonEmptyAnswerCount'],
    'finalNonEmptyExplanationCount':
        diagnostics['finalNonEmptyExplanationCount'],
    'repairRecommendedCount': diagnostics['repairRecommendedCount'],
    'repairAttemptedCount': diagnostics['repairAttemptedCount'],
    'repairAppliedCount': diagnostics['repairAppliedCount'],
    'repairSkippedForStemOnlyCount':
        diagnostics['repairSkippedForStemOnlyCount'],
    'discardedAnswerFromRepairCount':
        diagnostics['discardedAnswerFromRepairCount'],
    'clearedAssemblerAnswerCount': diagnostics['clearedAssemblerAnswerCount'],
    'rejectedRegionCount': diagnostics['rejectedRegionCount'],
    'questionCandidateTrace': candidateTrace,
    'questionCandidateCount': candidateTrace?.length,
    'rejectedCandidateCount': candidateTrace
        ?.where((candidate) =>
            candidate is Map && candidate['decision'] == 'rejected')
        .length,
    'referenceSectionDetected':
        regionizerDiagnostics?['referenceSectionDetected'],
    'referenceSectionCandidateCount':
        regionizerDiagnostics?['referenceSectionCandidateCount'],
    'questionCandidateTraceTruncated': regionizerDiagnostics == null
        ? null
        : regionizerDiagnostics['questionCandidateTraceTruncated'] == true,
    'markerProbeTrace': markerProbeTrace,
    'markerProbeCount': markerProbeTrace?.length,
    'markerProbeTraceTruncated': regionizerDiagnostics == null
        ? null
        : regionizerDiagnostics['markerProbeTraceTruncated'] == true,
    'durationMs': durationMs,
  };
}

List<int>? _safeIntegerList(Object? value) {
  if (value is! List) return null;
  return [
    for (final item in value)
      if (item is int) item else if (item is num) item.toInt(),
  ];
}

List<int>? _duplicateNumbers(List<int>? numbers) {
  if (numbers == null) return null;
  final counts = <int, int>{};
  for (final number in numbers) {
    counts[number] = (counts[number] ?? 0) + 1;
  }
  return counts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toList()
    ..sort();
}

Map<String, dynamic> buildOcrSmokeTerminalEvent(
  Map<String, dynamic> event,
) {
  if (event['stage'] == 'independent_parse') {
    final trace = event['questionCandidateTrace'];
    final candidates = trace is List ? trace : null;
    Map<String, dynamic>? firstAnomaly;
    if (candidates != null) {
      for (final candidate in candidates) {
        if (candidate is Map && candidate['decision'] == 'rejected') {
          firstAnomaly = {
            'number': candidate['number'],
            'decision': 'rejected',
            'reason': candidate['reason'],
          };
          break;
        }
      }
    }
    return {
      'stage': event['stage'],
      'status': event['status'],
      'durationMs': event['durationMs'],
      'ocrBlockCount': event['blockCount'],
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
      'firstAnomaly': firstAnomaly,
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
  };
  return {
    for (final entry in event.entries)
      if (safeKeys.contains(entry.key)) entry.key: entry.value,
  };
}

Future<String?> loadSavedOcrApiKey() async {
  final profile = await AiEngineRepository.instance.getActiveOcrEngine();
  return profile?.apiKey;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final environmentApiKey = environment['SHIROHA_OCR_API_KEY'];
  final useSavedAppKey =
      environment['SHIROHA_OCR_USE_SAVED_APP_KEY'] == 'true' &&
          (environmentApiKey == null || environmentApiKey.trim().isEmpty);
  if (useSavedAppKey && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final exitCode = await runOcrSmoke(
    args,
    stdout.writeln,
    environment: environment,
    loadSavedApiKey: useSavedAppKey ? loadSavedOcrApiKey : null,
    reportWriter: OcrSmokeReportWriter(
      repositoryRoot: Directory.current.path,
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
  printJson({
    'stage': 'preflight',
    'apiKeyPresent': apiKeyPresent,
  });

  final List<String> pdfArgs = [];
  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--pdf=')) {
      pdfArgs.add(arg.substring(6));
    } else if (arg == '--pdf') {
      if (i + 1 < args.length) {
        pdfArgs.add(args[i + 1]);
        i++;
      } else {
        return exitWithError('invalid_arguments');
      }
    } else if (arg.startsWith('-p=')) {
      pdfArgs.add(arg.substring(3));
    } else if (arg == '-p') {
      if (i + 1 < args.length) {
        pdfArgs.add(args[i + 1]);
        i++;
      } else {
        return exitWithError('invalid_arguments');
      }
    } else {
      return exitWithError('invalid_arguments');
    }
  }

  if (pdfArgs.isEmpty) {
    return exitWithError(
      'invalid_pdf_argument',
      stage: 'launcher',
      causeType: 'InvalidPdfArgument',
    );
  }
  if (pdfArgs.length > 2) {
    return exitWithError('invalid_arguments');
  }

  if (!apiKeyPresent && useSavedAppKey) {
    return exitWithError(
      'saved_api_key_unavailable',
      stage: 'launcher',
      causeType: 'SavedApiKeyUnavailable',
    );
  }
  if (!apiKeyPresent) {
    return exitWithError(
      'missing_api_key',
      stage: 'launcher',
      causeType: 'MissingApiKey',
    );
  }
  final baseUrl = environment['SHIROHA_OCR_BASE_URL'] ??
      'https://open.bigmodel.cn/api/paas';

  final validPaths = <String>[];
  for (final String pdfArg in pdfArgs) {
    try {
      validPaths.add(
        resolveOcrSmokePdfPath(
          pdfArg,
          repositoryRoot: repositoryRoot ?? Directory.current.path,
        ),
      );
    } on OcrSmokePreflightException catch (error) {
      return exitWithError(
        error.status,
        stage:
            error.status == 'invalid_pdf_argument' ? 'launcher' : 'preflight',
        causeType: error.causeType,
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

  final writeReplayCacheEnabled =
      environment['SHIROHA_WRITE_REPLAY_CACHE'] == 'true';
  final replayCaseId = environment['SHIROHA_REPLAY_CASE_ID'] ?? '';
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

  // Write replay cache if requested and OCR succeeded
  if (writeReplayCacheEnabled &&
      replayCaseId.isNotEmpty &&
      capturingClient.lastDocument != null) {
    try {
      final repoRoot = repositoryRoot ?? Directory.current.path;
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
        repositoryRoot: repoRoot,
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
    }
  }

  printJson({
    'stage': 'completed',
    'status': 'success',
  });
  return 0;
}

/// Wraps a ZhipuOcrClient to capture the last OcrDocument returned.
class _CapturingOcrClient extends ZhipuOcrClient {
  _CapturingOcrClient(this._delegate);

  final ZhipuOcrClient _delegate;
  OcrDocument? lastDocument;

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
