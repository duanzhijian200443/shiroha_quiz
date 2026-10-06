import 'package:flutter/material.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../theme/design_tokens.dart';
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
    taskCenterAttemptLabel(item.coarseStatus, item.attemptStatus);
String taskCenterAttemptLabel(
        TaskCenterCoarseStatus coarse, TaskCenterAttemptStatus? attempt) =>
    switch (attempt) {
      TaskCenterAttemptStatus.queued => '排队中',
      TaskCenterAttemptStatus.running => '进行中',
      TaskCenterAttemptStatus.cancelRequested => '取消中',
      TaskCenterAttemptStatus.cancelled => '已取消',
      TaskCenterAttemptStatus.interrupted => '已中断',
      TaskCenterAttemptStatus.failed => '解析失败',
      _ => taskCenterTabLabel(coarse),
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
        final colors = Theme.of(context).colorScheme;
        final style =
            Theme.of(context).textTheme.labelMedium!.copyWith(fontSize: 12);
        final widths = <TaskCenterCoarseStatus, double>{};
        for (final status in TaskCenterCoarseStatus.values) {
          final painter = TextPainter(
              text: TextSpan(
                  text:
                      '${taskCenterTabLabel(status)} ${counts[status] ?? '—'}',
                  style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context))
            ..layout();
          widths[status] = (painter.width + 34).clamp(48, double.infinity);
          painter.dispose();
        }
        final total = widths.values.reduce((a, b) => a + b);
        final available = constraints.maxWidth - 8;
        final fits = total <= available;
        return Material(
            color: colors.surface,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
                padding: const EdgeInsets.all(4),
                child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final status in TaskCenterCoarseStatus.values)
                        SizedBox(
                            width: widths[status]! +
                                (fits ? (available - total) / 4 : 0),
                            child: Semantics(
                                selected: selected == status,
                                button: true,
                                child: Material(
                                    color: selected == status
                                        ? colors.onSurface.withValues(alpha: .8)
                                        : colors.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    child: InkWell(
                                        key: ValueKey(
                                            'task-category-${status.name}'),
                                        onTap: () => onSelect(status),
                                        borderRadius: BorderRadius.circular(16),
                                        child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                minHeight: 48),
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 10),
                                                child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                          taskCenterTabIcon(
                                                              status),
                                                          size: 16,
                                                          color: selected ==
                                                                  status
                                                              ? colors.surface
                                                              : colors
                                                                  .onSurfaceVariant),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                          '${taskCenterTabLabel(status)} ${counts[status] ?? '—'}',
                                                          style: style.copyWith(
                                                              color: selected ==
                                                                      status
                                                                  ? colors
                                                                      .surface
                                                                  : colors
                                                                      .onSurfaceVariant)),
                                                    ]))))))),
                    ]))));
      });
}

class TaskCenterHeader extends StatelessWidget {
  const TaskCenterHeader({super.key});
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final colors = Theme.of(context).colorScheme;
        final decorate = constraints.maxWidth >= 340 &&
            MediaQuery.textScalerOf(context).scale(16) <= 21;
        return SizedBox(
            width: double.infinity,
            child: Stack(children: [
              if (decorate)
                Positioned(
                    right: 0,
                    top: 0,
                    child: TaskCenterDocumentArt(
                        color: colors.onSurfaceVariant, size: 120)),
              Padding(
                  padding: EdgeInsets.only(
                      top: 6, bottom: 22, right: decorate ? 108 : 0),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('解析任务',
                            style: Theme.of(context)
                                .textTheme
                                .headlineLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text('查看文件解析与校对进度',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant)),
                      ])),
            ]));
      });
}

/// Local, decorative vector only; excluded from hit testing and semantics.
class TaskCenterDocumentArt extends StatelessWidget {
  const TaskCenterDocumentArt(
      {super.key, required this.color, required this.size});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: ExcludeSemantics(
          child: SizedBox.square(
              dimension: size,
              child: CustomPaint(painter: _DocumentPainter(color)))));
}

class _DocumentPainter extends CustomPainter {
  const _DocumentPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120, size.height / 120);
    canvas.drawOval(const Rect.fromLTWH(2, 20, 115, 90),
        Paint()..color = color.withValues(alpha: .035));
    canvas.save();
    canvas.translate(40, 8);
    canvas.rotate(.25);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(0, 0, 66, 88), const Radius.circular(8)),
        Paint()..color = color.withValues(alpha: .08));
    final pen = Paint()
      ..color = color.withValues(alpha: .16)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      canvas.drawLine(
          Offset(13, 21 + i * 13), Offset(i == 3 ? 36 : 49, 21 + i * 13), pen);
    }
    canvas.restore();
    final glass = Paint()
      ..color = color.withValues(alpha: .3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(const Offset(91, 76), 17, glass);
    canvas.drawLine(const Offset(103, 89), const Offset(115, 103), glass);
    final leaf = Paint()..color = color.withValues(alpha: .17);
    canvas.drawOval(const Rect.fromLTWH(8, 62, 13, 29), leaf);
    canvas.drawOval(const Rect.fromLTWH(22, 81, 21, 11), leaf);
  }

  @override
  bool shouldRepaint(_DocumentPainter oldDelegate) =>
      oldDelegate.color != color;
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
    final statusColor = item.coarseStatus == TaskCenterCoarseStatus.error
        ? colors.error
        : colors.onSurfaceVariant;
    final actions = item.actions;
    return Card(
        key: ValueKey('import-task-${item.target.taskId}'),
        elevation: 2,
        surfaceTintColor: Colors.transparent,
        shadowColor: colors.shadow.withValues(alpha: .07),
        margin: const EdgeInsets.only(bottom: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DesignTokens.cardRadius + 6),
            side:
                BorderSide(color: colors.outlineVariant.withValues(alpha: .5))),
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
                                    color: colors.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(12)),
                                child: Icon(Icons.description_outlined,
                                    color: colors.onSurfaceVariant)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(item.fileDisplayName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 8),
                                  Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 9, vertical: 4),
                                      decoration: BoxDecoration(
                                          color: statusColor.withValues(
                                              alpha: .08),
                                          borderRadius:
                                              BorderRadius.circular(16)),
                                      child: Text(taskCenterStatusLabel(item),
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(color: statusColor))),
                                ])),
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
                      _TaskFactLine(
                          icon: Icons.article_outlined,
                          text: taskCenterSummary(item)),
                      const SizedBox(height: 8),
                      _TaskFactLine(
                          icon: Icons.calendar_today_outlined,
                          text: formatTaskCenterEventTime(item.eventTime,
                              localize: localize)),
                      if (item.attemptStatus ==
                              TaskCenterAttemptStatus.running ||
                          item.attemptStatus ==
                              TaskCenterAttemptStatus.cancelRequested)
                        const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: LinearProgressIndicator()),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: colors.outlineVariant),
                      const SizedBox(height: 8),
                      SizedBox(
                          width: double.infinity,
                          child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                TextButton.icon(
                                    key: ValueKey(
                                        'task-details-${item.target.taskId}'),
                                    style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                        foregroundColor:
                                            colors.onSurfaceVariant),
                                    onPressed: onDetail,
                                    icon: const Icon(Icons.info_outline_rounded,
                                        size: 20),
                                    label: const Text('查看详情')),
                                if (actions.review)
                                  FilledButton.tonalIcon(
                                      key: ValueKey(
                                          'task-review-${item.target.taskId}'),
                                      style: FilledButton.styleFrom(
                                          minimumSize: const Size(104, 48),
                                          backgroundColor: colors.onSurface
                                              .withValues(alpha: .8),
                                          foregroundColor: colors.surface,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(18))),
                                      onPressed: busy
                                          ? null
                                          : () =>
                                              onAction(TaskCenterAction.review),
                                      icon: const Icon(Icons.edit_note_rounded),
                                      label: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text('去校对'),
                                            SizedBox(width: 4),
                                            Icon(Icons.chevron_right_rounded,
                                                size: 18)
                                          ])),
                                if (actions.retry)
                                  FilledButton.tonalIcon(
                                      key: ValueKey(
                                          'task-retry-${item.target.taskId}'),
                                      style: FilledButton.styleFrom(
                                          minimumSize: const Size(104, 48),
                                          backgroundColor: colors.onSurface
                                              .withValues(alpha: .8),
                                          foregroundColor: colors.surface,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(18))),
                                      onPressed: busy
                                          ? null
                                          : () =>
                                              onAction(TaskCenterAction.retry),
                                      icon: const Icon(Icons.replay_rounded),
                                      label: const Text('重试')),
                                if (actions.cancel)
                                  TextButton(
                                      key: ValueKey(
                                          'task-cancel-${item.target.taskId}'),
                                      onPressed: busy
                                          ? null
                                          : () =>
                                              onAction(TaskCenterAction.cancel),
                                      child: const Text('取消')),
                              ])),
                    ]))));
  }
}

class _TaskFactLine extends StatelessWidget {
  const _TaskFactLine({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon,
            size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5))),
      ]);
}
