import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/home_training_result.dart';
import '../../application/task_center/task_center_contracts.dart';
import 'task_center_components.dart';

String formatTaskCenterDuration(int? seconds) {
  if (seconds == null) return '未记录';
  final hours = seconds ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) return '$hours 小时 $minutes 分 $remainder 秒';
  if (minutes > 0) return '$minutes 分 $remainder 秒';
  return '$remainder 秒';
}

/// Read-only route with its own query lifetime. Dismissed/disposed queries
/// cannot reopen a route or publish into another task's detail.
class TaskCenterDetailSheet extends StatefulWidget {
  const TaskCenterDetailSheet(
      {super.key, required this.taskId, required this.query, this.localize});
  final String taskId;
  final TaskCenterQuery query;
  final DateTime Function(DateTime)? localize;
  @override
  State<TaskCenterDetailSheet> createState() => _TaskCenterDetailSheetState();
}

class _TaskCenterDetailSheetState extends State<TaskCenterDetailSheet> {
  late final Future<HomeTrainingResult<TaskCenterDetail>> _result = _load();
  Future<HomeTrainingResult<TaskCenterDetail>> _load() async {
    try {
      final result = await widget.query.detail(widget.taskId);
      if (result case HomeTrainingSuccess(:final value)) {
        if (value.taskId != widget.taskId) {
          return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
        }
      }
      return result;
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  Future<void> _copy(String trace) async {
    try {
      await Clipboard.setData(ClipboardData(text: trace));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Trace ID 已复制')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('复制暂不可用')));
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
          key: const ValueKey('task-center-detail-sheet'),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: FutureBuilder<HomeTrainingResult<TaskCenterDetail>>(
              future: _result,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()));
                }
                if (snapshot.data case HomeTrainingSuccess(:final value)) {
                  final colors = Theme.of(context).colorScheme;
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('任务详情',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 20),
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                      color: colors.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(14)),
                                  child: const Icon(Icons.description_outlined,
                                      size: 30)),
                              const SizedBox(width: 14),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(value.fileDisplayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                                fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 8),
                                    Text(
                                        taskCenterAttemptLabel(
                                            value.coarseStatus,
                                            value.attemptStatus),
                                        style: TextStyle(
                                            color: colors.onSurfaceVariant)),
                                  ])),
                            ]),
                        const SizedBox(height: 24),
                        _DetailFact(
                            label: '已识别题目',
                            value: value.counts.questionCount == null
                                ? '未记录'
                                : '${value.counts.questionCount} 道题'),
                        _DetailFact(
                            label: '待确认',
                            value: value.counts.warningCount == null
                                ? '未记录'
                                : '${value.counts.warningCount} 项'),
                        _DetailFact(
                            label: '事件时间',
                            value: formatTaskCenterEventTime(value.eventTime,
                                localize: widget.localize)),
                        _DetailFact(
                            label: '解析耗时',
                            value: formatTaskCenterDuration(
                                value.durationSeconds)),
                        Text('按记录事件时间计算：解析开始到结果发布',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant)),
                        const SizedBox(height: 20),
                        Divider(color: colors.outlineVariant),
                        const SizedBox(height: 16),
                        Text('Trace ID',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 4),
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      child: Text(value.traceId ?? '未记录',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                  color: colors
                                                      .onSurfaceVariant)))),
                              IconButton(
                                  key: const ValueKey('task-detail-copy-trace'),
                                  tooltip: value.traceId == null
                                      ? 'Trace ID 未记录'
                                      : '复制 Trace ID',
                                  onPressed: value.traceId == null
                                      ? null
                                      : () => _copy(value.traceId!),
                                  icon: const Icon(Icons.copy_outlined)),
                            ]),
                      ]);
                }
                return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('任务详情暂不可用')));
              })));
}

class _DetailFact extends StatelessWidget {
  const _DetailFact({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ]));
}
