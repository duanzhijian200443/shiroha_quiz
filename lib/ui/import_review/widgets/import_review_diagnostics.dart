import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/import_pipeline/import_diagnostic_message.dart';

/// Severity-coloured banner summarising the import diagnostics of this task.
///
/// Tapping "查看详情" reports the intent through [onShowDetails]; the page owns
/// the bottom sheet that shows the details.
class ImportReviewDiagnosticsBanner extends StatelessWidget {
  const ImportReviewDiagnosticsBanner({
    super.key,
    required this.messages,
    required this.onShowDetails,
  });

  final List<ImportDiagnosticMessage> messages;
  final VoidCallback onShowDetails;

  @override
  Widget build(BuildContext context) {
    final hasError =
        messages.any((m) => m.severity == ImportDiagnosticSeverity.error);
    final hasWarning =
        messages.any((m) => m.severity == ImportDiagnosticSeverity.warning);

    Color bannerBg;
    Color textAndIconColor;
    IconData bannerIcon;
    String bannerTitle;

    if (hasError) {
      bannerBg = Colors.redAccent.withValues(alpha: 0.1);
      textAndIconColor = Colors.redAccent;
      bannerIcon = Icons.error_outline_rounded;
      bannerTitle = '解析发生严重错误';
    } else if (hasWarning) {
      bannerBg = Colors.orangeAccent.withValues(alpha: 0.12);
      textAndIconColor = Colors.orange;
      bannerIcon = Icons.warning_amber_rounded;
      bannerTitle = '解析有注意事项';
    } else {
      bannerBg = Colors.blueAccent.withValues(alpha: 0.08);
      textAndIconColor = Colors.blueAccent;
      bannerIcon = Icons.info_outline_rounded;
      bannerTitle = '包含解析报告';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: bannerBg,
      child: Row(
        children: [
          Icon(bannerIcon, color: textAndIconColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$bannerTitle (${messages.length} 条记录)',
              style: TextStyle(
                color: textAndIconColor,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton(
            onPressed: onShowDetails,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              foregroundColor: textAndIconColor,
            ),
            child: const Row(
              children: [
                Text('查看详情',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                Icon(Icons.arrow_right, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Selectable import trace id with a copy-to-clipboard action.
class ImportReviewTraceBar extends StatelessWidget {
  const ImportReviewTraceBar({
    super.key,
    required this.traceId,
    required this.onCopy,
  });

  final String traceId;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).primaryColor.withValues(alpha: 0.06),
      child: Row(
        children: [
          Icon(Icons.hub_outlined,
              color: Theme.of(context).primaryColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              '导入追踪：$traceId',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            key: const ValueKey('copy-staging-trace'),
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: '复制 Trace ID',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Banner shown when the vision parse quality summary reports risky questions.
class ImportReviewVisionLowQualityBanner extends StatelessWidget {
  const ImportReviewVisionLowQualityBanner({
    super.key,
    required this.diagnostics,
  });

  final Map<String, dynamic>? diagnostics;

  @override
  Widget build(BuildContext context) {
    final summary = diagnostics?['visionQualitySummary'];
    if (summary is! Map) return const SizedBox.shrink();
    final issueSummary = _formatVisionIssueCounts(summary['issueCounts']);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.red.shade50,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.visibility_off, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '视觉解析质量偏低',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '建议人工复核，或切换更强视觉模型后重新导入。'
                  '风险题数：${summary['riskyCount'] ?? 0} / ${summary['total'] ?? 0}',
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
                if (issueSummary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    issueSummary,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner shown when the parser reported image/table blocks it cannot render
/// faithfully in this version.
class ImportReviewUnsupportedStructureBanner extends StatelessWidget {
  const ImportReviewUnsupportedStructureBanner({
    super.key,
    required this.diagnostics,
  });

  final Map<String, dynamic>? diagnostics;

  @override
  Widget build(BuildContext context) {
    final summary = diagnostics?['unsupportedStructureSummary'];
    final imageBlockCount = summary is Map ? summary['imageBlockCount'] : null;
    final tableBlockCount = summary is Map ? summary['tableBlockCount'] : null;
    final hasImage = imageBlockCount is int && imageBlockCount > 0;
    final hasTable = tableBlockCount is int && tableBlockCount > 0;
    final message = hasImage && hasTable
        ? '检测到图片和表格内容，当前版本尚不能完整呈现，请对照 PDF 校对。'
        : hasImage
            ? '检测到图片内容，但当前版本尚不能显示原图，请对照 PDF 校对。'
            : '检测到表格内容，当前可能以文本或 HTML 片段显示，请对照 PDF 校对。';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.orangeAccent.withValues(alpha: 0.12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-sheet content listing every import diagnostic message.
///
/// The page owns the sheet route; this widget only renders its content and pops
/// itself when the close button is pressed.
class ImportReviewDiagnosticsSheet extends StatelessWidget {
  const ImportReviewDiagnosticsSheet({
    super.key,
    required this.messages,
    required this.diagnostics,
  });

  final List<ImportDiagnosticMessage> messages;
  final Map<String, dynamic>? diagnostics;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '导入诊断详情',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (diagnostics != null &&
              diagnostics!.containsKey('rawTextPreview')) ...[
            ImportReviewRawTextPreviewCard(diagnostics: diagnostics!),
            const SizedBox(height: 16),
          ],
          Expanded(
            child: ListView.separated(
              itemCount: messages.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final msg = messages[index];
                IconData icon;
                Color color;
                switch (msg.severity) {
                  case ImportDiagnosticSeverity.error:
                    icon = Icons.error_outline_rounded;
                    color = Colors.redAccent;
                    break;
                  case ImportDiagnosticSeverity.warning:
                    icon = Icons.warning_amber_rounded;
                    color = Colors.orange;
                    break;
                  case ImportDiagnosticSeverity.info:
                    icon = Icons.info_outline_rounded;
                    color = Colors.blueAccent;
                    break;
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: color, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            msg.title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: color,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            msg.message,
                            style: TextStyle(
                              fontSize: 13,
                              color:
                                  Theme.of(context).textTheme.bodyMedium?.color,
                              height: 1.4,
                            ),
                          ),
                          if (msg.source != null || msg.code != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${msg.source != null ? "来源: ${msg.source}" : ""}'
                              '${msg.source != null && msg.code != null ? " | " : ""}'
                              '${msg.code != null ? "代码: ${msg.code}" : ""}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only preview of the raw extracted text kept in the import diagnostics.
class ImportReviewRawTextPreviewCard extends StatelessWidget {
  const ImportReviewRawTextPreviewCard({
    super.key,
    required this.diagnostics,
  });

  final Map<String, dynamic> diagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rawText = diagnostics['rawTextPreview'] as String;
    final length = diagnostics['rawTextLength'] ?? rawText.length;
    final lineCount =
        diagnostics['rawTextLineCount'] ?? rawText.split('\n').length;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.primaryColor.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.description_outlined,
                      color: theme.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '原始提取文本 (DOCX)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: theme.textTheme.titleMedium?.color,
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: rawText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制原始文本预览到剪贴板'),
                      backgroundColor: Colors.green,
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('复制原始文本预览'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(0, 28),
                  textStyle: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold),
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '字符数: $length | 行数: $lineCount',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Container(
            height: 100,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? Colors.black26
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                rawText,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String? _formatVisionIssueCounts(dynamic rawCounts) {
  if (rawCounts is! Map || rawCounts.isEmpty) return null;
  final entries = <MapEntry<String, int>>[];
  for (final entry in rawCounts.entries) {
    final count = _readPositiveInt(entry.value);
    if (count <= 0) continue;
    entries.add(MapEntry(entry.key.toString(), count));
  }
  if (entries.isEmpty) return null;

  entries.sort((a, b) => b.value.compareTo(a.value));
  final visible = entries.take(3).map((entry) {
    return '${_visionIssueLabel(entry.key)} ${entry.value}';
  }).join('，');
  return '主要风险：$visible';
}

int _readPositiveInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

String _visionIssueLabel(String code) {
  return switch (code) {
    'answer_leaked_to_content' => '答案混入题干',
    'missing_answer_or_explanation' => '缺少答案/解析',
    'type_options_mismatch' => '题型选项不匹配',
    'duplicate_q_num' => '重复题号',
    'q_num_drift' => '题号漂移',
    _ => code,
  };
}
