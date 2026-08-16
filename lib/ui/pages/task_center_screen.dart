import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/observability/diagnostic_summary.dart';
import '../../services/import_pipeline/import_diagnostic_message.dart';
import '../../services/import_pipeline/import_diagnostic_formatter.dart';
import '../../services/import_pipeline/import_diagnostic_summary.dart';
import '../../services/import_pipeline/import_task_coordinator.dart';
import '../../services/task_manager.dart';
import '../dependencies/ai_dependencies_scope.dart';
import 'import_staging_screen.dart';
import 'task_center_projection.dart';

typedef TaskReviewPageBuilder = Widget Function(
  BuildContext context,
  ImportTask task,
);

typedef TaskCenterRetryFilePicker = Future<FilePickerResult?> Function();

class TaskCenterScreen extends StatefulWidget {
  const TaskCenterScreen({
    super.key,
    this.onOpenReview,
    this.reviewPageBuilder,
    this.taskManager,
    this.taskCoordinator,
    this.retryFilePicker,
  });

  final ValueChanged<ImportTask>? onOpenReview;
  final TaskReviewPageBuilder? reviewPageBuilder;
  final TaskManager? taskManager;
  final ImportTaskCoordinator? taskCoordinator;
  final TaskCenterRetryFilePicker? retryFilePicker;

  @override
  State<TaskCenterScreen> createState() => _TaskCenterScreenState();
}

class _TaskCenterScreenState extends State<TaskCenterScreen> {
  TaskCenterCategory _selectedCategory = TaskCenterCategory.processing;
  final Set<String> _pendingActionTaskIds = <String>{};

  TaskManager get _taskManager => widget.taskManager ?? TaskManager.instance;

  ImportTaskCoordinator _taskCoordinator(BuildContext context) {
    return widget.taskCoordinator ??
        AiDependenciesScope.of(context).importTaskCoordinator;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('传输与解析中心',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => _taskManager.clearCompletedTasks(),
            tooltip: '清理已完成',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedBuilder(
          animation: _taskManager,
          builder: (context, _) {
            final tasks = _taskManager.tasks;
            final projection = TaskCenterProjection.fromTasks(tasks);
            final visibleTasks = projection.tasksFor(_selectedCategory);

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: _TaskCategorySelector(
                    selected: _selectedCategory,
                    counts: <TaskCenterCategory, int>{
                      for (final category in TaskCenterCategory.values)
                        category: projection.countFor(category),
                    },
                    onSelected: (category) {
                      if (_selectedCategory == category) return;
                      setState(() => _selectedCategory = category);
                    },
                  ),
                ),
                Expanded(
                  child: visibleTasks.isEmpty
                      ? _TaskCategoryEmptyState(category: _selectedCategory)
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: visibleTasks.length,
                          findChildIndexCallback: (key) {
                            if (key is! ValueKey<String> ||
                                !key.value.startsWith('import-task-')) {
                              return null;
                            }
                            final taskId =
                                key.value.substring('import-task-'.length);
                            final index = visibleTasks
                                .indexWhere((task) => task.id == taskId);
                            return index == -1 ? null : index;
                          },
                          itemBuilder: (context, index) {
                            return _buildTaskCard(
                              context,
                              visibleTasks[index],
                            );
                          },
                        ),
                ),
              ],
            );
          }),
    );
  }

  Widget _buildTaskCard(BuildContext context, ImportTask task) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final summary = ImportDiagnosticFormatter.summarize(task);
    final statusColor = _statusColor(task.status);
    final progress = task.percent.clamp(0.0, 1.0).toDouble();
    final presentation = TaskCenterProjection.presentationFor(task);
    final actionPending = _pendingActionTaskIds.contains(task.id);
    // OBS-1: the diagnostic affordance only appears for strictly valid
    // correlation ids (fixed OBS-XXXX-XXXX format).
    final correlationId = task.correlationId;
    final hasValidDiagnosticId = correlationId != null &&
        DiagnosticSummaryFormatter.isValidDiagnosticId(correlationId);

    return Card(
      key: ValueKey<String>('import-task-${task.id}'),
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? Colors.white10 : Colors.grey.withValues(alpha: 0.2),
        ),
      ),
      color: theme.cardTheme.color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            task.status == TaskStatus.processing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Icon(
                    _statusIcon(task.status),
                    color: statusColor,
                    size: 26,
                  ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: theme.textTheme.bodyLarge?.color,
                          ),
                        ),
                      ),
                      if (presentation.canDelete) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          key: ValueKey<String>('task-delete-${task.id}'),
                          onPressed: actionPending
                              ? null
                              : () => _taskManager.deleteTask(task.id),
                          icon: const Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.grey,
                          ),
                          tooltip: '删除${task.title}',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _TaskStatusBadge(
                    label: presentation.statusLabel,
                    color: statusColor,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _safeCardSummary(task, summary, presentation),
                    key: ValueKey<String>('task-summary-${task.id}'),
                    style: TextStyle(
                      color: task.status == TaskStatus.error
                          ? Colors.redAccent
                          : Colors.grey,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Trace ID: ${task.traceId ?? "不可用"}',
                    key: ValueKey<String>('task-trace-${task.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (task.status == TaskStatus.error &&
                      hasValidDiagnosticId) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '诊断编号：$correlationId',
                            key:
                                ValueKey<String>('task-correlation-${task.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          key: ValueKey<String>(
                            'task-copy-diagnostic-${task.id}',
                          ),
                          onPressed: () => _copyImportDiagnostic(task),
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          tooltip: '复制诊断信息',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ],
                  if (task.status == TaskStatus.processing) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 6,
                        backgroundColor: Colors.grey.withValues(alpha: 0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.blueAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${(progress * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                    if (task.pendingChunks != null ||
                        task.failedChunks != null) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (task.pendingChunks != null)
                            Text(
                              '待解析: ${task.pendingChunks!.length} 批次',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          if (task.failedChunks?.isNotEmpty ?? false)
                            Text(
                              '失败: ${task.failedChunks!.length} 批次',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.redAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                  if (task.status == TaskStatus.pendingReview &&
                      task.warnings?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text(
                      '解析完成，但有 ${task.warnings!.length} 条注意事项',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Semantics(
                        button: true,
                        label: '查看${task.title}诊断',
                        child: TextButton.icon(
                          key: ValueKey<String>(
                            'task-diagnostics-${task.id}',
                          ),
                          onPressed: () => _showDiagnosticsSheet(context, task),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(48, 32),
                            foregroundColor: task.status == TaskStatus.error
                                ? Colors.redAccent
                                : theme.primaryColor,
                          ),
                          icon: const Icon(Icons.info_outline, size: 16),
                          label: const Text(
                            '查看诊断',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (task.status == TaskStatus.pendingReview &&
                          task.parsedData != null)
                        Semantics(
                          button: true,
                          label: '打开${task.title}校对',
                          child: FilledButton.tonalIcon(
                            key: ValueKey<String>('task-review-${task.id}'),
                            onPressed: () => _openReview(context, task),
                            icon: const Icon(Icons.rule_rounded, size: 16),
                            label: const Text('去校对'),
                          ),
                        ),
                      if (presentation.canCancel ||
                          presentation.isCancellationPending)
                        OutlinedButton.icon(
                          key: ValueKey<String>('task-cancel-${task.id}'),
                          onPressed: actionPending ||
                                  presentation.isCancellationPending
                              ? null
                              : () => _cancelOcrTask(task.id),
                          icon:
                              const Icon(Icons.stop_circle_outlined, size: 16),
                          label: Text(
                            presentation.isCancellationPending || actionPending
                                ? '取消中'
                                : '取消任务',
                          ),
                        ),
                      if (presentation.canRetry)
                        FilledButton.tonalIcon(
                          key: ValueKey<String>('task-retry-${task.id}'),
                          onPressed: actionPending
                              ? null
                              : () => _retryOcrTask(task.id),
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: Text(
                            actionPending ? '选择文件中' : '重新选择文件重试',
                          ),
                        ),
                      if ((task.status == TaskStatus.error ||
                              task.status == TaskStatus.processing) &&
                          (task.pendingChunks?.isNotEmpty ?? false) &&
                          !presentation.canRetry)
                        OutlinedButton(
                          onPressed: () {
                            AiDependenciesScope.of(context)
                                .aiService
                                .resumeTask(task.id);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('正在从断点恢复解析...'),
                              ),
                            );
                          },
                          child: const Text('断点重试'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelOcrTask(String taskId) async {
    if (!_beginTaskAction(taskId)) return;
    try {
      final status = await _taskCoordinator(context).cancelOcrTask(taskId);
      if (!mounted) return;
      final message = switch (status) {
        ImportAttemptWriteStatus.applied => '已提交取消请求',
        ImportAttemptWriteStatus.persistenceFailed => '取消状态保存失败，请稍后重试',
        ImportAttemptWriteStatus.stale ||
        ImportAttemptWriteStatus.taskMissing ||
        ImportAttemptWriteStatus.invalidState =>
          '任务状态已变化，请刷新后重试',
      };
      _showSafeActionMessage(message);
    } catch (_) {
      _showSafeActionMessage('无法取消任务，请稍后重试');
    } finally {
      _finishTaskAction(taskId);
    }
  }

  Future<void> _retryOcrTask(String taskId) async {
    if (!_beginTaskAction(taskId)) return;
    try {
      final result = await (widget.retryFilePicker?.call() ??
          FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const <String>['pdf', 'png', 'jpg', 'jpeg'],
            allowMultiple: true,
          ));
      if (!mounted || result == null || result.files.isEmpty) return;

      final currentTask = _taskForId(taskId);
      if (currentTask == null ||
          !TaskCenterProjection.presentationFor(currentTask).canRetry) {
        _showSafeActionMessage('任务状态已变化，请刷新后重试');
        return;
      }

      final filePaths = <String>[];
      final fileNames = <String>[];
      for (final file in result.files) {
        final path = file.path?.trim();
        if (path == null || path.isEmpty) {
          _showSafeActionMessage('所选文件不可用，请重新选择');
          return;
        }
        filePaths.add(path);
        fileNames.add(file.name);
      }

      await _taskCoordinator(context).retryOcrRequest(
        taskId: taskId,
        filePaths: filePaths,
        fileNames: fileNames,
      );
      _showSafeActionMessage('任务已重新排队');
    } on ImportTaskRetryRejectedException {
      _showSafeActionMessage('任务状态已变化，请刷新后重试');
    } on ImportTaskCoordinatorDependencyException {
      _showSafeActionMessage('重试暂不可用，请稍后再试');
    } catch (_) {
      _showSafeActionMessage('无法重试任务，请稍后再试');
    } finally {
      _finishTaskAction(taskId);
    }
  }

  bool _beginTaskAction(String taskId) {
    if (_pendingActionTaskIds.contains(taskId)) return false;
    setState(() => _pendingActionTaskIds.add(taskId));
    return true;
  }

  void _finishTaskAction(String taskId) {
    if (!mounted || !_pendingActionTaskIds.contains(taskId)) return;
    setState(() => _pendingActionTaskIds.remove(taskId));
  }

  ImportTask? _taskForId(String taskId) {
    for (final task in _taskManager.tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  void _showSafeActionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openReview(BuildContext context, ImportTask task) {
    final callback = widget.onOpenReview;
    if (callback != null) {
      callback(task);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (routeContext) {
          final pageBuilder = widget.reviewPageBuilder;
          if (pageBuilder != null) {
            return pageBuilder(routeContext, task);
          }
          return ImportStagingScreen(
            taskId: task.id,
            parsedQuestions: task.parsedData!,
            warnings: task.warnings,
            diagnostics: task.diagnostics,
            initialExplanationRetentionMode: task.explanationRetentionMode,
          );
        },
      ),
    );
  }

  String _safeCardSummary(
    ImportTask task,
    ImportDiagnosticSummary summary,
    TaskCenterTaskPresentation presentation,
  ) {
    final override = presentation.summaryOverride;
    if (override != null) return override;
    switch (task.status) {
      case TaskStatus.processing:
        return task.progressText;
      case TaskStatus.pendingReview:
        final warningCount = task.warnings?.length ?? 0;
        return warningCount == 0 ? '解析完成，等待校对' : '共有 $warningCount 条注意事项需要校对';
      case TaskStatus.completed:
        return '任务已完成';
      case TaskStatus.error:
        final guidance = summary.userGuidance?.trim();
        if (guidance != null && guidance.isNotEmpty) return guidance;
        final failedStage = summary.failedStage?.trim();
        if (failedStage != null && failedStage.isNotEmpty) {
          return '失败阶段：$failedStage';
        }
        final structuredErrorType =
            task.diagnostics?['errorType']?.toString().trim();
        if (structuredErrorType != null && structuredErrorType.isNotEmpty) {
          return '异常类型：$structuredErrorType';
        }
        return '导入失败，请查看诊断信息';
    }
  }

  Color _statusColor(TaskStatus status) {
    return switch (status) {
      TaskStatus.processing => Colors.blueAccent,
      TaskStatus.pendingReview => Colors.orange,
      TaskStatus.completed => Colors.green,
      TaskStatus.error => Colors.redAccent,
    };
  }

  IconData _statusIcon(TaskStatus status) {
    return switch (status) {
      TaskStatus.processing => Icons.sync,
      TaskStatus.pendingReview => Icons.rule_rounded,
      TaskStatus.completed => Icons.check_circle,
      TaskStatus.error => Icons.error_rounded,
    };
  }

  void _showDiagnosticsSheet(BuildContext context, ImportTask task) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ImportTaskDiagnosticSheet(task: task),
    );
  }

  /// OBS-1: copies only the whitelist diagnostic summary of a failed Import
  /// attempt. Never copies messages, tool payloads, RAG content, provider
  /// bodies, paths or stacks.
  Future<void> _copyImportDiagnostic(ImportTask task) async {
    final correlationId = task.correlationId;
    if (correlationId == null) return;
    final summary = DiagnosticSummary(
      diagnosticId: correlationId,
      operation: 'import_attempt',
      failure: task.diagnostics?['errorType']?.toString(),
      status: 'failed',
      taskId: task.id,
      attemptNumber: task.attemptNumber,
      traceId: task.traceId,
    );
    final text = DiagnosticSummaryFormatter.format(summary);
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showSafeActionMessage('诊断信息已复制');
  }
}

class _TaskCategorySelector extends StatelessWidget {
  const _TaskCategorySelector({
    required this.selected,
    required this.counts,
    required this.onSelected,
  });

  final TaskCenterCategory selected;
  final Map<TaskCenterCategory, int> counts;
  final ValueChanged<TaskCenterCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: TaskCenterCategory.values.map((category) {
          final isSelected = category == selected;
          final label = switch (category) {
            TaskCenterCategory.processing => '进行中',
            TaskCenterCategory.pendingReview => '待校对',
            TaskCenterCategory.completed => '已完成',
            TaskCenterCategory.error => '异常',
          };
          return Expanded(
            child: InkWell(
              key: ValueKey<String>('task-category-${category.name}'),
              onTap: () => onSelected(category),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$label（${counts[category] ?? 0}）',
                    style: TextStyle(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _TaskCategoryEmptyState extends StatelessWidget {
  const _TaskCategoryEmptyState({required this.category});

  final TaskCenterCategory category;

  @override
  Widget build(BuildContext context) {
    final message = switch (category) {
      TaskCenterCategory.processing => '当前没有正在导入的文件',
      TaskCenterCategory.pendingReview => '当前没有等待校对的任务',
      TaskCenterCategory.completed => '暂无已完成的导入任务',
      TaskCenterCategory.error => '没有解析失败的任务',
    };
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 72,
            color: Colors.grey.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskStatusBadge extends StatelessWidget {
  const _TaskStatusBadge({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
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

  Duration get _taskElapsed => widget.task.elapsed;

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
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
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
                            '${msg.source != null ? "来源: ${msg.source!}" : ""}'
                            '${msg.source != null && msg.code != null ? " | " : ""}'
                            '${msg.code != null ? "代码: ${msg.code!}" : ""}',
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
          }),
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
