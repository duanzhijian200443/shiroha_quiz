import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../ai_service.dart';
import '../task_manager.dart';
import 'import_file_detector.dart';
import 'import_format.dart';
import 'import_parse_request.dart';
import 'import_parse_result.dart';
import 'import_question_fusion_coordinator.dart';
import 'adapters/docx_document_adapter.dart';
import 'docx_text_first_parse_service.dart';
import 'parsed_document.dart';
import 'adapters/txt_document_adapter.dart';
import 'adapters/markdown_document_adapter.dart';
import 'adapters/zip_document_adapter.dart';
import 'mixed_document_vision_service.dart';
import 'pdf_page_image_renderer.dart';
import 'vision_batch_parse_coordinator.dart';

class ImportPipelineService {
  static final ImportPipelineService instance = ImportPipelineService._();
  ImportPipelineService._();

  Future<ImportParseResult> parseFiles(ImportParseRequest request) async {
    List<List<Map<String, dynamic>>> fileResults = [];
    List<String> allWarnings = [];
    Map<String, dynamic> allDiagnostics = {};
    final taskId = request.taskId;

    bool hasStrictDocxRoute = false;
    bool hasBlockedParse = false;

    for (int fileIdx = 0; fileIdx < request.filePaths.length; fileIdx++) {
      final filePath = request.filePaths[fileIdx];
      final format = ImportFileDetector.detect(filePath);
      List<Map<String, dynamic>> singleFileQuestions = [];

      TaskManager.instance.updateProgress(
        taskId,
        '正在解析第 ${fileIdx + 1}/${request.filePaths.length} 个文件...',
        0.1 + (fileIdx / request.filePaths.length) * 0.7,
      );

      final sourceName = request.fileNames.length > fileIdx
          ? request.fileNames[fileIdx]
          : filePath.split(Platform.pathSeparator).last;

      if (format == ImportFormat.docx) {
        hasStrictDocxRoute = true;
        final parsedDoc = await DocxDocumentAdapter.parse(
            filePath: filePath, sourceName: sourceName);
        final rawText = parsedDoc.toPlainTextForParsing(includeImages: false);
        
        allDiagnostics[sourceName] = parsedDoc.toDiagnostics();
        if (!parsedDoc.fallbackUsed) {
          if (parsedDoc.signals.imageCount > 0 ||
              parsedDoc.signals.tableCount > 0) {
            allDiagnostics['${sourceName}_info'] =
                '检测到 ${parsedDoc.signals.tableCount} 个表格、${parsedDoc.signals.imageCount} 张图片。图片仅记录，不再触发题干补充融合。';
          }
        }

        final docxParseRes = await DocxTextFirstParseService().parseDocxText(
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
          allDiagnostics['qualityGate'] = docxParseRes.diagnostics['qualityGate'];
        } else if (docxParseRes.blocked) {
          allDiagnostics['qualityGate'] = {
            'blocked': true,
            'reason': docxParseRes.warnings.isNotEmpty
                ? docxParseRes.warnings.first
                : 'unknown',
          };
        }

        singleFileQuestions = docxParseRes.questions;
        if (singleFileQuestions.isNotEmpty) {
          fileResults.add(singleFileQuestions);
        }
        continue;
      }

      if (request.useVisionEngine) {
        List<String> imagePaths = [];
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

        final int pagesPerBatch = format == ImportFormat.pdf ? 1 : 4;
        final int batchCount =
            (imagePaths.length + pagesPerBatch - 1) ~/ pagesPerBatch;

        TaskManager.instance.appendPendingChunks(
          taskId,
          'vision',
          List.generate(batchCount, (i) => 'batch_${fileIdx}_$i'),
        );

        final coordinator = const VisionBatchParseCoordinator();
        final visionRes = await coordinator.parse(
          imagePaths: imagePaths,
          pagesPerBatch: pagesPerBatch,
          maxConcurrency: request.maxConcurrency,
          parseBatch: (batchPaths) =>
              AiService.instance.parseImagesWithVision(batchPaths),
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
            TaskManager.instance.markChunkSuccess(taskId, chunkKey, questions);
          },
          onBatchFailed: (batchIdx, error) {
            final chunkKey = 'batch_${fileIdx}_$batchIdx';
            TaskManager.instance.markChunkFailed(taskId, chunkKey);
          },
          onBatchRetry: (batchIdx, error) {
            debugPrint(
                'Vision batch $batchIdx encountered transient error, will retry: $error');
          },
        );

        singleFileQuestions.addAll(visionRes.questions);
        allWarnings.addAll(visionRes.warnings);
        allDiagnostics['vision_batch_file_$fileIdx'] = visionRes.diagnostics;

        final fusionCoordinator = const ImportQuestionFusionCoordinator();
        final fusion = fusionCoordinator.fuseTextAndVision(
          textQuestions: [],
          visionQuestions: singleFileQuestions,
          sourceName: 'vision_pdf_page',
        );
        singleFileQuestions = fusion.questions;
        allWarnings.addAll(fusion.warnings);
        debugPrint('✅ 文件 ${fileIdx + 1}/${request.filePaths.length} '
            '本地拼图完成，得到 ${singleFileQuestions.length} 题');
      } else {
        final file = File(filePath);
        String rawText = '';
        bool isMarkdownFile = false;
        ParsedDocument? parsedDoc;
        final sourceName = request.fileNames.length > fileIdx
            ? request.fileNames[fileIdx]
            : filePath.split(Platform.pathSeparator).last;

        if (format == ImportFormat.pdf) {
          final bytes = await file.readAsBytes();
          final document = PdfDocument(inputBytes: bytes);
          rawText = PdfTextExtractor(document).extractText();
          document.dispose();
        } else {
          if (format == ImportFormat.zip) {
            parsedDoc = await ZipDocumentAdapter.parse(
                filePath: filePath, sourceName: sourceName);
            isMarkdownFile =
                true; // Treats as markdown because zip emits markdown text
          } else if (format == ImportFormat.md) {
            parsedDoc = await MarkdownDocumentAdapter.parse(
                filePath: filePath, sourceName: sourceName);
            isMarkdownFile = true;
          } else if (format == ImportFormat.txt) {
            parsedDoc = await TxtDocumentAdapter.parse(
                filePath: filePath, sourceName: sourceName);
          } else {
            // fallback for unknown
            rawText = await file.readAsString();
          }

          if (parsedDoc != null) {
            rawText = parsedDoc.toPlainTextForParsing();
            allDiagnostics[sourceName] = parsedDoc.toDiagnostics();
            if (parsedDoc.diagnostics.containsKey('warning')) {
              allWarnings.add(parsedDoc.diagnostics['warning'].toString());
            }
            if (parsedDoc.diagnostics.containsKey('warnings')) {
              final w = parsedDoc.diagnostics['warnings'];
              if (w is List) {
                allWarnings.addAll(w.map((e) => e.toString()));
              }
            }
          }
        }

        if (rawText.trim().length > 10) {
          singleFileQuestions = await AiService.instance.parseTextToQuestions(
              rawText,
              taskId: taskId,
              isMarkdown: isMarkdownFile);
        }

        // --- Phase 4-A: Mixed Vision Supplement ---
        if (format != ImportFormat.docx && parsedDoc != null && parsedDoc.imageAssets.isNotEmpty) {
          TaskManager.instance.updateProgress(
              taskId,
              '文件 ${fileIdx + 1}/${request.filePaths.length} — 启动图文混合补充解析...',
              0.1 + (fileIdx / request.filePaths.length) * 0.7 + 0.05);

          final mixedService = MixedDocumentVisionService();
          final visionResult = await mixedService.process(parsedDoc);

          if (visionResult.questions.isNotEmpty) {
            final fusion =
                const ImportQuestionFusionCoordinator().fuseTextAndVision(
              textQuestions: singleFileQuestions,
              visionQuestions: visionResult.questions,
              sourceName: sourceName,
            );
            singleFileQuestions = fusion.questions;
            allWarnings.addAll(fusion.warnings);
            allDiagnostics.addAll(fusion.diagnostics);
          }

          if (visionResult.warnings.isNotEmpty) {
            allWarnings.addAll(visionResult.warnings);
          }
          if (visionResult.diagnostics.isNotEmpty) {
            parsedDoc.diagnostics['mixedVisionDiagnostics'] =
                visionResult.diagnostics;
          }
          if (visionResult.metadata.isNotEmpty) {
            parsedDoc.diagnostics['mixedVisionMetadata'] =
                visionResult.metadata;
          }
          allDiagnostics[sourceName] = parsedDoc.toDiagnostics();
        }
      }

      if (singleFileQuestions.isNotEmpty) {
        fileResults.add(singleFileQuestions);
      }
    }

    if (fileResults.length > 1 && !hasStrictDocxRoute && !hasBlockedParse) {
      TaskManager.instance.updateProgress(taskId, '启动 AI 结构化交叉配对引擎...', 0.9);
      final merged =
          await AiService.instance.mergeStructuredQuestions(fileResults);
      return ImportParseResult(
        questions: merged,
        warnings: allWarnings,
        diagnostics: allDiagnostics,
      );
    } else if (fileResults.isNotEmpty) {
      final flattenedQuestions = fileResults.expand((e) => e).toList();
      return ImportParseResult(
        questions: flattenedQuestions,
        warnings: allWarnings,
        diagnostics: allDiagnostics,
        blocked: hasBlockedParse,
        blockReason: _readBlockReason(allDiagnostics),
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
      );
    }
  }

  String? _readBlockReason(Map<String, dynamic> diagnostics) {
    final gate = diagnostics['qualityGate'];
    if (gate is Map) {
      return (gate['reason']?.toString() ??
          gate['severity']?.toString());
    }
    return null;
  }
}
