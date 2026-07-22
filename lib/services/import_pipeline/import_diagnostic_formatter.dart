import 'import_diagnostic_message.dart';
import '../task_manager.dart';
import 'import_diagnostic_summary.dart';

class ImportDiagnosticFormatter {
  static List<ImportDiagnosticMessage> format({
    List<String>? warnings,
    Map<String, dynamic>? diagnostics,
  }) {
    final List<ImportDiagnosticMessage> messages = [];

    // 1. Process top-level warnings
    if (warnings != null) {
      for (final warning in warnings) {
        if (warning.trim().isNotEmpty) {
          messages.add(ImportDiagnosticMessage(
            severity: ImportDiagnosticSeverity.warning,
            title: '解析警告',
            message: warning,
            source: 'pipeline',
          ));
        }
      }
    }

    if (diagnostics == null || diagnostics.isEmpty) {
      return messages;
    }

    final Set<List> processedLists = {};

    // Helper to add a diagnostic message safely
    void addDiagnostic({
      required ImportDiagnosticSeverity severity,
      required String title,
      required String message,
      String? source,
      String? code,
    }) {
      messages.add(ImportDiagnosticMessage(
        severity: severity,
        title: title,
        message: message,
        source: source,
        code: code,
      ));
    }

    // Helper to find maps by key prefix recursively
    List<Map> findMapsByKey(Map map, bool Function(String) predicate) {
      final List<Map> results = [];
      for (final entry in map.entries) {
        final key = entry.key.toString();
        if (predicate(key) && entry.value is Map) {
          results.add(entry.value as Map);
        }
        if (entry.value is Map) {
          results.addAll(findMapsByKey(entry.value as Map, predicate));
        }
      }
      return results;
    }

    // Helper to find specific keys recursively
    List<dynamic> findValuesByKey(Map map, String targetKey) {
      final List<dynamic> results = [];
      for (final entry in map.entries) {
        if (entry.key.toString() == targetKey) {
          results.add(entry.value);
        }
        if (entry.value is Map) {
          results.addAll(findValuesByKey(entry.value as Map, targetKey));
        }
      }
      return results;
    }

    // 2. Fallback Used / Fallback Reason
    final fallbackReasons = findValuesByKey(diagnostics, 'fallbackReason');
    for (final reason in fallbackReasons) {
      if (reason != null && reason.toString().trim().isNotEmpty) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.warning,
          title: '解析降级',
          message: reason.toString(),
          source: 'adapter',
          code: 'FALLBACK',
        );
      }
    }

    // 3. PDF Render Diagnostics
    final pdfMaps =
        findMapsByKey(diagnostics, (k) => k.startsWith('pdf_render'));
    for (final pdfMap in pdfMaps) {
      final status = pdfMap['status']?.toString();
      final error = pdfMap['error']?.toString();
      if (status == 'crash' || error != null) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.error,
          title: 'PDF 渲染失败',
          message: error ?? 'PDF 页面渲染崩溃，已降级',
          source: 'pdf_renderer',
          code: 'PDF_RENDER_CRASH',
        );
      }
      if (pdfMap['warnings'] is List) {
        final list = pdfMap['warnings'] as List;
        processedLists.add(list);
        for (final w in list) {
          addDiagnostic(
            severity: ImportDiagnosticSeverity.warning,
            title: 'PDF 渲染警告',
            message: w.toString(),
            source: 'pdf_renderer',
          );
        }
      }
    }

    // 4. Vision Batch Diagnostics
    final visionMaps =
        findMapsByKey(diagnostics, (k) => k.startsWith('vision_batch'));
    for (final visionMap in visionMaps) {
      final failedCount = visionMap['failedBatchCount'] as int? ?? 0;
      final totalCount = visionMap['totalBatches'] as int? ?? 0;
      if (failedCount > 0) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.error,
          title: '视觉解析批次失败',
          message: '共 $totalCount 个批次中，有 $failedCount 个批次解析失败。',
          source: 'vision_coordinator',
          code: 'VISION_BATCH_FAILED',
        );
      }
      if (visionMap['errors'] is List) {
        final list = visionMap['errors'] as List;
        processedLists.add(list);
        for (final e in list) {
          addDiagnostic(
            severity: ImportDiagnosticSeverity.warning,
            title: '视觉批次错误记录',
            message: e.toString(),
            source: 'vision_coordinator',
          );
        }
      }
    }

    // 5. Mixed Vision metadata/diagnostics
    final mixedMaps = findMapsByKey(diagnostics,
        (k) => k.startsWith('mixed_vision') || k == 'mixedVisionMetadata');
    for (final mvMap in mixedMaps) {
      final total = mvMap['totalAssets'] ?? mvMap['total'] ?? 0;
      final resolvable = mvMap['resolvableAssets'] ?? mvMap['resolvable'] ?? 0;
      final unresolvable =
          mvMap['unresolvableAssets'] ?? mvMap['unresolvable'] ?? 0;
      final missing = mvMap['missingPathsCount'] ?? mvMap['missing'] ?? 0;
      final sent = mvMap['sentCount'] ?? mvMap['sent'] ?? 0;

      addDiagnostic(
        severity: ImportDiagnosticSeverity.info,
        title: '混合视觉资源统计',
        message:
            '文档共包含图片 $total 张，其中可解析 $resolvable 张，未解析 $unresolvable 张，缺失 $missing 张，已发送大模型 $sent 张。',
        source: 'mixed_vision',
        code: 'MIXED_VISION_STATS',
      );
    }

    // Process mixedVisionDiagnostics list if present
    final mixedVisionLists =
        findValuesByKey(diagnostics, 'mixedVisionDiagnostics')
            .whereType<List>();
    for (final list in mixedVisionLists) {
      processedLists.add(list);
      for (final item in list) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.info,
          title: '混合视觉诊断',
          message: item.toString(),
          source: 'mixed_vision',
        );
      }
    }

    // 6. Generic errors in diagnostics (nested search)
    final errorsLists =
        findValuesByKey(diagnostics, 'errors').whereType<List>();
    for (final errList in errorsLists) {
      if (processedLists.contains(errList)) continue;
      processedLists.add(errList);
      for (final e in errList) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.error,
          title: '错误诊断',
          message: e.toString(),
          source: 'pipeline',
        );
      }
    }

    // 7. Generic warnings in diagnostics (nested search)
    final warningsLists =
        findValuesByKey(diagnostics, 'warnings').whereType<List>();
    for (final warnList in warningsLists) {
      if (processedLists.contains(warnList)) continue;
      processedLists.add(warnList);
      for (final w in warnList) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.warning,
          title: '警告诊断',
          message: w.toString(),
          source: 'pipeline',
        );
      }
    }

    // 8. Unresolved images list (nested search)
    final unresolvedImagesLists =
        findValuesByKey(diagnostics, 'unresolvedImages').whereType<List>();
    for (final list in unresolvedImagesLists) {
      if (processedLists.contains(list)) continue;
      processedLists.add(list);
      if (list.isNotEmpty) {
        addDiagnostic(
          severity: ImportDiagnosticSeverity.warning,
          title: '未解析图片资源',
          message: '以下图片路径无法解析，将降级处理：\n${list.join('\n')}',
          source: 'adapter',
          code: 'UNRESOLVED_IMAGES',
        );
      }
    }

    return messages;
  }

  static final _technicalFieldWhitelist = {
    'status',
    'sourceName',
    'format',
    'provider',
    'model',
    'pageCount',
    'blockCount',
    'totalPages',
    'batchCount',
    'failedBatchCount',
    'totalBatches',
    'expectedCount',
    'actualCount',
    'completionRate',
    'total',
    'riskyCount',
    'lowQualityFileCount',
    'answerCount',
    'questionCount',
    'repairCount',
    'rejectedCount',
  };

  static ImportDiagnosticSummary summarize(ImportTask task) {
    final outcome = task.status == TaskStatus.processing
        ? ImportTaskOutcome.processing
        : (task.errorMsg != null
            ? ImportTaskOutcome.failure
            : (task.parsedData?.isEmpty ?? true)
                ? ImportTaskOutcome.emptyResult
                : ImportTaskOutcome.success);

    String outcomeLabel;
    switch (outcome) {
      case ImportTaskOutcome.success:
        outcomeLabel = '解析成功';
        break;
      case ImportTaskOutcome.emptyResult:
        outcomeLabel = '无有效提取内容';
        break;
      case ImportTaskOutcome.failure:
        outcomeLabel = '解析失败';
        break;
      case ImportTaskOutcome.processing:
        outcomeLabel = '正在解析...';
        break;
    }

    final mode = task.parseMode ?? 'text';
    final traceId = task.traceId;
    final elapsed = task.elapsed;
    final diags = task.diagnostics ?? const {};

    String? lastSuccessStage;
    String? failedStage;
    String? errorType;
    bool suggestRetry = false;
    String? userGuidance;

    // Extract whitelist fields
    final Map<String, String> extractedFields = {};
    void traverseAndExtract(Map<String, dynamic> data, [String prefix = '']) {
      for (final entry in data.entries) {
        if (entry.key == TaskManager.keyTraceId ||
            entry.key == TaskManager.keyParseMode) continue;

        if (entry.value is Map<String, dynamic>) {
          traverseAndExtract(entry.value as Map<String, dynamic>,
              prefix.isEmpty ? entry.key : '$prefix.${entry.key}');
        } else if (_technicalFieldWhitelist.contains(entry.key)) {
          extractedFields[prefix.isEmpty ? entry.key : '$prefix.${entry.key}'] =
              entry.value.toString();
        }
      }
    }

    traverseAndExtract(diags);

    // Stage logic
    if (mode == 'ocr') {
      final ocrStatus = _findNestedString(diags, 'status');
      if (ocrStatus == 'attempted' || ocrStatus == 'used_ocr') {
        lastSuccessStage = 'OCR 引擎请求';
      } else if (ocrStatus == 'failed_no_question_regions') {
        failedStage = '题目区域识别阶段 / Regionizer';
        userGuidance = 'OCR 已返回文字，但未能识别到有效题目区域。请确保文档包含清晰可见的题目排版或更换排版规范的文档后重试。';
        suggestRetry = true;
      } else if (ocrStatus != null && ocrStatus.startsWith('failed_')) {
        failedStage = 'OCR 请求阶段';
        userGuidance = '建议检查网络连接或更换 OCR 引擎。';
        suggestRetry = true;
      }
      if (diags.containsKey('qualityGate')) {
        lastSuccessStage = '质量门禁';
      } else if (outcome == ImportTaskOutcome.emptyResult &&
          failedStage == null) {
        failedStage = '提取阶段';
        userGuidance = 'OCR 成功但未能提取出任何有效题目，建议尝试视觉模式或检查原图清晰度。';
        suggestRetry = true;
      }
    } else if (mode == 'vision') {
      final pdfCrash = _findNestedString(diags, 'status') == 'crash';
      if (pdfCrash) {
        failedStage = 'PDF 渲染';
        userGuidance = 'PDF 渲染失败，可能是由于文件损坏或加密导致，建议导出为图片后重试。';
      } else {
        lastSuccessStage = 'PDF 渲染 / 文件准备';
      }

      final failedBatches = _findNestedInt(diags, 'failedBatchCount') ?? 0;
      if (failedBatches > 0) {
        failedStage = '视觉批次解析';
        userGuidance = '部分视觉批次失败，建议重试。';
        suggestRetry = true;
      }

      if (outcome == ImportTaskOutcome.emptyResult && failedStage == null) {
        failedStage = '提取阶段';
        userGuidance = '未能提取出有效题目，建议检查图片内容是否包含规范题型。';
      }
    } else {
      if (outcome == ImportTaskOutcome.emptyResult) {
        failedStage = '文字检测';
        userGuidance = '未能检测到有效的文字题型标识。如果文档包含较多图片或排版复杂，建议尝试“OCR 模式”或“视觉模式”。';
      } else if (outcome == ImportTaskOutcome.success) {
        lastSuccessStage = '本地解析与组题';
      }
    }

    if (task.errorMsg != null) {
      errorType = task.errorMsg!.split(':').first;
      if (errorType!.length > 50) {
        errorType = errorType!.substring(0, 50) + '...';
      }
    }

    return ImportDiagnosticSummary(
      outcome: outcome,
      outcomeLabel: outcomeLabel,
      parseMode: mode,
      traceId: traceId,
      elapsed: elapsed,
      lastSuccessStage: lastSuccessStage,
      failedStage: failedStage,
      errorType: errorType,
      suggestRetry: suggestRetry,
      userGuidance: userGuidance,
      details: format(warnings: task.warnings, diagnostics: task.diagnostics),
      technicalFields: extractedFields,
    );
  }

  static String? _findNestedString(Map<String, dynamic> data, String key) {
    if (data.containsKey(key) && data[key] is String)
      return data[key] as String;
    for (final v in data.values) {
      if (v is Map<String, dynamic>) {
        final res = _findNestedString(v, key);
        if (res != null) return res;
      }
    }
    return null;
  }

  static int? _findNestedInt(Map<String, dynamic> data, String key) {
    if (data.containsKey(key) && data[key] is int) return data[key] as int;
    for (final v in data.values) {
      if (v is Map<String, dynamic>) {
        final res = _findNestedInt(v, key);
        if (res != null) return res;
      }
    }
    return null;
  }
}
