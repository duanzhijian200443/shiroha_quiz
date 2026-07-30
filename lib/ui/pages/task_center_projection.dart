import '../../services/import_pipeline/import_attempt_context.dart';
import '../../services/task_manager.dart';

enum TaskCenterCategory {
  processing,
  pendingReview,
  completed,
  error,
}

class TaskCenterTaskPresentation {
  const TaskCenterTaskPresentation({
    required this.statusLabel,
    required this.canCancel,
    required this.isCancellationPending,
    required this.canRetry,
    required this.canDelete,
    this.summaryOverride,
  });

  final String statusLabel;
  final String? summaryOverride;
  final bool canCancel;
  final bool isCancellationPending;
  final bool canRetry;
  final bool canDelete;
}

class TaskCenterProjection {
  TaskCenterProjection._(List<ImportTask> tasks)
      : _orderedTasks = _orderTasks(tasks);

  factory TaskCenterProjection.fromTasks(List<ImportTask> tasks) {
    return TaskCenterProjection._(List<ImportTask>.of(tasks));
  }

  final List<ImportTask> _orderedTasks;

  static TaskCenterCategory categoryFor(TaskStatus status) {
    return switch (status) {
      TaskStatus.processing => TaskCenterCategory.processing,
      TaskStatus.pendingReview => TaskCenterCategory.pendingReview,
      TaskStatus.completed => TaskCenterCategory.completed,
      TaskStatus.error => TaskCenterCategory.error,
    };
  }

  static TaskCenterTaskPresentation presentationFor(ImportTask task) {
    final rawAttemptState =
        task.diagnostics?[TaskManager.keyAttemptState]?.toString();
    final hasDetailedAttemptState = ImportAttemptState.values.any(
      (state) => state.name == rawAttemptState,
    );
    final isOcrAttempt = task.parseMode == 'ocr' && hasDetailedAttemptState;

    if (!isOcrAttempt) {
      return TaskCenterTaskPresentation(
        statusLabel: _coarseStatusLabel(task.status),
        canCancel: false,
        isCancellationPending: false,
        canRetry: false,
        canDelete: true,
      );
    }

    final attemptState = task.attemptState;
    return TaskCenterTaskPresentation(
      statusLabel: switch (attemptState) {
        ImportAttemptState.queued => '排队中',
        ImportAttemptState.running => '进行中',
        ImportAttemptState.cancelRequested => '取消中',
        ImportAttemptState.cancelled => '已取消',
        ImportAttemptState.failed => '解析失败',
        ImportAttemptState.interrupted => '已中断',
        ImportAttemptState.readyForReview =>
          task.status == TaskStatus.completed ? '已完成' : '待校对',
      },
      summaryOverride: switch (attemptState) {
        ImportAttemptState.cancelRequested => '正在等待当前 OCR 请求结束',
        ImportAttemptState.cancelled => '任务已取消',
        ImportAttemptState.interrupted => '应用重启后任务已中断，请重新选择文件重试',
        _ => null,
      },
      canCancel: task.status == TaskStatus.processing &&
          (attemptState == ImportAttemptState.queued ||
              attemptState == ImportAttemptState.running),
      isCancellationPending: attemptState == ImportAttemptState.cancelRequested,
      canRetry: task.status == TaskStatus.error &&
          (attemptState == ImportAttemptState.cancelled ||
              attemptState == ImportAttemptState.failed ||
              attemptState == ImportAttemptState.interrupted),
      canDelete: attemptState != ImportAttemptState.queued &&
          attemptState != ImportAttemptState.running &&
          attemptState != ImportAttemptState.cancelRequested,
    );
  }

  static String _coarseStatusLabel(TaskStatus status) {
    return switch (status) {
      TaskStatus.processing => '进行中',
      TaskStatus.pendingReview => '待校对',
      TaskStatus.completed => '已完成',
      TaskStatus.error => '解析失败',
    };
  }

  int countFor(TaskCenterCategory category) {
    return _orderedTasks
        .where((task) => categoryFor(task.status) == category)
        .length;
  }

  List<ImportTask> tasksFor(TaskCenterCategory category) {
    return List<ImportTask>.unmodifiable(
      _orderedTasks.where((task) => categoryFor(task.status) == category),
    );
  }

  static List<ImportTask> _orderTasks(List<ImportTask> tasks) {
    final ordered = List<ImportTask>.of(tasks);
    final indicesByBatch = <String, List<int>>{};

    for (var index = 0; index < tasks.length; index++) {
      final batchId = tasks[index].batchId;
      if (batchId == null) continue;
      indicesByBatch.putIfAbsent(batchId, () => <int>[]).add(index);
    }

    for (final indices in indicesByBatch.values) {
      if (indices.length < 2) continue;
      final batchTasks = indices
          .map(
            (index) => (
              task: tasks[index],
              originalIndex: index,
            ),
          )
          .toList();
      batchTasks.sort((left, right) {
        final leftSelectionIndex = left.task.selectionIndex;
        final rightSelectionIndex = right.task.selectionIndex;
        if (leftSelectionIndex != null && rightSelectionIndex != null) {
          final comparison = leftSelectionIndex.compareTo(rightSelectionIndex);
          if (comparison != 0) return comparison;
        } else if (leftSelectionIndex != null) {
          return -1;
        } else if (rightSelectionIndex != null) {
          return 1;
        }
        return left.originalIndex.compareTo(right.originalIndex);
      });

      for (var offset = 0; offset < indices.length; offset++) {
        ordered[indices[offset]] = batchTasks[offset].task;
      }
    }

    return List<ImportTask>.unmodifiable(ordered);
  }
}
