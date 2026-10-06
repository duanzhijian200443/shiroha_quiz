import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../dependencies/task_center_dependencies.dart';
import '../task_center/task_center_controller.dart';
import '../task_center/task_center_components.dart';
import '../task_center/task_center_detail_sheet.dart';
import '../home/today_visual_theme.dart';
import '../theme/design_tokens.dart';

class TaskCenterScreen extends StatefulWidget {
  const TaskCenterScreen(
      {super.key,
      this.dependencies,
      this.refreshInterval = const Duration(seconds: 3),
      this.localize});
  final TaskCenterDependencies? dependencies;
  final Duration refreshInterval;
  final DateTime Function(DateTime)? localize;
  @override
  State<TaskCenterScreen> createState() => _TaskCenterScreenState();
}

class _TaskCenterScreenState extends State<TaskCenterScreen>
    with WidgetsBindingObserver {
  TaskCenterController? _controller;
  bool _foreground = true, _covered = false;
  int _messageRevision = 0;
  bool _detailOpen = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final ports = widget.dependencies;
    if (ports != null) {
      _controller = TaskCenterController(ports,
          refreshInterval: widget.refreshInterval,
          routeVisible: () =>
              mounted &&
              _foreground &&
              !_covered &&
              ModalRoute.of(context)?.isCurrent == true)
        ..addListener(_changed)
        ..setVisible(true);
      unawaited(_controller!.load());
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final controller = _controller!;
    if (controller.messageRevision != _messageRevision) {
      _messageRevision = controller.messageRevision;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(controller.message!)));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _controller?.setVisible(_foreground && !_covered);
    if (_foreground && !_covered) unawaited(_controller?.load());
  }

  Future<T> _cover<T>(Future<T> Function() action) async {
    _covered = true;
    _controller?.setVisible(false);
    try {
      return await action();
    } finally {
      _covered = false;
      if (mounted) _controller?.setVisible(_foreground);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ?..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _controller?.load();
  }

  Future<bool> _confirm(String title, String body) async =>
      await _cover<bool?>(() => showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(body), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确定')),
              ]))) ??
      false;
  Future<void> _action(TaskCenterItem item, TaskCenterAction action) async {
    if (action == TaskCenterAction.delete &&
        !await _confirm('删除任务记录', '仅删除解析任务记录，不影响已经保存的题库。')) {
      return;
    }
    if (!mounted) return;
    Future<void> act() async => _controller?.act(item, action,
        present: (request) =>
            _cover(() => widget.dependencies!.openReview(context, request)));
    if (action == TaskCenterAction.retry) {
      await _cover(act);
    } else {
      await act();
    }
  }

  Future<void> _details(TaskCenterItem item) async {
    if (_detailOpen || !mounted) return;
    _detailOpen = true;
    try {
      final theme = todayVisualTheme(Theme.of(context));
      await _cover(() => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: theme.colorScheme.surface,
          constraints:
              const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
          builder: (context) => Theme(
              data: theme,
              child: TaskCenterDetailSheet(
                  taskId: item.target.taskId,
                  query: widget.dependencies!.query,
                  localize: widget.localize))));
    } finally {
      _detailOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
        data: todayVisualTheme(Theme.of(context)),
        child: Builder(builder: _page));
  }

  Widget _page(BuildContext context) {
    final controller = _controller;
    final loading = controller?.phase == TaskCenterLoadPhase.loading;
    final unavailable = controller == null ||
        controller.phase == TaskCenterLoadPhase.unavailable;
    final selected = controller?.selected ?? TaskCenterCoarseStatus.inProgress;
    final items = controller?.items ?? <TaskCenterItem>[];
    return Scaffold(
        appBar: AppBar(
            leading: const BackButton(),
            backgroundColor: Colors.transparent,
            scrolledUnderElevation: 0,
            actions: [
              PopupMenuButton<String>(
                  key: const ValueKey('task-center-page-menu'),
                  tooltip: '更多操作',
                  enabled: controller != null && !controller.cleanupBusy,
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (_) => controller?.cleanup((count) => _confirm(
                      '清理已完成记录', '清理 $count 条记录。仅删除解析任务记录，不影响已经保存的题库。')),
                  itemBuilder: (_) => const [
                        PopupMenuItem(value: 'clear', child: Text('清理已完成记录'))
                      ])
            ]),
        body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
                constraints: const BoxConstraints(
                    maxWidth: DesignTokens.contentMaxWidth),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const TaskCenterHeader(),
                                TaskCenterTabs(
                                    selected: selected,
                                    counts: {
                                      for (final status
                                          in TaskCenterCoarseStatus.values)
                                        status: controller?.snapshot == null
                                            ? null
                                            : controller!.count(status)
                                    },
                                    onSelect: (status) =>
                                        controller?.selectTab(status)),
                              ])),
                      if (loading ||
                          controller?.phase == TaskCenterLoadPhase.refreshing)
                        const LinearProgressIndicator(),
                      Expanded(
                          child: RefreshIndicator(
                              onRefresh: _refresh,
                              child: ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 6, 16, 24),
                                  children: [
                                    if (unavailable)
                                      Column(children: [
                                        const Icon(Icons.cloud_off_outlined,
                                            size: 42),
                                        const Text('任务暂不可用'),
                                        TextButton(
                                            onPressed: controller == null
                                                ? null
                                                : _refresh,
                                            child: const Text('重试'))
                                      ]),
                                    if (!unavailable &&
                                        !loading &&
                                        items.isEmpty)
                                      Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 40),
                                          child: Column(children: [
                                            Icon(taskCenterTabIcon(selected),
                                                size: 48),
                                            const SizedBox(height: 16),
                                            Text(const [
                                              '暂无正在解析的任务',
                                              '暂无待校对任务',
                                              '暂无已完成记录',
                                              '暂无异常任务'
                                            ][selected.index]),
                                            const SizedBox(height: 8),
                                            const Text('新导入的文件会显示在这里'),
                                            if (selected !=
                                                    TaskCenterCoarseStatus
                                                        .pendingReview &&
                                                (controller.count(
                                                        TaskCenterCoarseStatus
                                                            .pendingReview)) >
                                                    0)
                                              TextButton(
                                                  onPressed: () =>
                                                      controller.selectTab(
                                                          TaskCenterCoarseStatus
                                                              .pendingReview),
                                                  child: Text(
                                                      '还有 ${controller.count(TaskCenterCoarseStatus.pendingReview)} 个任务等待校对，去处理')),
                                          ])),
                                    for (final item in items)
                                      TaskCenterTaskCard(
                                          item: item,
                                          localize: widget.localize,
                                          busy: controller!.cleanupBusy ||
                                              controller.pendingTaskIds
                                                  .contains(item.target.taskId),
                                          onDetail: () => _details(item),
                                          onAction: (action) =>
                                              _action(item, action)),
                                  ]))),
                    ]))));
  }
}
