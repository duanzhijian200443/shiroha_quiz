import '../../services/task_manager.dart';

enum TaskCenterCategory {
  processing,
  pendingReview,
  completed,
  error,
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
