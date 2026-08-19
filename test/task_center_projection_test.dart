import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';

ImportTask _task(
  String id,
  TaskStatus status, {
  String? batchId,
  int? selectionIndex,
  String title = 'fixture.pdf',
  String? parseMode,
  ImportAttemptState? attemptState,
}) {
  return ImportTask(
    id: id,
    title: title,
    status: status,
    diagnostics: <String, dynamic>{
      if (batchId != null) TaskManager.keyBatchId: batchId,
      if (selectionIndex != null) TaskManager.keySelectionIndex: selectionIndex,
      if (parseMode != null) TaskManager.keyParseMode: parseMode,
      if (attemptState != null) TaskManager.keyAttemptState: attemptState.name,
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

  test('projects OCR attempt states to safe task-center actions', () {
    TaskCenterTaskPresentation presentation(ImportAttemptState state) {
      final status = switch (state) {
        ImportAttemptState.queued ||
        ImportAttemptState.running ||
        ImportAttemptState.cancelRequested =>
          TaskStatus.processing,
        ImportAttemptState.readyForReview => TaskStatus.pendingReview,
        ImportAttemptState.cancelled ||
        ImportAttemptState.failed ||
        ImportAttemptState.interrupted =>
          TaskStatus.error,
      };
      return TaskCenterProjection.presentationFor(
        _task(
          state.name,
          status,
          parseMode: 'ocr',
          attemptState: state,
        ),
      );
    }

    for (final state in <ImportAttemptState>[
      ImportAttemptState.queued,
      ImportAttemptState.running,
    ]) {
      final value = presentation(state);
      expect(value.canCancel, isTrue, reason: state.name);
      expect(value.isCancellationPending, isFalse, reason: state.name);
      expect(value.canRetry, isFalse, reason: state.name);
      expect(value.canDelete, isFalse, reason: state.name);
    }

    final cancelling = presentation(ImportAttemptState.cancelRequested);
    expect(cancelling.canCancel, isFalse);
    expect(cancelling.isCancellationPending, isTrue);
    expect(cancelling.canRetry, isFalse);
    expect(cancelling.canDelete, isFalse);
    expect(cancelling.statusLabel, '取消中');
    expect(cancelling.summaryOverride, '正在等待当前 OCR 请求结束');

    for (final state in <ImportAttemptState>[
      ImportAttemptState.cancelled,
      ImportAttemptState.failed,
      ImportAttemptState.interrupted,
    ]) {
      final value = presentation(state);
      expect(value.canCancel, isFalse, reason: state.name);
      expect(value.canRetry, isTrue, reason: state.name);
      expect(value.canDelete, isTrue, reason: state.name);
    }
    expect(
      presentation(ImportAttemptState.cancelled).statusLabel,
      '已取消',
    );
    expect(
      presentation(ImportAttemptState.interrupted).statusLabel,
      '已中断',
    );

    final review = presentation(ImportAttemptState.readyForReview);
    expect(review.canCancel, isFalse);
    expect(review.canRetry, isFalse);
    expect(review.canDelete, isFalse);

    final completedReady = TaskCenterProjection.presentationFor(
      _task(
        'completed-ready',
        TaskStatus.completed,
        parseMode: 'ocr',
        attemptState: ImportAttemptState.readyForReview,
      ),
    );
    expect(completedReady.canDelete, isTrue);

    final errorReady = TaskCenterProjection.presentationFor(
      _task(
        'error-ready',
        TaskStatus.error,
        parseMode: 'ocr',
        attemptState: ImportAttemptState.readyForReview,
      ),
    );
    expect(errorReady.canDelete, isFalse);
  });

  test('does not expose OCR actions for legacy or non-OCR tasks', () {
    final coarseProcessing = TaskCenterProjection.presentationFor(
      _task('coarse-processing', TaskStatus.processing, parseMode: 'text'),
    );
    final coarseReview = TaskCenterProjection.presentationFor(
      _task('coarse-review', TaskStatus.pendingReview, parseMode: 'text'),
    );
    final legacyOcr = TaskCenterProjection.presentationFor(
      _task('legacy-ocr', TaskStatus.error, parseMode: 'ocr'),
    );
    final textFailure = TaskCenterProjection.presentationFor(
      _task(
        'text-failure',
        TaskStatus.error,
        parseMode: 'text',
        attemptState: ImportAttemptState.failed,
      ),
    );
    final coarseCompleted = TaskCenterProjection.presentationFor(
      _task('coarse-completed', TaskStatus.completed, parseMode: 'text'),
    );
    final coarseError = TaskCenterProjection.presentationFor(
      _task('coarse-error', TaskStatus.error, parseMode: 'text'),
    );

    expect(coarseProcessing.canDelete, isFalse);
    expect(coarseReview.canDelete, isFalse);
    expect(coarseCompleted.canDelete, isTrue);
    expect(coarseError.canDelete, isTrue);
    expect(legacyOcr.canRetry, isFalse);
    expect(legacyOcr.canCancel, isFalse);
    expect(legacyOcr.canDelete, isTrue);
    expect(textFailure.canRetry, isFalse);
    expect(textFailure.canCancel, isFalse);
    expect(textFailure.canDelete, isTrue);
  });
}
