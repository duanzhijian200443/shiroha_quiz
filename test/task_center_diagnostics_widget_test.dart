import 'support/task_center_test_composition.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_components.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_controller.dart';

void main() {
  late TaskManager manager;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    manager = TaskManager.forTesting();
    await manager.ready;
  });
  tearDown(() {
    manager.dispose();
  });

  Widget createWidgetUnderTest({
    ValueChanged<ImportTask>? onOpenReview,
    TaskReviewPageBuilder? reviewPageBuilder,
    TaskManager? taskManager,
    ImportTaskCoordinator? taskCoordinator,
    TaskCenterRetryFilePicker? retryFilePicker,
    ValueChanged<String>? onOpenBank,
  }) {
    return MaterialApp(
      home: TaskCenterScreen(
        dependencies: testTaskCenterDependencies(
            manager: taskManager ?? manager,
            coordinator: taskCoordinator,
            picker: retryFilePicker,
            onReview: onOpenReview,
            reviewBuilder: reviewPageBuilder),
      ),
    );
  }

  Future<void> selectCategory(
    WidgetTester tester,
    TaskCenterCategory category,
  ) async {
    await tester.tap(
      find.byKey(ValueKey<String>(
          'task-category-${category == TaskCenterCategory.processing ? 'inProgress' : category.name}')),
    );
    await _pumpTaskCenter(tester);
    await tester.runAsync(() => Future<void>.value());
    await _pumpTaskCenter(tester);
  }

  ImportTask createOcrAttemptTask({
    required String id,
    required TaskStatus status,
    required ImportAttemptState attemptState,
    String title = 'same.pdf',
  }) {
    return ImportTask(
      id: id,
      title: title,
      status: status,
      progressText: '安全的合成任务状态',
      percent: status == TaskStatus.processing ? 0.4 : 0,
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: 'trace-$id',
        TaskManager.keyParseMode: 'ocr',
        TaskManager.keyAttemptNumber: 1,
        TaskManager.keyAttemptToken: 'attempt-$id',
        TaskManager.keyAttemptState: attemptState.name,
      },
    );
  }

  testWidgets('review action is explicit and bound to the current task ID',
      (WidgetTester tester) async {
    final openedTaskIds = <String>[];
    manager.tasks.addAll(<ImportTask>[
      ImportTask(
        id: 'review-action',
        title: 'same.pdf',
        status: TaskStatus.pendingReview,
        parsedData: const <Map<String, dynamic>>[
          <String, dynamic>{'q_num': '1', 'content': 'fixture'},
        ],
      ),
      ImportTask(
        id: 'completed-no-action',
        title: 'same.pdf',
        status: TaskStatus.completed,
        completedAt: 200,
      ),
    ]);

    final probe = await tester.runAsync(
        () => testTaskCenterDependencies(manager: manager).query.read());
    expect(probe, isA<HomeTrainingSuccess<TaskCenterSnapshot>>());
    expect(
        (probe as HomeTrainingSuccess<TaskCenterSnapshot>)
            .value
            .items
            .first
            .actions
            .review,
        isTrue);
    await tester.pumpWidget(
      createWidgetUnderTest(
        onOpenReview: (task) => openedTaskIds.add(task.id),
      ),
    );
    await _pumpTaskCenter(tester);
    await selectCategory(tester, TaskCenterCategory.pendingReview);

    final tabs = tester.widget<TaskCenterTabs>(find.byType(TaskCenterTabs));
    expect(tabs.selected, TaskCenterCoarseStatus.pendingReview);
    expect(tabs.counts[TaskCenterCoarseStatus.pendingReview], 1);
    expect(find.byKey(const ValueKey('import-task-review-action')),
        findsOneWidget);

    expect(
      find.byKey(const ValueKey<String>('task-review-review-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('task-review-completed-no-action')),
      findsNothing,
    );
    expect(openedTaskIds, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('task-review-review-action')),
    );
    await _pumpTaskCenter(tester);
    expect(openedTaskIds, <String>['review-action']);
  });

  testWidgets('review action performs Navigator push for the selected task ID',
      (WidgetTester tester) async {
    String? builtTaskId;
    manager.tasks.addAll(<ImportTask>[
      ImportTask(
        id: 'same-name-first-review',
        title: 'same.pdf',
        status: TaskStatus.pendingReview,
        parsedData: const <Map<String, dynamic>>[
          <String, dynamic>{'q_num': '1', 'content': 'fixture one'},
        ],
      ),
      ImportTask(
        id: 'same-name-second-review',
        title: 'same.pdf',
        status: TaskStatus.pendingReview,
        parsedData: const <Map<String, dynamic>>[
          <String, dynamic>{'q_num': '2', 'content': 'fixture two'},
        ],
      ),
      ImportTask(
        id: 'completed-without-review',
        title: 'same.pdf',
        status: TaskStatus.completed,
        completedAt: 200,
      ),
    ]);

    await tester.pumpWidget(
      createWidgetUnderTest(
        reviewPageBuilder: (context, task) {
          builtTaskId = task.id;
          return Scaffold(
            body: Text(
              'review-target-${task.id}',
              key: ValueKey<String>('review-target-${task.id}'),
            ),
          );
        },
      ),
    );
    await _pumpTaskCenter(tester);

    expect(find.textContaining('review-target-'), findsNothing);
    await selectCategory(tester, TaskCenterCategory.completed);
    expect(
      find.byKey(
        const ValueKey<String>('task-review-completed-without-review'),
      ),
      findsNothing,
    );

    await selectCategory(tester, TaskCenterCategory.pendingReview);
    await tester.ensureVisible(
      find.byKey(
        const ValueKey<String>('task-review-same-name-second-review'),
      ),
    );
    await _pumpTaskCenter(tester);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('task-review-same-name-second-review'),
      ),
    );
    await _pumpTaskCenter(tester);
    await tester.pumpAndSettle();

    expect(builtTaskId, 'same-name-second-review');
    expect(
      find.byKey(
        const ValueKey<String>('review-target-same-name-second-review'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('error cards never render raw error text',
      (WidgetTester tester) async {
    const sensitiveSentinel = 'PRIVATE_ERROR_BODY_SENTINEL';
    manager.tasks.add(
      ImportTask(
        id: 'safe-error-summary',
        title: 'failed.pdf',
        status: TaskStatus.error,
        errorMsg: sensitiveSentinel,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-safe-error',
        },
      ),
    );

    await tester.pumpWidget(createWidgetUnderTest());
    await _pumpTaskCenter(tester);
    await selectCategory(tester, TaskCenterCategory.error);

    expect(find.text(sensitiveSentinel), findsNothing);
    expect(find.text('查看任务状态，选择可用操作'), findsOneWidget);
    expect(find.textContaining('trace-safe-error'), findsNothing);
    expect(find.text('异常'), findsOneWidget);
  });

  testWidgets('TaskCenterScreen displays pendingReview warnings summary',
      (WidgetTester tester) async {
    final task = ImportTask(
      id: 'task_review_1',
      title: 'Review Task 1',
      status: TaskStatus.pendingReview,
      progressText: 'Wait for review',
      warnings: ['Missing image in markdown', 'Formula parse issue'],
    );
    manager.tasks.add(task);

    await tester.pumpWidget(createWidgetUnderTest());
    await _pumpTaskCenter(tester);
    await selectCategory(tester, TaskCenterCategory.pendingReview);

    expect(find.text('Review Task 1'), findsOneWidget);
    expect(find.text('共有 2 项需要确认'), findsOneWidget);
  });

  testWidgets(
      'OCR cancellation is task-ID bound and duplicate action stays disabled',
      (WidgetTester tester) async {
    final persistenceRelease = Completer<void>();
    var persistenceWrites = 0;
    final taskManager = TaskManager.forTesting(
      saveTask: (_) async {
        persistenceWrites++;
        await persistenceRelease.future;
      },
    );
    addTearDown(() {
      if (!persistenceRelease.isCompleted) persistenceRelease.complete();
      taskManager.dispose();
    });
    final first = createOcrAttemptTask(
      id: 'cancel-first',
      status: TaskStatus.processing,
      attemptState: ImportAttemptState.running,
    );
    final second = createOcrAttemptTask(
      id: 'cancel-second',
      status: TaskStatus.processing,
      attemptState: ImportAttemptState.running,
    );
    taskManager.tasks.addAll(<ImportTask>[first, second]);
    final coordinator = ImportTaskCoordinator(taskManager: taskManager);

    await tester.pumpWidget(
      createWidgetUnderTest(
        taskManager: taskManager,
        taskCoordinator: coordinator,
      ),
    );
    await _pumpTaskCenter(tester);

    final firstCancel =
        find.byKey(const ValueKey<String>('task-cancel-cancel-first'));
    expect(firstCancel, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('task-delete-cancel-first')),
      findsNothing,
    );
    await tester.ensureVisible(firstCancel);
    await tester.tap(firstCancel);
    await tester.tap(firstCancel);
    await _pumpTaskCenter(tester);
    await _pumpTaskCenter(tester);

    // D2 publishes the lifecycle transition only after its durable snapshot
    // has been accepted. While that write is intentionally held open, the
    // action is pending but the task still projects its last persisted state.
    expect(first.attemptState, ImportAttemptState.running);
    expect(second.attemptState, ImportAttemptState.running);
    await tester.pump(const Duration(seconds: 3));
    await _pumpTaskCenter(tester);
    expect(persistenceWrites, 1);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('import-task-cancel-first'),
        ),
        matching: find.text('进行中'),
      ),
      findsOneWidget,
    );
    expect(firstCancel, findsNothing);
    expect(
      tester
          .widget<PopupMenuButton<TaskCenterAction>>(
            find.byKey(const ValueKey<String>('task-menu-cancel-first')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey<String>('task-cancel-cancel-second'),
            ),
          )
          .onPressed,
      isNotNull,
    );

    persistenceRelease.complete();
    await _pumpTaskCenter(tester);
    await _pumpTaskCenter(tester);
    // The test scheduler has no matching runtime request, so the coordinator
    // durably settles the already-persisted cancellation as cancelled.
    expect(first.attemptState, ImportAttemptState.cancelled);
  });

  testWidgets('retry picker cancellation does not mutate the OCR attempt',
      (WidgetTester tester) async {
    final taskManager = TaskManager.forTesting();
    addTearDown(taskManager.dispose);
    final task = createOcrAttemptTask(
      id: 'retry-picker-cancelled',
      status: TaskStatus.error,
      attemptState: ImportAttemptState.failed,
    );
    taskManager.tasks.add(task);
    var parserCalls = 0;
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      parser: (_) async {
        parserCalls++;
        return const ImportParseResult(questions: <Map<String, dynamic>>[]);
      },
    );

    await tester.pumpWidget(
      createWidgetUnderTest(
        taskManager: taskManager,
        taskCoordinator: coordinator,
        retryFilePicker: () async => null,
      ),
    );
    await _pumpTaskCenter(tester);
    await selectCategory(tester, TaskCenterCategory.error);

    final retry =
        find.byKey(const ValueKey<String>('task-retry-retry-picker-cancelled'));
    await tester.tap(retry);
    await _pumpTaskCenter(tester);
    await _pumpTaskCenter(tester);

    expect(task.attemptNumber, 1);
    expect(task.attemptState, ImportAttemptState.failed);
    expect(task.traceId, 'trace-retry-picker-cancelled');
    expect(parserCalls, 0);
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
  });

  testWidgets(
      'retry reselects files for the exact task without rendering the path',
      (WidgetTester tester) async {
    const selectedPath = r'C:\synthetic-private\replacement.pdf';
    final taskManager = TaskManager.forTesting();
    addTearDown(taskManager.dispose);
    final first = createOcrAttemptTask(
      id: 'retry-first',
      status: TaskStatus.error,
      attemptState: ImportAttemptState.failed,
    );
    final second = createOcrAttemptTask(
      id: 'retry-second',
      status: TaskStatus.error,
      attemptState: ImportAttemptState.failed,
    );
    taskManager.tasks.addAll(<ImportTask>[first, second]);
    List<String>? parsedPaths;
    List<String>? parsedNames;
    String? parsedTaskId;
    final coordinator = ImportTaskCoordinator(
      taskManager: taskManager,
      traceIdFactory: () => 'trace-retry-new',
      attemptTokenFactory: () => 'attempt-retry-new',
      parser: (request) async {
        parsedPaths = request.filePaths;
        parsedNames = request.fileNames;
        parsedTaskId = request.taskId;
        return const ImportParseResult(
          questions: <Map<String, dynamic>>[
            <String, dynamic>{'q_num': '1', 'content': 'fixture'},
          ],
        );
      },
    );

    await tester.pumpWidget(
      createWidgetUnderTest(
        taskManager: taskManager,
        taskCoordinator: coordinator,
        retryFilePicker: () async => FilePickerResult(
          <PlatformFile>[
            PlatformFile(
              name: 'replacement.pdf',
              path: selectedPath,
              size: 0,
            ),
          ],
        ),
      ),
    );
    await _pumpTaskCenter(tester);
    await selectCategory(tester, TaskCenterCategory.error);

    final retry = find.byKey(const ValueKey<String>('task-retry-retry-first'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(parsedTaskId, 'retry-first');
    expect(parsedPaths, const <String>[selectedPath]);
    expect(parsedNames, const <String>['replacement.pdf']);
    expect(first.id, 'retry-first');
    expect(first.attemptNumber, 2);
    expect(first.traceId, 'trace-retry-new');
    expect(second.attemptNumber, 1);
    expect(second.attemptState, ImportAttemptState.failed);
    expect(find.textContaining(selectedPath), findsNothing);
  });
}

Future<void> _pumpTaskCenter(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.value());
  await tester.pump();
}
