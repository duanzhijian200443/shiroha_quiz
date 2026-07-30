import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';

ImportTask _task(
  String id,
  TaskStatus status, {
  String? batchId,
  int? selectionIndex,
  String title = 'fixture.pdf',
}) {
  return ImportTask(
    id: id,
    title: title,
    status: status,
    diagnostics: <String, dynamic>{
      if (batchId != null) TaskManager.keyBatchId: batchId,
      if (selectionIndex != null) TaskManager.keySelectionIndex: selectionIndex,
    },
  );
}

void main() {
  test('maps detailed task states to the four presentation categories', () {
    expect(
      TaskCenterProjection.categoryFor(TaskStatus.processing),
      TaskCenterCategory.processing,
    );
    expect(
      TaskCenterProjection.categoryFor(TaskStatus.pendingReview),
      TaskCenterCategory.pendingReview,
    );
    expect(
      TaskCenterProjection.categoryFor(TaskStatus.completed),
      TaskCenterCategory.completed,
    );
    expect(
      TaskCenterProjection.categoryFor(TaskStatus.error),
      TaskCenterCategory.error,
    );
  });

  test('derives category counts without changing task state', () {
    final tasks = <ImportTask>[
      _task('processing', TaskStatus.processing),
      _task('review', TaskStatus.pendingReview),
      _task('completed', TaskStatus.completed),
      _task('error', TaskStatus.error),
    ];

    final projection = TaskCenterProjection.fromTasks(tasks);

    expect(projection.countFor(TaskCenterCategory.processing), 1);
    expect(projection.countFor(TaskCenterCategory.pendingReview), 1);
    expect(projection.countFor(TaskCenterCategory.completed), 1);
    expect(projection.countFor(TaskCenterCategory.error), 1);
    expect(
      tasks.map((task) => task.status),
      <TaskStatus>[
        TaskStatus.processing,
        TaskStatus.pendingReview,
        TaskStatus.completed,
        TaskStatus.error,
      ],
    );
  });

  test('orders a batch by selection index regardless of completion order', () {
    final projection = TaskCenterProjection.fromTasks(<ImportTask>[
      _task(
        'third',
        TaskStatus.completed,
        batchId: 'batch-a',
        selectionIndex: 2,
      ),
      _task(
        'first',
        TaskStatus.completed,
        batchId: 'batch-a',
        selectionIndex: 0,
      ),
      _task(
        'second',
        TaskStatus.completed,
        batchId: 'batch-a',
        selectionIndex: 1,
      ),
    ]);

    expect(
      projection.tasksFor(TaskCenterCategory.completed).map((task) => task.id),
      <String>['first', 'second', 'third'],
    );
  });

  test('pending review moves to completed without changing task identity', () {
    final task = _task(
      'transition-task',
      TaskStatus.pendingReview,
      batchId: 'batch-transition',
      selectionIndex: 0,
    );

    final before = TaskCenterProjection.fromTasks(<ImportTask>[task]);
    expect(
      before.tasksFor(TaskCenterCategory.pendingReview).single.id,
      'transition-task',
    );
    expect(before.tasksFor(TaskCenterCategory.completed), isEmpty);

    task.status = TaskStatus.completed;
    final after = TaskCenterProjection.fromTasks(<ImportTask>[task]);

    expect(after.tasksFor(TaskCenterCategory.pendingReview), isEmpty);
    expect(
      after.tasksFor(TaskCenterCategory.completed).single.id,
      'transition-task',
    );
  });

  test('keeps different batches and legacy tasks in their original slots', () {
    final projection = TaskCenterProjection.fromTasks(<ImportTask>[
      _task(
        'batch-a-second',
        TaskStatus.processing,
        batchId: 'batch-a',
        selectionIndex: 1,
      ),
      _task('legacy-first', TaskStatus.processing),
      _task(
        'batch-b-first',
        TaskStatus.processing,
        batchId: 'batch-b',
        selectionIndex: 0,
      ),
      _task(
        'batch-a-first',
        TaskStatus.processing,
        batchId: 'batch-a',
        selectionIndex: 0,
      ),
      _task('legacy-second', TaskStatus.processing),
      _task(
        'batch-b-second',
        TaskStatus.processing,
        batchId: 'batch-b',
        selectionIndex: 1,
      ),
    ]);

    expect(
      projection.tasksFor(TaskCenterCategory.processing).map((task) => task.id),
      <String>[
        'batch-a-first',
        'legacy-first',
        'batch-b-first',
        'batch-a-second',
        'legacy-second',
        'batch-b-second',
      ],
    );
  });

  test('same file names do not affect identity or batch ordering', () {
    final projection = TaskCenterProjection.fromTasks(<ImportTask>[
      _task(
        'same-second',
        TaskStatus.error,
        batchId: 'batch-same',
        selectionIndex: 1,
        title: 'same.pdf',
      ),
      _task(
        'same-first',
        TaskStatus.error,
        batchId: 'batch-same',
        selectionIndex: 0,
        title: 'same.pdf',
      ),
    ]);

    expect(
      projection.tasksFor(TaskCenterCategory.error).map((task) => task.id),
      <String>['same-first', 'same-second'],
    );
  });
}
