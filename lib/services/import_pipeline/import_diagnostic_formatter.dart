import 'import_diagnostic_message.dart';

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
}
