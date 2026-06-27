import 'package:flutter/foundation.dart';

import '../../data/repositories/ai_engine_repository.dart';
import '../llm_providers/llm_provider_registry.dart';
import '../llm_providers/zhipu_ocr_client.dart';
import 'import_format.dart';
import 'local_question_assembler.dart';
import 'ocr_question_assembler.dart';
import 'ocr_question_regionizer.dart';
import 'single_question_repair_service.dart';

class OcrImportResult {
  const OcrImportResult({
    required this.usedOcr,
    required this.questions,
    required this.warnings,
    required this.diagnostics,
  });

  final bool usedOcr;
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
}

class OcrImportService {
  const OcrImportService({
    AiEngineRepository? engineRepository,
    ZhipuOcrClient ocrClient = const ZhipuOcrClient(),
    OcrQuestionRegionizer regionizer = const OcrQuestionRegionizer(),
    OcrQuestionAssembler assembler = const OcrQuestionAssembler(),
    SingleQuestionRepairService repairService =
        const SingleQuestionRepairService(),
  })  : _engineRepository = engineRepository,
        _ocrClient = ocrClient,
        _regionizer = regionizer,
        _assembler = assembler,
        _repairService = repairService;

  final AiEngineRepository? _engineRepository;
  final ZhipuOcrClient _ocrClient;
  final OcrQuestionRegionizer _regionizer;
  final OcrQuestionAssembler _assembler;
  final SingleQuestionRepairService _repairService;

  AiEngineRepository get engineRepository =>
      _engineRepository ?? AiEngineRepository.instance;

  Future<OcrImportResult?> tryParse({
    required String filePath,
    required String sourceName,
    required ImportFormat format,
  }) async {
    if (format != ImportFormat.pdf && format != ImportFormat.image) {
      return null;
    }

    final profile = await engineRepository.getActiveOcrEngine();
    if (profile == null ||
        LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
            LlmProviderKind.zhipu) {
      return null;
    }

    final diagnostics = <String, dynamic>{
      'sourceName': sourceName,
      'format': format.name,
      'provider': 'zhipu',
      'model': ZhipuOcrClient.model,
      'status': 'attempted',
    };

    try {
      final document = await _ocrClient.parseFile(
        profile: profile,
        filePath: filePath,
        sourceName: sourceName,
      );
      diagnostics['document'] = document.toDiagnostics();

      if (!document.hasUsableBlocks) {
        diagnostics['status'] = 'fallback_empty_ocr_blocks';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['GLM-OCR 未返回可用版面块，已降级为旧视觉解析路径。'],
          diagnostics: diagnostics,
        );
      }

      final regionized = _regionizer.regionize(document);
      diagnostics['regionizer'] = regionized.diagnostics;
      if (regionized.regions.isEmpty) {
        diagnostics['status'] = 'fallback_no_question_regions';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['GLM-OCR 未切分出题目区域，已降级为旧视觉解析路径。'],
          diagnostics: diagnostics,
        );
      }

      final questions = <Map<String, dynamic>>[];
      var repairRecommendedCount = 0;
      var repairAttemptedCount = 0;
      var repairAppliedCount = 0;
      var rejectedCount = 0;

      for (final region in regionized.regions) {
        var result = _assembler.assemble(region);
        if (result.repairRecommended && !result.rejected) {
          repairRecommendedCount++;
          repairAttemptedCount++;
          result = await _repairService.repair(
            region: region.toTextQuestionRegion(),
            localResult: result,
          );
          if (result.diagnostics.contains('ai_repair_applied')) {
            repairAppliedCount++;
          }
        }

        if (result.rejected) {
          rejectedCount++;
          continue;
        }

        questions.add(_restoreOcrProvenance(result, region));
      }

      if (questions.isEmpty) {
        diagnostics['status'] = 'fallback_no_assembled_questions';
        return OcrImportResult(
          usedOcr: false,
          questions: const [],
          warnings: const ['GLM-OCR 已返回内容，但本地组题为空，已降级为旧视觉解析路径。'],
          diagnostics: diagnostics,
        );
      }

      diagnostics.addAll({
        'status': 'used_ocr',
        'assembledQuestionCount': questions.length,
        'repairRecommendedCount': repairRecommendedCount,
        'repairAttemptedCount': repairAttemptedCount,
        'repairAppliedCount': repairAppliedCount,
        'rejectedRegionCount': rejectedCount,
      });

      return OcrImportResult(
        usedOcr: true,
        questions: questions,
        warnings: const [],
        diagnostics: diagnostics,
      );
    } catch (e, stackTrace) {
      debugPrint('OcrImportService: GLM-OCR failed, falling back: $e');
      debugPrint('$stackTrace');
      diagnostics['status'] = 'fallback_exception';
      diagnostics['error'] = e.toString();
      return OcrImportResult(
        usedOcr: false,
        questions: const [],
        warnings: ['GLM-OCR 解析失败，已降级为旧视觉解析路径：$e'],
        diagnostics: diagnostics,
      );
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
}
