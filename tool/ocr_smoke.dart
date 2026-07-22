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

class _StubAiEngineRepository extends AiEngineRepository {
  _StubAiEngineRepository(this.profile);
  final AiEngineProfile profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => null;
}

Map<String, dynamic> buildOcrSmokeIndependentParseReport({
  required String fileName,
  required OcrImportResult result,
  required int durationMs,
}) {
  final diagnostics = result.diagnostics;
  final docDiagnostics = diagnostics['document'] as Map?;
  final regionizerDiagnostics = diagnostics['regionizer'] as Map?;

  return {
    'fileName': fileName,
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
}) async {
  void printJson(Map<String, dynamic> jsonMap) {
    printLine(jsonEncode(jsonMap));
  }

  int exitWithError(String status, {String? causeType, int code = 1}) {
    printJson({
      'stage': 'failed',
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
    return exitWithError('no_pdf_provided');
  }
  if (pdfArgs.length > 2) {
    return exitWithError('invalid_arguments');
  }

  if (!apiKeyPresent) {
    return exitWithError('missing_api_key');
  }
  final baseUrl = environment['SHIROHA_OCR_BASE_URL'] ??
      'https://open.bigmodel.cn/api/paas';

  final rootDir =
      p.canonicalize(p.join(Directory.current.path, 'scratch', 'test_pdfs'));

  final validPaths = <String>[];
  for (final String pdfArg in pdfArgs) {
    if (pdfArg.trim().isEmpty) {
      return exitWithError('invalid_arguments');
    }
    if (p.isAbsolute(pdfArg)) {
      return exitWithError('absolute_path_rejected');
    }
    if (pdfArg.contains('..')) {
      return exitWithError('path_traversal_rejected');
    }
    if (!pdfArg.toLowerCase().endsWith('.pdf')) {
      return exitWithError('non_pdf_rejected');
    }

    final fullPath = p.canonicalize(p.join(rootDir, pdfArg));
    if (!p.isWithin(rootDir, fullPath)) {
      return exitWithError('path_outside_root_rejected');
    }
    validPaths.add(fullPath);
  }

  final profile = AiEngineProfile(
    id: 'smoke-test-ocr',
    engineType: AiEngineType.ocr,
    name: 'smoke-test-zhipu',
    apiKey: apiKey,
    baseUrl: baseUrl,
    modelName: 'glm-4v',
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
  var hasProviderError = false;

  for (int i = 0; i < validPaths.length; i++) {
    final fullPath = validPaths[i];
    final fileName = p.basename(fullPath);
    final stopwatch = Stopwatch()..start();

    try {
      if (!File(fullPath).existsSync()) {
        throw FileSystemException('File not found', fullPath);
      }

      final result = await ocrService.tryParse(
        filePath: fullPath,
        sourceName: fileName,
        format: ImportFormat.pdf,
      );
      stopwatch.stop();

      if (result == null) {
        printJson({
          'fileName': fileName,
          'stage': 'independent_parse',
          'status': 'skipped_null',
          'durationMs': stopwatch.elapsedMilliseconds,
        });
        continue;
      }

      final diagnostics = result.diagnostics;
      printJson(buildOcrSmokeIndependentParseReport(
        fileName: fileName,
        result: result,
        durationMs: stopwatch.elapsedMilliseconds,
      ));

      if (diagnostics['status'] == 'failed_request') {
        hasProviderError = true;
      }

      batches.add(MultiFileQuestionBatch(
        fileIndex: i,
        questions: result.questions,
      ));
    } catch (e) {
      hasProviderError = true;
      printJson({
        'fileName': fileName,
        'stage': 'independent_parse',
        'status': 'failed_unhandled_exception',
        'causeType': e.runtimeType.toString(),
        'durationMs': stopwatch.elapsedMilliseconds,
      });
    }
  }

  if (validPaths.length == 2 && !hasProviderError) {
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
      hasProviderError = true;
      printJson({
        'stage': 'combined_merge',
        'status': 'failed_merge_exception',
        'causeType': e.runtimeType.toString(),
      });
    }
  }

  if (hasProviderError) {
    return exitWithError('provider_error');
  } else {
    printJson({
      'stage': 'completed',
      'status': 'success',
    });
    return 0;
  }
}
