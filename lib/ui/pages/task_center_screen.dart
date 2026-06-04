import 'package:flutter/material.dart';
import '../../services/task_manager.dart';
import '../../services/ai_service.dart';
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
                        size: 80, color: Colors.grey.withOpacity(0.3)),
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
                } // 待校对图标

                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: isDark
                              ? Colors.white10
                              : Colors.grey.withOpacity(0.2))),
                  color: theme.cardTheme.color,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: t.status == TaskStatus.pendingReview &&
                            t.parsedData != null
                        ? () {
                            // 点击待校对任务，弹出暂存区
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ImportStagingScreen(
                                  taskId: t.id,
                                  parsedQuestions: t.parsedData!,
                                ),
                              ),
                            ).then((_) {
                              // 返回后我们先不强制删掉任务，等待真入库（若用户真入库，可在暂存区调用 completeTask 或此处判断）
                            });
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
                                          backgroundColor:
                                              Colors.grey.withOpacity(0.2),
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                  Color>(Colors.blueAccent))),
                                  const SizedBox(height: 8),
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
}
