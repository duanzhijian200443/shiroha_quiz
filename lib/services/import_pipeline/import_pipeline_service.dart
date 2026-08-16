import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../application/import_review/typed_review_snapshot.dart';
import '../../core/observability/app_logger.dart';
import '../../core/observability/trace_context.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../ai_service.dart';
import '../task_manager.dart';
import 'final_question_latex_audit.dart';
import 'import_document_role.dart';
import 'import_file_detector.dart';
import 'import_format.dart';
import 'import_parse_request.dart';
import 'import_parse_result.dart';
import 'import_question_field_policy.dart';
import 'import_question_fusion_coordinator.dart';
import 'adapters/docx_document_adapter.dart';
import 'docx_text_first_parse_service.dart';
import 'parsed_document.dart';
import 'adapters/txt_document_adapter.dart';
import 'adapters/markdown_document_adapter.dart';
import 'adapters/pdf_text_extractor_adapter.dart';
import '../llm_providers/zhipu_ocr_client.dart';
import 'adapters/zip_document_adapter.dart';
import 'import_attempt_context.dart';
import 'import_question_final_sorter.dart';
import 'ocr_import_service.dart';
import 'ocr_request_scheduler.dart';
import 'ocr_typed_candidate.dart';
import 'pdf_page_image_renderer.dart';
import 'single_question_repair_service.dart';
import 'vision_batch_parse_coordinator.dart';
import 'vision_question_quality_gate.dart';
import 'vision_import_quality_summary.dart';

typedef ImportTextParser = Future<List<Map<String, dynamic>>> Function(
  String rawText, {
  required String taskId,
  required bool isMarkdown,
});

typedef ImportVisionParser = Future<List<Map<String, dynamic>>> Function(
  List<String> imagePaths,
);

typedef ImportOcrParser = Future<OcrImportResult?> Function({
  required String filePath,
  required String sourceName,
  required ImportFormat format,
  required ExplanationRetentionMode explanationRetentionMode,
});

typedef ImportQuestionMerger = Future<List<Map<String, dynamic>>> Function(
  List<List<Map<String, dynamic>>> fileResults,
);

class ImportPipelineService {
  ImportPipelineService({
    required AiService aiService,
    required AiEngineRepository engineRepository,
    required TaskManager taskManager,
    OcrRequestScheduler? ocrRequestScheduler,
  }) : this._(
          textParser: (
            rawText, {
            required taskId,
            required isMarkdown,
          }) =>
              aiService.parseTextToQuestions(
            rawText,
            taskId: taskId,
            isMarkdown: isMarkdown,
          ),
          visionParser: (imagePaths) => aiService.parseImagesWithVision(
            imagePaths,
            repairLatex: false,
          ),
          ocrParser: OcrImportService(
            ocrClient: const ZhipuOcrClient(),
            engineRepository: engineRepository,
            requestScheduler: ocrRequestScheduler ?? OcrRequestScheduler(),
            taskManager: taskManager,
          ).tryParse,
          questionMerger: aiService.mergeStructuredQuestions,
          taskManager: taskManager,
          docxTextFirstParseService: DocxTextFirstParseService(
            repairService: SingleQuestionRepairService(
              engineRepository: engineRepository,
            ),
          ),
        );

  ImportPipelineService._({
    required ImportTextParser textParser,
    required ImportVisionParser visionParser,
    required ImportOcrParser ocrParser,
    required ImportQuestionMerger questionMerger,
    required TaskManager taskManager,
    required DocxTextFirstParseService docxTextFirstParseService,
  })  : _textParser = textParser,
        _visionParser = visionParser,
        _ocrParser = ocrParser,
        _questionMerger = questionMerger,
        _taskManager = taskManager,
        _docxTextFirstParseService = docxTextFirstParseService;

  @visibleForTesting
  ImportPipelineService.forTesting({
    required ImportTextParser textParser,
    required ImportVisionParser visionParser,
    required ImportOcrParser ocrParser,
    ImportQuestionMerger? questionMerger,
    TaskManager? taskManager,
    DocxTextFirstParseService docxTextFirstParseService =
        const DocxTextFirstParseService(),
  }) : this._(
          textParser: textParser,
          visionParser: visionParser,
          ocrParser: ocrParser,
          questionMerger: questionMerger ?? _mergeQuestionsForTesting,
          taskManager: taskManager ?? TaskManager.instance,
          docxTextFirstParseService: docxTextFirstParseService,
        );

  final ImportTextParser _textParser;
  final ImportVisionParser _visionParser;
  final ImportOcrParser _ocrParser;
  final ImportQuestionMerger _questionMerger;
  final TaskManager _taskManager;
  final DocxTextFirstParseService _docxTextFirstParseService;

  static Future<List<Map<String, dynamic>>> _mergeQuestionsForTesting(
    List<List<Map<String, dynamic>>> fileResults,
  ) async {
    return fileResults.expand((questions) => questions).toList(growable: false);
  }

  Future<ImportParseResult> parseFiles(ImportParseRequest request) {
    Future<ImportParseResult> runPipeline() => AppLogger.span(
          'Import pipeline',
          () => _parseFiles(request),
          module: 'ImportPipeline',
          data: <String, Object?>{
            'fileCount': request.filePaths.length,
            'mode': request.mode.name,
            'maxConcurrency': request.maxConcurrency,
          },
        );

    if (TraceContext.traceId == null) {
      return TraceContext.run(
        taskId: request.taskId,
        action: runPipeline,
      );
    }
    return runPipeline();
  }

  Future<ImportParseResult> _parseFiles(ImportParseRequest request) async {
    List<List<Map<String, dynamic>>> fileResults = [];
    List<String> allWarnings = [];
    Map<String, dynamic> allDiagnostics = {};
    final taskId = request.taskId;
    OcrTypedCandidateBatch? ocrTypedCandidateBatch;

    bool hasStrictDocxRoute = false;
    bool hasBlockedParse = false;

    for (int fileIdx = 0; fileIdx < request.filePaths.length; fileIdx++) {
      final filePath = request.filePaths[fileIdx];
      final format = ImportFileDetector.detect(filePath);
      List<Map<String, dynamic>> singleFileQuestions = [];

      await _updateTaskProgress(
        taskId,
        '正在解析第 ${fileIdx + 1}/${request.filePaths.length} 个文件...',
        0.1 + (fileIdx / request.filePaths.length) * 0.7,
      );

      final sourceName = request.fileNames.length > fileIdx
          ? request.fileNames[fileIdx]
          : filePath.split(Platform.pathSeparator).last;

      AppLogger.info(
        'Import file processing started',
        module: 'ImportPipeline',
        data: <String, Object?>{
          'fileIndex': fileIdx,
          'format': format.name,
        },
      );

      switch (request.mode) {
        case ImportParseMode.text:
          if (format == ImportFormat.docx) {
            hasStrictDocxRoute = true;
            final parsedDoc = await DocxDocumentAdapter.parse(
              filePath: filePath,
              sourceName: sourceName,
            );
            final rawText =
                parsedDoc.toPlainTextForParsing(includeImages: false);

            allDiagnostics[sourceName] = parsedDoc.toDiagnostics();
            if (!parsedDoc.fallbackUsed &&
                (parsedDoc.signals.imageCount > 0 ||
                    parsedDoc.signals.tableCount > 0)) {
              allDiagnostics['${sourceName}_info'] =
                  '检测到 ${parsedDoc.signals.tableCount} 个表格、${parsedDoc.signals.imageCount} 张图片。图片仅记录，不再触发题干补充融合。';
            }

            final docxParseRes = await _docxTextFirstParseService.parseDocxText(
              rawText: rawText,
              sourceName: sourceName,
              taskId: taskId,
              documentSignals: parsedDoc.signals,
            );

            allWarnings.addAll(docxParseRes.warnings);
            allDiagnostics.addAll(docxParseRes.diagnostics);
            if (docxParseRes.blocked) {
              hasBlockedParse = true;
            }
            if (docxParseRes.diagnostics.containsKey('qualityGate')) {
              allDiagnostics['qualityGate'] =
                  docxParseRes.diagnostics['qualityGate'];
            } else if (docxParseRes.blocked) {
              allDiagnostics['qualityGate'] = {
                'blocked': true,
                'reason': docxParseRes.warnings.isNotEmpty
                    ? docxParseRes.warnings.first
                    : 'unknown',
              };
            }
            singleFileQuestions = docxParseRes.questions;
            break;
          }

          if (format == ImportFormat.image) {
            allWarnings.add('文本模式不支持图片文件，请改用视觉或 OCR 模式。');
            break;
          }

          final file = File(filePath);
          String rawText = '';
          bool isMarkdownFile = false;
          ParsedDocument? parsedDoc;

          if (format == ImportFormat.pdf) {
            rawText = await PdfTextExtractorAdapter.extractText(
              filePath: filePath,
            );
            if (rawText.trim().isEmpty) {
              allWarnings.add('未检测到可提取文字，请改用视觉或 OCR 模式。');
            }
          } else {
            if (format == ImportFormat.zip) {
              parsedDoc = await ZipDocumentAdapter.parse(
                filePath: filePath,
                sourceName: sourceName,
              );
              isMarkdownFile = true;
            } else if (format == ImportFormat.md) {
              parsedDoc = await MarkdownDocumentAdapter.parse(
                filePath: filePath,
                sourceName: sourceName,
              );
              isMarkdownFile = true;
            } else if (format == ImportFormat.txt) {
              parsedDoc = await TxtDocumentAdapter.parse(
                filePath: filePath,
                sourceName: sourceName,
              );
            } else {
              rawText = await file.readAsString();
            }

            if (parsedDoc != null) {
              rawText = parsedDoc.toPlainTextForParsing();
              allDiagnostics[sourceName] = parsedDoc.toDiagnostics();
              if (parsedDoc.diagnostics.containsKey('warning')) {
                allWarnings.add(parsedDoc.diagnostics['warning'].toString());
              }
              if (parsedDoc.diagnostics.containsKey('warnings')) {
                final warnings = parsedDoc.diagnostics['warnings'];
                if (warnings is List) {
                  allWarnings.addAll(warnings.map((e) => e.toString()));
                }
              }
            }
          }

          if (rawText.trim().length > 10) {
            singleFileQuestions = await _textParser(
              rawText,
              taskId: taskId,
              isMarkdown: isMarkdownFile,
            );
          }
          break;

        case ImportParseMode.vision:
          if (format != ImportFormat.pdf && format != ImportFormat.image) {
            allWarnings.add('视觉模式仅支持 PDF 或图片文件。');
            break;
          }

          final imagePaths = <String>[];
          if (format == ImportFormat.pdf) {
            final renderer = const PdfPageImageRenderer();
            final renderRes = await renderer.renderToImages(
              filePath: filePath,
              fileIndex: fileIdx,
            );
            imagePaths.addAll(renderRes.imagePaths);
            allWarnings.addAll(renderRes.warnings);
            allDiagnostics['pdf_render_file_$fileIdx'] = renderRes.diagnostics;
          } else {
            imagePaths.add(filePath);
          }

          final pagesPerBatch = format == ImportFormat.pdf ? 1 : 4;
          final batchCount =
              (imagePaths.length + pagesPerBatch - 1) ~/ pagesPerBatch;
          TaskManager.instance.appendPendingChunks(
            taskId,
            'vision',
            List.generate(batchCount, (i) => 'batch_${fileIdx}_$i'),
          );

          final visionRes = await const VisionBatchParseCoordinator().parse(
            imagePaths: imagePaths,
            pagesPerBatch: pagesPerBatch,
            maxConcurrency: request.maxConcurrency,
            parseBatch: _visionParser,
            onProgress: (progress, status) {
              TaskManager.instance.updateProgress(
                taskId,
                '文件 ${fileIdx + 1}/${request.filePaths.length} — $status',
                0.1 +
                    (fileIdx / request.filePaths.length) * 0.7 +
                    progress * (0.7 / request.filePaths.length),
              );
            },
            onBatchSuccess: (batchIdx, questions) {
              final chunkKey = 'batch_${fileIdx}_$batchIdx';
              TaskManager.instance
                  .markChunkSuccess(taskId, chunkKey, questions);
            },
            onBatchFailed: (batchIdx, error) {
              final chunkKey = 'batch_${fileIdx}_$batchIdx';
              TaskManager.instance.markChunkFailed(taskId, chunkKey);
            },
            onBatchRetry: (batchIdx, error) {
              debugPrint(
                'Vision batch $batchIdx encountered transient error, will retry: $error',
              );
            },
          );

          singleFileQuestions.addAll(visionRes.questions);
          allWarnings.addAll(visionRes.warnings);
          allDiagnostics['vision_batch_file_$fileIdx'] = visionRes.diagnostics;

          final pureVisionSourceName = format == ImportFormat.pdf
              ? 'vision_pdf_page'
              : 'vision_image_file';
          final fusion =
              const ImportQuestionFusionCoordinator().fuseTextAndVision(
            textQuestions: const [],
            visionQuestions: singleFileQuestions,
            sourceName: pureVisionSourceName,
            repairLatexAfterFusion: false,
          );
          final qualityGate = const VisionQuestionQualityGate().evaluate(
            fusion.questions,
            sourceName: pureVisionSourceName,
          );
          singleFileQuestions = qualityGate.questions;
          allWarnings.addAll(fusion.warnings);
          allWarnings.addAll(qualityGate.warnings);
          allDiagnostics.addAll(fusion.diagnostics);
          allDiagnostics['vision_quality_gate_file_$fileIdx'] =
              qualityGate.diagnostics;
          break;

        case ImportParseMode.ocr:
          if (format != ImportFormat.pdf && format != ImportFormat.image) {
            allWarnings.add('OCR 模式仅支持 PDF 或图片文件。');
            break;
          }

          final ocrResult = await _ocrParser(
            filePath: filePath,
            sourceName: sourceName,
            format: format,
            explanationRetentionMode: request.explanationRetentionMode,
          );
          if (ocrResult == null) {
            allWarnings.add('OCR 未能处理当前文件。');
            break;
          }
          ocrTypedCandidateBatch = ocrResult.typedCandidateBatch;

          allWarnings.addAll(ocrResult.warnings);
          allDiagnostics['ocr_import_file_$fileIdx'] = ocrResult.diagnostics;
          if (!ocrResult.usedOcr || ocrResult.questions.isEmpty) {
            if (ocrResult.warnings.isEmpty) {
              allWarnings.add('OCR 未能提取到有效题目。');
            }
            break;
          }

          final ocrQualityGate = const VisionQuestionQualityGate().evaluate(
            ocrResult.questions,
            sourceName: 'glm_ocr_intermediate',
            documentRole: tryParseImportDocumentRole(
              ocrResult.diagnostics['documentRole'],
            ),
          );
          singleFileQuestions = ocrQualityGate.questions;
          allWarnings.addAll(ocrQualityGate.warnings);
          allDiagnostics['ocr_quality_gate_file_$fileIdx'] =
              ocrQualityGate.diagnostics;
          allDiagnostics['vision_quality_gate_file_$fileIdx'] =
              ocrQualityGate.diagnostics;
          break;
      }

      if (singleFileQuestions.isNotEmpty) {
        fileResults.add(singleFileQuestions);
      }
    }

    if (fileResults.length > 1 && !hasStrictDocxRoute && !hasBlockedParse) {
      await _updateTaskProgress(
        taskId,
        '启动 AI 结构化交叉配对引擎...',
        0.9,
      );
      final merged = await _questionMerger(fileResults);
      final sorted = const ImportQuestionFinalSorter().sort(merged);
      allDiagnostics['final_sort'] = sorted.diagnostics;
      _attachVisionQualitySummary(allDiagnostics);
      final finalized = finalizeAndAuditImportQuestions(
        sorted.questions,
        mode: request.explanationRetentionMode,
      );
      final storage = _resolveOcrCandidateStorage(
        request,
        ocrTypedCandidateBatch,
        finalized,
      );
      return ImportParseResult.withStorageMetadata(
        questions: storage.questions,
        warnings: allWarnings,
        diagnostics: allDiagnostics,
        explanationRetentionMode: request.explanationRetentionMode,
        storageRoute: storage.route,
        storageReason: storage.reason,
      );
    } else if (fileResults.isNotEmpty) {
      final flattenedQuestions = fileResults.expand((e) => e).toList();
      final sorted = const ImportQuestionFinalSorter().sort(flattenedQuestions);
      allDiagnostics['final_sort'] = sorted.diagnostics;
      _attachVisionQualitySummary(allDiagnostics);
      final finalized = finalizeAndAuditImportQuestions(
        sorted.questions,
        mode: request.explanationRetentionMode,
      );
      final storage = _resolveOcrCandidateStorage(
        request,
        ocrTypedCandidateBatch,
        finalized,
      );
      return ImportParseResult.withStorageMetadata(
        questions: storage.questions,
        warnings: allWarnings,
        diagnostics: allDiagnostics,
        blocked: hasBlockedParse,
        blockReason: _readBlockReason(allDiagnostics),
        explanationRetentionMode: request.explanationRetentionMode,
        storageRoute: storage.route,
        storageReason: storage.reason,
      );
    } else {
      if (allWarnings.isEmpty && allDiagnostics.isNotEmpty) {
        allWarnings.add('解析完成，但未能提取到任何题目。请检查诊断信息。');
      }
      return ImportParseResult(
        questions: [],
        warnings: allWarnings,
        diagnostics: allDiagnostics,
        blocked: hasBlockedParse,
        blockReason: _readBlockReason(allDiagnostics),
        explanationRetentionMode: request.explanationRetentionMode,
      );
    }
  }

  String? _readBlockReason(Map<String, dynamic> diagnostics) {
    final gate = diagnostics['qualityGate'];
    if (gate is Map) {
      return (gate['reason']?.toString() ?? gate['severity']?.toString());
    }
    return null;
  }

  /// Resolves the R7B shadow candidate storage metadata after the final
  /// finalization. Non-OCR modes and parsers without a candidate batch keep
  /// the strict defaults; OCR batches go through the all-or-nothing gate.
  ({
    List<Map<String, dynamic>> questions,
    ImportStorageRoute route,
    String? reason
  }) _resolveOcrCandidateStorage(
    ImportParseRequest request,
    OcrTypedCandidateBatch? batch,
    List<Map<String, dynamic>> finalized,
  ) {
    if (request.mode != ImportParseMode.ocr || batch == null) {
      return (
        questions: finalized,
        route: ImportStorageRoute.legacyV1,
        reason: null,
      );
    }
    final gate = applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: finalized,
      singleFile: request.filePaths.length == 1,
    );
    return (
      questions: gate.questions,
      route: gate.route,
      reason: gate.reason,
    );
  }

  Future<void> _updateTaskProgress(
    String taskId,
    String text,
    double percent,
  ) async {
    final attempt = ImportAttemptContext.current;
    if (attempt != null && attempt.taskId == taskId) {
      await _taskManager.updateAttemptProgress(attempt, text, percent);
      return;
    }
    _taskManager.updateProgress(taskId, text, percent);
  }

  void _attachVisionQualitySummary(Map<String, dynamic> diagnostics) {
    diagnostics['visionQualitySummary'] =
        VisionImportQualitySummary.fromDiagnostics(diagnostics).toDiagnostics();
  }
}
