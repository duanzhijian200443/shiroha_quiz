import 'package:flutter/material.dart';
import '../../application/task_center/task_center_contracts.dart';
import 'task_center_controller.dart';

String taskCenterTabLabel(TaskCenterCoarseStatus status) =>
    const ['进行中', '待校对', '已完成', '异常'][status.index];
IconData taskCenterTabIcon(TaskCenterCoarseStatus status) => const [
      Icons.sync_rounded,
      Icons.edit_note_rounded,
      Icons.check_circle_outline_rounded,
      Icons.warning_amber_rounded
    ][status.index];
String taskCenterStatusLabel(TaskCenterItem item) =>
    switch (item.attemptStatus) {
      TaskCenterAttemptStatus.queued => '排队中',
      TaskCenterAttemptStatus.running => '进行中',
      TaskCenterAttemptStatus.cancelRequested => '取消中',
      TaskCenterAttemptStatus.cancelled => '已取消',
      TaskCenterAttemptStatus.interrupted => '已中断',
      TaskCenterAttemptStatus.failed => '解析失败',
      _ => taskCenterTabLabel(item.coarseStatus),
    };
String taskCenterSummary(TaskCenterItem item) {
  final count = item.counts.questionCount;
  final warnings = item.counts.warningCount;
  if (count != null && warnings != null && warnings > 0) {
    return '已识别 $count 道题 · $warnings 项需要确认';
  }
  if (count != null) {
    return '已识别 $count 道题${item.coarseStatus == TaskCenterCoarseStatus.pendingReview ? '，等待校对' : ''}';
  }
  if (warnings != null && warnings > 0) {
    return '共有 $warnings 项需要确认';
  }
  return switch (item.coarseStatus) {
    TaskCenterCoarseStatus.inProgress => '任务正在处理',
    TaskCenterCoarseStatus.pendingReview => '解析完成，等待校对',
    TaskCenterCoarseStatus.completed => '任务已完成',
    TaskCenterCoarseStatus.error => '查看任务状态，选择可用操作',
  };
}

String formatTaskCenterEventTime(TaskCenterEventTime event,
    {DateTime Function(DateTime)? localize}) {
  final prefix = switch (event.kind) {
    TaskCenterEventKind.queuedAt => '排队',
    TaskCenterEventKind.startedAt => '开始',
    TaskCenterEventKind.parsedAt => '解析完成',
    TaskCenterEventKind.completedAt => '完成',
    TaskCenterEventKind.failedAt => '失败',
    null => ''
  };
  if (event.utcSeconds == null) {
    return prefix.isEmpty ? '时间未记录' : '$prefix时间未记录';
  }
  final utc = DateTime.fromMillisecondsSinceEpoch(event.utcSeconds! * 1000,
      isUtc: true);
  final time = (localize ?? (t) => t.toLocal())(utc);
  String two(int n) => n.toString().padLeft(2, '0');
  return '$prefix于 ${time.year.toString().padLeft(4, '0')}.${two(time.month)}.${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

class TaskCenterTabs extends StatelessWidget {
  const TaskCenterTabs(
      {super.key,
      required this.selected,
      required this.counts,
      required this.onSelect});
  final TaskCenterCoarseStatus selected;
  final Map<TaskCenterCoarseStatus, int?> counts;
  final ValueChanged<TaskCenterCoarseStatus> onSelect;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 500 &&
            MediaQuery.textScalerOf(context).scale(14) < 20;
        return Wrap(spacing: 6, runSpacing: 6, children: [
          for (final status in TaskCenterCoarseStatus.values)
            SizedBox(
                width:
                    (constraints.maxWidth - (wide ? 18 : 6)) / (wide ? 4 : 2),
                child: Semantics(
                    selected: selected == status,
                    button: true,
                    child: Material(
                        color: selected == status
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                            key: ValueKey('task-category-${status.name}'),
                            onTap: () => onSelect(status),
                            borderRadius: BorderRadius.circular(14),
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(children: [
                                  Icon(taskCenterTabIcon(status), size: 20),
                                  const SizedBox(width: 6),
                                  Flexible(
                                      child: Text(
                                          '${taskCenterTabLabel(status)} ${counts[status] ?? '—'}'))
                                ]))))))
        ]);
      });
}

class TaskCenterTaskCard extends StatelessWidget {
  const TaskCenterTaskCard(
      {super.key,
      required this.item,
      required this.busy,
      required this.onDetail,
      required this.onAction,
      this.localize});
  final TaskCenterItem item;
  final bool busy;
  final VoidCallback onDetail;
  final ValueChanged<TaskCenterAction> onAction;
  final DateTime Function(DateTime)? localize;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (item.coarseStatus) {
      TaskCenterCoarseStatus.inProgress ||
      TaskCenterCoarseStatus.completed =>
        colors.onPrimaryContainer,
      TaskCenterCoarseStatus.pendingReview =>
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xffcfb57b)
            : const Color(0xff927239),
      TaskCenterCoarseStatus.error => colors.error,
    };
    final actions = item.actions;
    return Card(
        key: ValueKey('import-task-${item.target.taskId}'),
        elevation: 1,
        shadowColor: colors.shadow.withValues(alpha: .07),
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: InkWell(
            onTap: onDetail,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                    color: colors.primaryContainer
                                        .withValues(alpha: .5),
                                    borderRadius: BorderRadius.circular(12)),
                                child: Icon(Icons.description_outlined,
                                    color: colors.onSurfaceVariant)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: InkWell(
                                    onTap: onDetail,
                                    child: Text(item.fileDisplayName,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w600)))),
                            PopupMenuButton<TaskCenterAction>(
                                key:
                                    ValueKey('task-menu-${item.target.taskId}'),
                                tooltip: '更多操作',
                                enabled: !busy,
                                onSelected: onAction,
                                itemBuilder: (_) => [
                                      if (actions.retry)
                                        const PopupMenuItem(
                                            value: TaskCenterAction.retry,
                                            child: Text('重新解析')),
                                      if (actions.cancel)
                                        const PopupMenuItem(
                                            value: TaskCenterAction.cancel,
                                            child: Text('取消任务')),
                                      if (actions.delete)
                                        const PopupMenuItem(
                                            value: TaskCenterAction.delete,
                                            child: Text('删除任务记录'))
                                    ],
                                icon: const Icon(Icons.more_horiz_rounded)),
                          ]),
                      const SizedBox(height: 12),
                      Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: .09),
                              borderRadius: BorderRadius.circular(10)),
                          child: Text(taskCenterStatusLabel(item),
                              style: TextStyle(color: statusColor))),
                      const SizedBox(height: 10),
                      Text(taskCenterSummary(item)),
                      const SizedBox(height: 8),
                      Text(
                          formatTaskCenterEventTime(item.eventTime,
                              localize: localize),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                      if (item.attemptStatus ==
                              TaskCenterAttemptStatus.running ||
                          item.attemptStatus ==
                              TaskCenterAttemptStatus.cancelRequested)
                        const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: LinearProgressIndicator()),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                                key: ValueKey(
                                    'task-details-${item.target.taskId}'),
                                style: TextButton.styleFrom(
                                    foregroundColor: colors.onSurfaceVariant),
                                onPressed: onDetail,
                                icon: const Icon(Icons.info_outline_rounded,
                                    size: 20),
                                label: const Text('查看详情')),
                            if (actions.review)
                              FilledButton.tonalIcon(
                                  key: ValueKey(
                                      'task-review-${item.target.taskId}'),
                                  style: FilledButton.styleFrom(
                                      backgroundColor: colors.primaryContainer,
                                      foregroundColor:
                                          colors.onPrimaryContainer),
                                  onPressed: busy
                                      ? null
                                      : () => onAction(TaskCenterAction.review),
                                  icon: const Icon(Icons.edit_note_rounded),
                                  label: const Text('去校对')),
                            if (actions.retry)
                              FilledButton.tonalIcon(
                                  key: ValueKey(
                                      'task-retry-${item.target.taskId}'),
                                  style: FilledButton.styleFrom(
                                      backgroundColor: colors.primaryContainer,
                                      foregroundColor:
                                          colors.onPrimaryContainer),
                                  onPressed: busy
                                      ? null
                                      : () => onAction(TaskCenterAction.retry),
                                  icon: const Icon(Icons.replay_rounded),
                                  label: const Text('重试')),
                            if (actions.cancel)
                              TextButton(
                                  key: ValueKey(
                                      'task-cancel-${item.target.taskId}'),
                                  onPressed: busy
                                      ? null
                                      : () => onAction(TaskCenterAction.cancel),
                                  child: const Text('取消')),
                          ]),
                    ]))));
  }
}
