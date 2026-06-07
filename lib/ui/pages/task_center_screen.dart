import 'package:flutter/material.dart';
import '../../services/task_manager.dart';
import '../../services/ai_service.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_diagnostic_formatter.dart';
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
                                            AiService.instance.resumeTask(t.id);
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
                                if (t.status == TaskStatus.error &&
                                    (t.warnings?.isNotEmpty == true ||
                                        t.diagnostics?.isNotEmpty == true)) ...[
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: () =>
                                          _showDiagnosticsSheet(context, t),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 28),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        foregroundColor: Colors.redAccent,
                                      ),
                                      icon: const Icon(Icons.info_outline,
                                          size: 16),
                                      label: const Text('查看详细诊断原因',
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

class _ImportTaskDiagnosticSheet extends StatelessWidget {
  final ImportTask task;

  const _ImportTaskDiagnosticSheet({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = ImportDiagnosticFormatter.format(
      warnings: task.warnings,
      diagnostics: task.diagnostics,
    );

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
            task.title,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          if (messages.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('无可用诊断信息', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
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
                                color: theme.textTheme.bodyMedium?.color,
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
