import '../../data/repositories/ai_engine_repository.dart';
import '../../core/observability/trace_context.dart';
import '../llm_providers/llm_provider_registry.dart';
import '../task_manager.dart';
import 'package:uuid/uuid.dart';
import 'final_question_latex_audit.dart';
import 'import_attempt_context.dart';
import 'import_document_role.dart';
import 'import_format.dart';
import 'import_question_field_policy.dart';
import 'import_question_repair_policy.dart';
import 'local_question_assembler.dart';
import 'ocr_typed_candidate.dart';
import 'ocr_document.dart';
import 'ocr_document_client.dart';
import 'ocr_question_assembler.dart';
import 'ocr_question_regionizer.dart';
import 'ocr_request_scheduler.dart';
import 'reference_answer_extractor.dart';
import 'reference_answer_merger.dart';
import 'single_question_repair_service.dart';

class OcrImportResult {
  const OcrImportResult({
    required this.usedOcr,
    required this.questions,
    required this.warnings,
    required this.diagnostics,
    this.typedCandidateBatch,
  });

  final bool usedOcr;
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;

  /// Shadow typed candidate batch produced in parallel with the legacy
  /// questions. Never part of [diagnostics].
  final OcrTypedCandidateBatch? typedCandidateBatch;
}

class OcrImportService {
  OcrImportService({
    required OcrDocumentClient ocrClient,
    required AiEngineRepository engineRepository,
    OcrQuestionRegionizer regionizer = const OcrQuestionRegionizer(),
    OcrQuestionAssembler assembler = const OcrQuestionAssembler(),
    ReferenceAnswerExtractor referenceAnswerExtractor =
        const ReferenceAnswerExtractor(),
    ReferenceAnswerMerger referenceAnswerMerger = const ReferenceAnswerMerger(),
    SingleQuestionRepairService? repairService,
    OcrRequestScheduler? requestScheduler,
    TaskManager? taskManager,
    String Function()? uuidV4Factory,
  })  : _ocrClient = ocrClient,
        _engineRepository = engineRepository,
        _regionizer = regionizer,
        _assembler = assembler,
        _referenceAnswerExtractor = referenceAnswerExtractor,
        _referenceAnswerMerger = referenceAnswerMerger,
        _requestScheduler = requestScheduler ?? OcrRequestScheduler(),
        _taskManager = taskManager,
        _uuidV4Factory = uuidV4Factory ?? _defaultUuidV4,
        _repairService = repairService ??
            SingleQuestionRepairService(
              engineRepository: engineRepository,
            );

  final OcrDocumentClient _ocrClient;
  final AiEngineRepository _engineRepository;
  final OcrQuestionRegionizer _regionizer;
  final OcrQuestionAssembler _assembler;
  final ReferenceAnswerExtractor _referenceAnswerExtractor;
  final ReferenceAnswerMerger _referenceAnswerMerger;
  final OcrRequestScheduler _requestScheduler;
  final TaskManager? _taskManager;
  final SingleQuestionRepairService _repairService;
  final String Function() _uuidV4Factory;

  static String _defaultUuidV4() => const Uuid().v4();

  Future<OcrImportResult?> tryParse({
    required String filePath,
    required String sourceName,
    required ImportFormat format,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    if (format != ImportFormat.pdf && format != ImportFormat.image) {
      return null;
    }

    final profile = await _engineRepository.getActiveOcrEngine();
    if (profile == null ||
        LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
            LlmProviderKind.zhipu) {
      return const OcrImportResult(
        usedOcr: false,
        questions: <Map<String, dynamic>>[],
        warnings: <String>['未配置可用的智谱 OCR 引擎，请先完成 OCR 配置。'],
        diagnostics: <String, dynamic>{'status': 'failed_not_configured'},
      );
    }

    final diagnostics = <String, dynamic>{
      'sourceName': sourceName,
      'format': format.name,
      'provider': 'zhipu',
      'model': _ocrClient.modelId,
      'status': 'attempted',
    };
    final repairAttempts = <Map<String, dynamic>>[];
    final timing = <String, dynamic>{
      'ocrDurationMs': 0,
      'regionizerDurationMs': 0,
      'assemblyDurationMs': 0,
      'repairDurationMs': 0,
      'finalizationDurationMs': 0,
      'repairAttempts': repairAttempts,
    };
    diagnostics['timing'] = timing;
    final totalStopwatch = Stopwatch()..start();

    T measureStage<T>(String key, T Function() action) {
      final stopwatch = Stopwatch()..start();
      try {
        return action();
      } finally {
        stopwatch.stop();
        timing[key] = stopwatch.elapsedMilliseconds;
      }
    }

    Future<T> measureAsyncStage<T>(
      String key,
      Future<T> Function() action,
    ) async {
      final stopwatch = Stopwatch()..start();
      try {
        return await action();
      } finally {
        stopwatch.stop();
        timing[key] = stopwatch.elapsedMilliseconds;
      }
    }

    try {
      final attempt = ImportAttemptContext.current;
      final taskManager = _taskManager;
      if (attempt != null &&
          taskManager != null &&
          !taskManager.isAttemptRunnable(attempt)) {
        throw const OcrRequestCancelledException();
      }
      final document = await measureAsyncStage(
        'ocrDurationMs',
        () => _requestScheduler.run(
          taskId:
              attempt?.taskId ?? TraceContext.taskId ?? 'unscoped-ocr-import',
          attemptToken: attempt?.attemptToken,
          operation: () async {
            if (attempt != null && taskManager != null) {
              final runningStatus =
                  await taskManager.markAttemptRunning(attempt);
              if (runningStatus != ImportAttemptWriteStatus.applied ||
                  !taskManager.isAttemptRunnable(attempt)) {
                throw const OcrRequestCancelledException();
              }
            }
            return _ocrClient.parseFile(
              profile: profile,
              filePath: filePath,
              sourceName: sourceName,
            );
          },
        ),
      );
      if (attempt != null &&
          taskManager != null &&
          !taskManager.isAttemptRunnable(attempt)) {
        throw const OcrRequestCancelledException();
      }
      diagnostics['document'] = document.toDiagnostics();
      final unsupportedStructureSummary = _countUnsupportedStructures(document);
      if (unsupportedStructureSummary != null) {
        diagnostics['unsupportedStructureSummary'] =
            unsupportedStructureSummary;
      }

      if (!document.hasUsableBlocks) {
        diagnostics['status'] = 'failed_empty_ocr_blocks';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['OCR 未识别到有效文字，请检查文档清晰度后重试。'],
          diagnostics: diagnostics,
        );
      }

      final regionized = measureStage(
        'regionizerDurationMs',
        () => _regionizer.regionize(document),
      );
      diagnostics['regionizer'] = regionized.diagnostics;
      if (regionized.regions.isEmpty) {
        diagnostics['status'] = 'failed_no_question_regions';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['OCR 未识别到有效题目区域，请检查文档内容后重试。'],
          diagnostics: diagnostics,
        );
      }

      final referenceAnswerIndex = _referenceAnswerExtractor.extract(
        document,
        regionized.regions,
      );
      final mergedRegions = _referenceAnswerMerger.merge(
        regionized.regions,
        referenceAnswerIndex,
      );
      final referenceAnswerAttachedNumbers = mergedRegions
          .where(
            (region) =>
                region.diagnostics.contains('reference_answer_attached'),
          )
          .map((region) => region.number)
          .toList(growable: false);
      final referenceAnswerAttachedCount =
          referenceAnswerAttachedNumbers.length;
      final referenceAnswerConflictCount = mergedRegions
          .where(
            (region) =>
                region.diagnostics.contains('reference_answer_conflict') ||
                region.diagnostics
                    .contains('reference_answer_duplicate_conflict'),
          )
          .length;
      diagnostics['referenceAnswers'] = referenceAnswerIndex.diagnostics;
      diagnostics.addAll({
        'referenceAnswerSectionDetected':
            referenceAnswerIndex.diagnostics['referenceSectionDetected'],
        'referenceAnswerCandidateCount':
            referenceAnswerIndex.diagnostics['candidateCount'],
        'referenceAnswerAcceptedCount':
            referenceAnswerIndex.diagnostics['acceptedCount'],
        'referenceAnswerAttachedCount': referenceAnswerAttachedCount,
        'referenceAnswerAttachedNumbers': referenceAnswerAttachedNumbers,
        'referenceAnswerConflictCount': referenceAnswerConflictCount,
        'referenceAnswerAcceptedNumbers':
            referenceAnswerIndex.diagnostics['acceptedNumbers'],
      });

      var repairRecommendedCount = 0;
      var repairAttemptedCount = 0;
      var repairAppliedCount = 0;
      var rejectedCount = 0;

      final assembly = measureStage('assemblyDurationMs', () {
        final assembled = <_OcrAssemblyCandidate>[];
        for (final region in mergedRegions) {
          final result = _assembler.assemble(region);
          if (result.rejected) {
            rejectedCount++;
            continue;
          }
          assembled.add(_OcrAssemblyCandidate(region: region, result: result));
        }
        final roleAssessment = _assessDocumentRole(
          document: document,
          assembled: assembled,
          sectionHeadingCount:
              _readInt(regionized.diagnostics['sectionHeadingCount']),
        );
        return (candidates: assembled, roleAssessment: roleAssessment);
      });
      final assembled = assembly.candidates;
      final roleAssessment = assembly.roleAssessment;
      final isStemOnly = roleAssessment.role == ImportDocumentRole.stemOnly;
      final questions = <Map<String, dynamic>>[];
      var repairSkippedForStemOnlyCount = 0;
      var repairEligibleCount = 0;
      var repairSkippedNonStructuralCount = 0;
      var discardedAnswerFromRepairCount = 0;
      var clearedAssemblerAnswerCount = 0;
      var repairDurationMs = 0;
      var finalizationDurationMs = 0;

      LocalAssemblyResult finalizeForRepairRouting(
        LocalAssemblyResult localResult,
      ) {
        final stopwatch = Stopwatch()..start();
        try {
          return _finalizeForRepairRouting(
            localResult,
            explanationRetentionMode: explanationRetentionMode,
            requireAnswer: !isStemOnly,
          );
        } finally {
          stopwatch.stop();
          finalizationDurationMs += stopwatch.elapsedMilliseconds;
          timing['finalizationDurationMs'] = finalizationDurationMs;
        }
      }

      for (final candidate in assembled) {
        final region = candidate.region;
        var result = candidate.result;
        if (isStemOnly && _hasNonEmptyAnswer(result.question)) {
          clearedAssemblerAnswerCount++;
        }

        final initialRepairRecommended = result.repairRecommended;
        if (result.repairRecommended) {
          repairRecommendedCount++;
        }
        if (isStemOnly) {
          result = _enforceStemOnly(result);
        }
        result = finalizeForRepairRouting(result);

        final triggerCodes = const ImportQuestionRepairPolicy().candidateCodes(
          result.question,
          diagnostics: result.diagnostics,
          requireAnswer: roleAssessment.role != ImportDocumentRole.stemOnly,
        );
        if (triggerCodes.isNotEmpty) {
          repairEligibleCount++;
          repairAttemptedCount++;
          final repairStopwatch = Stopwatch()..start();
          var outcome = 'threw';
          try {
            result = await _repairService.repair(
              region: region.toTextQuestionRegion(),
              localResult: result,
              requireAnswer: !isStemOnly,
              explanationRetentionMode: explanationRetentionMode,
            );
            outcome = _repairOutcome(result);
            if (outcome == 'applied') {
              repairAppliedCount++;
              if (isStemOnly && _hasAnswerOrExplanation(result.question)) {
                discardedAnswerFromRepairCount++;
              }
            }
          } finally {
            repairStopwatch.stop();
            repairDurationMs += repairStopwatch.elapsedMilliseconds;
            timing['repairDurationMs'] = repairDurationMs;
            repairAttempts.add({
              'questionNumber': region.number,
              'triggerCodes': triggerCodes,
              'outcome': outcome,
              'durationMs': repairStopwatch.elapsedMilliseconds,
            });
          }
        } else if (initialRepairRecommended || result.repairRecommended) {
          repairSkippedNonStructuralCount++;
          if (isStemOnly) {
            repairSkippedForStemOnlyCount++;
          }
        }

        if (triggerCodes.isNotEmpty) {
          if (isStemOnly) {
            result = _enforceStemOnly(result);
          }
          result = finalizeForRepairRouting(result);
        }
        questions.add(_restoreOcrProvenance(result, region));
      }

      if (questions.isEmpty) {
        diagnostics['status'] = 'failed_no_assembled_questions';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['OCR 已返回文字，但未能组装出有效题目。'],
          diagnostics: diagnostics,
        );
      }

      diagnostics.addAll({
        'status': 'used_ocr',
        'assembledQuestionCount': questions.length,
        'finalQuestionCount': questions.length,
        ...roleAssessment.toDiagnostics(),
        'repairRecommendedCount': repairRecommendedCount,
        'repairAttemptCount': repairAttemptedCount,
        'repairAttemptedCount': repairAttemptedCount,
        'repairAppliedCount': repairAppliedCount,
        'repairEligibleCount': repairEligibleCount,
        'repairSkippedNonStructuralCount': repairSkippedNonStructuralCount,
        'repairSkippedForStemOnlyCount': repairSkippedForStemOnlyCount,
        'discardedAnswerFromRepairCount': discardedAnswerFromRepairCount,
        'clearedAssemblerAnswerCount': clearedAssemblerAnswerCount,
        'finalNonEmptyAnswerCount': questions.where(_hasNonEmptyAnswer).length,
        'finalNonEmptyExplanationCount':
            questions.where(_hasNonEmptyExplanation).length,
        'rejectedRegionCount': rejectedCount,
      });

      final typedCandidateBatch = _buildTypedCandidateBatch(
        document,
        <OcrQuestionRegion>[
          for (final candidate in assembled) candidate.region,
        ],
        questions,
      );

      return OcrImportResult(
        usedOcr: true,
        questions: questions,
        warnings: roleAssessment.role == ImportDocumentRole.ambiguous
            ? const ['文档答案结构不明确，请人工复核。']
            : const [],
        diagnostics: diagnostics,
        typedCandidateBatch: typedCandidateBatch,
      );
    } on OcrRequestCancelledException {
      rethrow;
    } catch (e) {
      diagnostics['status'] = 'failed_request';
      diagnostics['errorType'] = e.runtimeType.toString();
      return OcrImportResult(
        usedOcr: false,
        questions: const [],
        warnings: const ['OCR 请求失败，请检查 OCR 配置或网络后重试。'],
        diagnostics: diagnostics,
      );
    } finally {
      totalStopwatch.stop();
      timing['totalDurationMs'] = totalStopwatch.elapsedMilliseconds;
    }
  }

  Map<String, dynamic> _restoreOcrProvenance(
    LocalAssemblyResult result,
    OcrQuestionRegion region,
  ) {
    final question = Map<String, dynamic>.from(result.question);
    final diagnostics = <String>{
      ...region.diagnostics,
      ...result.diagnostics,
    }.toList();

    question['q_num'] = region.number.toString();
    question['question_number'] = region.number;
    question['source'] = diagnostics.contains('ai_repair_applied')
        ? 'glm_ocr_intermediate_ai_repair'
        : 'glm_ocr_intermediate';
    question['source_page_indices'] = region.sourcePageIndices;
    question['source_block_ids'] = region.sourceBlockIds;
    question['diagnostics'] = diagnostics;
    return question;
  }

  LocalAssemblyResult _finalizeForRepairRouting(
    LocalAssemblyResult result, {
    required ExplanationRetentionMode explanationRetentionMode,
    required bool requireAnswer,
  }) {
    final diagnostics = clearDerivedImportDiagnostics(result.diagnostics)
      ..removeWhere(
        (diagnostic) =>
            explanationRetentionMode ==
                ExplanationRetentionMode.allQuestionTypes &&
            diagnostic == 'dropped_non_subjective_explanation',
      );
    final finalized = finalizeAndAuditImportQuestion(
      <String, dynamic>{
        ...result.question,
        'diagnostics': diagnostics,
      },
      mode: explanationRetentionMode,
    );
    final finalizedDiagnostics = <String>{
      ...diagnostics,
      if (finalized['diagnostics'] is List)
        ...(finalized['diagnostics'] as List)
            .map((diagnostic) => diagnostic.toString()),
    }.toList(growable: false);
    final withCandidates =
        const ImportQuestionRepairPolicy().syncCandidateMetadata(
      finalized,
      diagnostics: finalizedDiagnostics,
      requireAnswer: requireAnswer,
    );

    return LocalAssemblyResult(
      question: withCandidates,
      diagnostics: finalizedDiagnostics,
      repairRecommended: result.repairRecommended,
      rejected: result.rejected,
    );
  }

  Map<String, int>? _countUnsupportedStructures(OcrDocument document) {
    var imageBlockCount = 0;
    var tableBlockCount = 0;
    for (final block in document.flattenedBlocks) {
      final type = block.type.trim().toLowerCase();
      if (type == 'image' || type == 'figure') {
        imageBlockCount += 1;
      } else if (type == 'table') {
        tableBlockCount += 1;
      }
    }
    if (imageBlockCount == 0 && tableBlockCount == 0) return null;
    return {
      'imageBlockCount': imageBlockCount,
      'tableBlockCount': tableBlockCount,
    };
  }

  OcrTypedCandidateBatch _buildTypedCandidateBatch(
    OcrDocument document,
    List<OcrQuestionRegion> regions,
    List<Map<String, dynamic>> legacyQuestions,
  ) {
    try {
      return buildOcrTypedCandidateBatch(
        document: document,
        regions: regions,
        legacyQuestions: legacyQuestions,
        uuidV4Factory: _uuidV4Factory,
      );
    } catch (_) {
      return OcrTypedCandidateBatch(
        candidates: <OcrTypedCandidate>[],
        failure: OcrTypedCandidateFailure.internalError,
      );
    }
  }

  _OcrDocumentRoleAssessment _assessDocumentRole({
    required OcrDocument document,
    required List<_OcrAssemblyCandidate> assembled,
    required int? sectionHeadingCount,
  }) {
    final questionCount = assembled.length;
    final nonEmptyStemCount = assembled
        .where(
            (item) => _readString(item.result.question['content']).isNotEmpty)
        .length;
    final nonEmptyAnswerCount = assembled
        .where((item) => _hasNonEmptyAnswer(item.result.question))
        .length;
    final nonEmptyExplanationCount = assembled
        .where((item) => _hasNonEmptyExplanation(item.result.question))
        .length;
    final markerCounts = _countExplicitMarkers(document.flattenedBlocks);
    final stemCoverage =
        questionCount == 0 ? 0.0 : nonEmptyStemCount / questionCount;
    final answerCoverage =
        questionCount == 0 ? 0.0 : nonEmptyAnswerCount / questionCount;
    final explanationCoverage =
        questionCount == 0 ? 0.0 : nonEmptyExplanationCount / questionCount;

    late final ImportDocumentRole role;
    late final double confidence;
    final hasExplicitMarkers =
        markerCounts.answer > 0 || markerCounts.explanation > 0;
    final hasStructuredAnswerData =
        nonEmptyAnswerCount > 0 || nonEmptyExplanationCount > 0;

    if (questionCount == 0 || stemCoverage < 0.8) {
      role = ImportDocumentRole.ambiguous;
      confidence = 0.4;
    } else if (hasExplicitMarkers) {
      if (hasStructuredAnswerData) {
        role = ImportDocumentRole.answerBearing;
        confidence = 0.95;
      } else {
        role = ImportDocumentRole.ambiguous;
        confidence = 0.5;
      }
    } else if (explanationCoverage == 0 && answerCoverage <= 0.25) {
      role = ImportDocumentRole.stemOnly;
      confidence = answerCoverage == 0 ? 0.95 : 0.8;
    } else {
      role = ImportDocumentRole.ambiguous;
      confidence = 0.55;
    }

    return _OcrDocumentRoleAssessment(
      role: role,
      confidence: confidence,
      explicitAnswerMarkerCount: markerCounts.answer,
      explicitExplanationMarkerCount: markerCounts.explanation,
      questionCount: questionCount,
      nonEmptyStemCount: nonEmptyStemCount,
      localNonEmptyAnswerCount: nonEmptyAnswerCount,
      localNonEmptyExplanationCount: nonEmptyExplanationCount,
      sectionHeadingCount: sectionHeadingCount ?? 0,
    );
  }

  _ExplicitMarkerCounts _countExplicitMarkers(Iterable<OcrBlock> blocks) {
    var answer = 0;
    var explanation = 0;
    final answerPattern = RegExp(
      r'(?:^|\n)\s*(?:#{1,6}\s+|>\s+)?(?:(?:【\s*(?:标准答案|参考答案|答案)\s*】)\s*|(?:标准答案|参考答案|答案)\s*[:：])',
      multiLine: true,
    );
    final explanationPattern = RegExp(
      r'(?:^|\n)\s*(?:#{1,6}\s+|>\s+)?(?:(?:【\s*(?:答案解析|解析|分析|详解|解)\s*】)\s*|(?:答案解析|解析|分析|详解|解)\s*[:：])',
      multiLine: true,
    );
    for (final block in blocks) {
      answer += answerPattern.allMatches(block.text).length;
      explanation += explanationPattern.allMatches(block.text).length;
    }
    return _ExplicitMarkerCounts(answer: answer, explanation: explanation);
  }

  String _repairOutcome(LocalAssemblyResult result) {
    if (result.diagnostics.contains('ai_repair_applied')) return 'applied';
    if (result.diagnostics.contains('repair_failed')) return 'failed';
    if (result.diagnostics.contains('repair_skipped_no_active_engine')) {
      return 'skipped_no_engine';
    }
    return 'unchanged';
  }

  LocalAssemblyResult _enforceStemOnly(LocalAssemblyResult result) {
    final question = Map<String, dynamic>.from(result.question)
      ..['standard_answer'] = ''
      ..['explanation'] = ''
      ..['raw_explanation'] = null;
    final diagnostics = result.diagnostics
        .where((item) => item != 'missing_answer')
        .toSet()
        .toList();
    final questionDiagnostics = question['diagnostics'];
    if (questionDiagnostics is List) {
      question['diagnostics'] = questionDiagnostics
          .map((item) => item.toString())
          .where((item) => item != 'missing_answer')
          .toSet()
          .toList();
    }
    return LocalAssemblyResult(
      question: question,
      diagnostics: diagnostics,
      repairRecommended: false,
      rejected: result.rejected,
    );
  }

  bool _hasNonEmptyAnswer(Map<String, dynamic> question) =>
      _readString(question['standard_answer']).isNotEmpty;

  bool _hasNonEmptyExplanation(Map<String, dynamic> question) =>
      _readString(question['explanation']).isNotEmpty ||
      _readString(question['raw_explanation']).isNotEmpty;

  bool _hasAnswerOrExplanation(Map<String, dynamic> question) =>
      _hasNonEmptyAnswer(question) || _hasNonEmptyExplanation(question);

  String _readString(Object? value) => value?.toString().trim() ?? '';

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(_readString(value));
  }
}

class _OcrAssemblyCandidate {
  const _OcrAssemblyCandidate({required this.region, required this.result});

  final OcrQuestionRegion region;
  final LocalAssemblyResult result;
}

class _ExplicitMarkerCounts {
  const _ExplicitMarkerCounts(
      {required this.answer, required this.explanation});

  final int answer;
  final int explanation;
}

class _OcrDocumentRoleAssessment {
  const _OcrDocumentRoleAssessment({
    required this.role,
    required this.confidence,
    required this.explicitAnswerMarkerCount,
    required this.explicitExplanationMarkerCount,
    required this.questionCount,
    required this.nonEmptyStemCount,
    required this.localNonEmptyAnswerCount,
    required this.localNonEmptyExplanationCount,
    required this.sectionHeadingCount,
  });

  final ImportDocumentRole role;
  final double confidence;
  final int explicitAnswerMarkerCount;
  final int explicitExplanationMarkerCount;
  final int questionCount;
  final int nonEmptyStemCount;
  final int localNonEmptyAnswerCount;
  final int localNonEmptyExplanationCount;
  final int sectionHeadingCount;

  Map<String, dynamic> toDiagnostics() => {
        'documentRole': role.name,
        'documentRoleConfidence': confidence,
        'explicitAnswerMarkerCount': explicitAnswerMarkerCount,
        'explicitExplanationMarkerCount': explicitExplanationMarkerCount,
        'documentQuestionCount': questionCount,
        'documentNonEmptyStemCount': nonEmptyStemCount,
        'localNonEmptyAnswerCount': localNonEmptyAnswerCount,
        'localNonEmptyExplanationCount': localNonEmptyExplanationCount,
        'documentSectionHeadingCount': sectionHeadingCount,
        'requiresReview': role == ImportDocumentRole.ambiguous,
      };
}
