import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/multi_file_question_merge_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

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

  return {
    'stage': 'independent_parse',
    'status': diagnostics['status'],
    'usedOcr': result.usedOcr,
    'pageCount': docDiagnostics?['pageCount'],
    'blockCount': docDiagnostics?['blockCount'],
    'unitCount': regionizerDiagnostics?['unitCount'],
    'regionCount': regionizerDiagnostics?['regionCount'],
    'acceptedNumbers': regionizerDiagnostics?['acceptedNumbers'],
    'missingNumbers': regionizerDiagnostics?['missingNumbers'],
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
    'questionCandidateTrace': regionizerDiagnostics?['questionCandidateTrace'],
    'questionCandidateTraceTruncated':
        regionizerDiagnostics?['questionCandidateTraceTruncated'],
    'durationMs': durationMs,
  };
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final exitCode = await runOcrSmoke(
    args,
    stdout.writeln,
    environment: Platform.environment,
  );
  exit(exitCode);
}

Future<int> runOcrSmoke(
  List<String> args,
  void Function(String) printLine, {
  required Map<String, String> environment,
  String? repositoryRoot,
}) async {
  void printJson(Map<String, dynamic> jsonMap) {
    printLine(jsonEncode(jsonMap));
  }

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

  final apiKey = environment['SHIROHA_OCR_API_KEY'];
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
  final ocrService = OcrImportService(
    engineRepository: repository,
    ocrClient: const ZhipuOcrClient(),
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

  printJson({
    'stage': 'completed',
    'status': 'success',
  });
  return 0;
}
