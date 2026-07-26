import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/task_manager.dart';
import '../dependencies/ai_dependencies_scope.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_diagnostic_formatter.dart';
import '../../services/import_pipeline/import_diagnostic_summary.dart';
import 'import_staging_screen.dart';

class TaskCenterScreen extends StatelessWidget {
  const TaskCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('传输与解析中心',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => TaskManager.instance.clearCompletedTasks(),
            tooltip: '清理已完成',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedBuilder(
          animation: TaskManager.instance,
          builder: (context, _) {
            final tasks = TaskManager.instance.tasks;
            if (tasks.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.inbox_rounded,
                        size: 80, color: Colors.grey.withValues(alpha: 0.3)),
                    const SizedBox(height: 16),
                    const Text('当前没有后台任务',
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('所有的解析和下载记录将显示在这里',
                        style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: tasks.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String> ||
                    !key.value.startsWith('import-task-')) {
                  return null;
                }
                final taskId = key.value.substring('import-task-'.length);
                final index = tasks.indexWhere((task) => task.id == taskId);
                return index == -1 ? null : index;
              },
              itemBuilder: (context, index) {
                final t = tasks[index];
                IconData icon = Icons.sync;
                Color iconColor = Colors.blueAccent;

                if (t.status == TaskStatus.completed) {
                  icon = Icons.check_circle;
                  iconColor = Colors.green;
                } else if (t.status == TaskStatus.error) {
                  icon = Icons.error_rounded;
                  iconColor = Colors.redAccent;
                } else if (t.status == TaskStatus.pendingReview) {
                  icon = Icons.rule_rounded;
                  iconColor = Colors.orange;
                }

                return Card(
                  key: ValueKey<String>('import-task-${t.id}'),
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: isDark
                              ? Colors.white10
                              : Colors.grey.withValues(alpha: 0.2))),
                  color: theme.cardTheme.color,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: t.status == TaskStatus.pendingReview &&
                            t.parsedData != null
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ImportStagingScreen(
                                  taskId: t.id,
                                  parsedQuestions: t.parsedData!,
                                  warnings: t.warnings,
                                  diagnostics: t.diagnostics,
                                ),
                              ),
                            );
                          }
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          t.status == TaskStatus.processing
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5))
                              : Icon(icon, color: iconColor, size: 26),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                        child: Text(t.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 15,
                                                color: theme.textTheme.bodyLarge
                                                    ?.color))),
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: () {
                                        TaskManager.instance.deleteTask(t.id);
                                      },
                                      borderRadius: BorderRadius.circular(12),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4.0),
                                        child: Icon(Icons.close,
                                            size: 18, color: Colors.grey),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (t.status == TaskStatus.processing) ...[
                                  ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                          value: t.percent,
                                          minHeight: 6,
                                          backgroundColor: Colors.grey
                                              .withValues(alpha: 0.2),
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                  Color>(Colors.blueAccent))),
                                  const SizedBox(height: 8),
                                  if (t.pendingChunks != null ||
                                      t.failedChunks != null) ...[
                                    Row(
                                      children: [
                                        if (t.pendingChunks != null)
                                          Text(
                                              '待解析: ${t.pendingChunks!.length} 批次',
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey)),
                                        if (t.pendingChunks != null &&
                                            t.failedChunks != null)
                                          const SizedBox(width: 12),
                                        if (t.failedChunks != null &&
                                            t.failedChunks!.isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.redAccent
                                                  .withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                                '失败: ${t.failedChunks!.length} 批次',
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.redAccent,
                                                    fontWeight:
                                                        FontWeight.bold)),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        t.status == TaskStatus.error
                                            ? (t.errorMsg ?? '未知错误')
                                            : t.progressText,
                                        style: TextStyle(
                                            color: t.status == TaskStatus.error
                                                ? Colors.redAccent
                                                : (t.status ==
                                                        TaskStatus.pendingReview
                                                    ? Colors.orange
                                                    : Colors.grey),
                                            fontSize: 13,
                                            height: 1.4,
                                            fontWeight: t.status ==
                                                    TaskStatus.pendingReview
                                                ? FontWeight.bold
                                                : FontWeight.normal),
                                      ),
                                    ),
                                    if ((t.status == TaskStatus.error ||
                                            t.status ==
                                                TaskStatus.processing) &&
                                        (t.pendingChunks?.isNotEmpty ?? false))
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 8.0),
                                        child: OutlinedButton(
                                          onPressed: () {
                                            AiDependenciesScope.of(context)
                                                .aiService
                                                .resumeTask(t.id);
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(const SnackBar(
                                                    content:
                                                        Text('正在从断点恢复解析...')));
                                          },
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 0),
                                            minimumSize: const Size(0, 28),
                                          ),
                                          child: const Text('断点重试',
                                              style: TextStyle(fontSize: 12)),
                                        ),
                                      ),
                                  ],
                                ),
                                if (t.status == TaskStatus.pendingReview &&
                                    t.warnings != null &&
                                    t.warnings!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.orange.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: Colors.orange
                                              .withValues(alpha: 0.2)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.warning_amber_rounded,
                                            size: 16, color: Colors.orange),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '解析完成，但有 ${t.warnings!.length} 条注意事项',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.orange,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                ...[
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      key: ValueKey('task-diagnostics-${t.id}'),
                                      onPressed: () =>
                                          _showDiagnosticsSheet(context, t),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 28),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        foregroundColor:
                                            t.status == TaskStatus.error
                                                ? Colors.redAccent
                                                : theme.primaryColor,
                                      ),
                                      icon: const Icon(Icons.info_outline,
                                          size: 16),
                                      label: const Text('查看诊断',
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (t.status == TaskStatus.pendingReview)
                            const Padding(
                              padding: EdgeInsets.only(left: 8.0, top: 4),
                              child: Icon(Icons.arrow_forward_ios_rounded,
                                  size: 14, color: Colors.orange),
                            )
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          }),
    );
  }

  void _showDiagnosticsSheet(BuildContext context, ImportTask task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ImportTaskDiagnosticSheet(task: task),
    );
  }
}

class _ImportTaskDiagnosticSheet extends StatefulWidget {
  final ImportTask task;

  const _ImportTaskDiagnosticSheet({required this.task});

  @override
  State<_ImportTaskDiagnosticSheet> createState() =>
      _ImportTaskDiagnosticSheetState();
}

class _ImportTaskDiagnosticSheetState
    extends State<_ImportTaskDiagnosticSheet> {
  bool _isTechnicalDetailsExpanded = false;

  String get _taskStatusLabel => switch (widget.task.status) {
        TaskStatus.processing => '正在解析',
        TaskStatus.pendingReview => '等待用户校对',
        TaskStatus.completed => '成功完成',
        TaskStatus.error => '解析失败',
      };

  Duration get _taskElapsed {
    final end = widget.task.completedAt ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: (end - widget.task.createdAt).clamp(0, 1 << 31));
  }

  Future<void> _copyTraceId(String traceId) async {
    await Clipboard.setData(ClipboardData(text: traceId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trace ID 已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = ImportDiagnosticFormatter.summarize(widget.task);

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '解析诊断报告',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: theme.textTheme.titleLarge?.color,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.task.title,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSummaryCard(theme, summary),
                  const SizedBox(height: 24),
                  _buildTechnicalDetailsToggle(theme),
                  if (_isTechnicalDetailsExpanded)
                    _buildTechnicalDetails(theme, summary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme, ImportDiagnosticSummary summary) {
    Color statusColor;
    IconData statusIcon;

    switch (widget.task.status) {
      case TaskStatus.completed:
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
        break;
      case TaskStatus.pendingReview:
        statusColor = Colors.orange;
        statusIcon = Icons.rule_rounded;
        break;
      case TaskStatus.error:
        statusColor = Colors.redAccent;
        statusIcon = Icons.error_rounded;
        break;
      case TaskStatus.processing:
        statusColor = Colors.blue;
        statusIcon = Icons.hourglass_top_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _taskStatusLabel,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          _buildMetadataRow(
            label: 'Trace ID',
            value: summary.traceId ?? '不可用',
            trailing: summary.traceId == null
                ? null
                : IconButton(
                    key: ValueKey('copy-trace-${widget.task.id}'),
                    onPressed: () => _copyTraceId(summary.traceId!),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: '复制 Trace ID',
                    visualDensity: VisualDensity.compact,
                  ),
          ),
          _buildMetadataRow(
            label: '解析模式',
            value: summary.parseMode ?? '不可用',
          ),
          _buildMetadataRow(label: '任务状态', value: _taskStatusLabel),
          _buildMetadataRow(
            label: '导入耗时',
            value: '${_taskElapsed.inSeconds}s',
          ),
          if (summary.lastSuccessStage != null ||
              summary.failedStage != null) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            if (summary.lastSuccessStage != null)
              _buildStageRow(Icons.check_circle_outline, Colors.green, '最后成功阶段',
                  summary.lastSuccessStage!),
            if (summary.failedStage != null)
              _buildStageRow(Icons.error_outline, Colors.redAccent, '失败阶段',
                  summary.failedStage!),
          ],
          if (summary.errorType != null) ...[
            const SizedBox(height: 8),
            _buildStageRow(Icons.bug_report_outlined, Colors.redAccent, '异常类型',
                summary.errorType!),
          ],
          if (summary.userGuidance != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline,
                      color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary.userGuidance!,
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStageRow(
      IconData icon, Color color, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text('$label: ',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataRow({
    required String label,
    required String value,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildTechnicalDetailsToggle(ThemeData theme) {
    return InkWell(
      onTap: () {
        setState(() {
          _isTechnicalDetailsExpanded = !_isTechnicalDetailsExpanded;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Row(
          children: [
            Text(
              '技术诊断详情',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: theme.textTheme.titleMedium?.color,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _isTechnicalDetailsExpanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              color: Colors.grey,
            ),
            const Expanded(child: Divider(indent: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildTechnicalDetails(
      ThemeData theme, ImportDiagnosticSummary summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.technicalFields.isNotEmpty) ...[
          const Text('关键指标:',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: summary.technicalFields.entries.map((e) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(e.key,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(e.value,
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (summary.details.isNotEmpty) ...[
          const Text('详细日志:',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...summary.details.map((msg) {
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
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          msg.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          msg.message,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.textTheme.bodyMedium?.color,
                          ),
                        ),
                        if (msg.source != null || msg.code != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${msg.source != null ? "来源: " + msg.source! : ""}'
                            '${msg.source != null && msg.code != null ? " | " : ""}'
                            '${msg.code != null ? "代码: " + msg.code! : ""}',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ] else if (summary.technicalFields.isEmpty && summary.traceId == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('无技术诊断信息', style: TextStyle(color: Colors.grey)),
            ),
          ),
      ],
    );
  }
}
