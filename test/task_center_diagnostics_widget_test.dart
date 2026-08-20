import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_projection.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';

void main() {
  String? clipboardText;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // Clear task manager state
    TaskManager.instance.tasks.clear();
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget createWidgetUnderTest({
    ValueChanged<ImportTask>? onOpenReview,
    TaskReviewPageBuilder? reviewPageBuilder,
    TaskManager? taskManager,
    ImportTaskCoordinator? taskCoordinator,
    TaskCenterRetryFilePicker? retryFilePicker,
  }) {
    return MaterialApp(
      home: TaskCenterScreen(
        onOpenReview: onOpenReview,
        reviewPageBuilder: reviewPageBuilder,
        taskManager: taskManager,
        taskCoordinator: taskCoordinator,
        retryFilePicker: retryFilePicker,
      ),
    );
  }

  Future<void> selectCategory(
    WidgetTester tester,
    TaskCenterCategory category,
  ) async {
    await tester.tap(
      find.byKey(ValueKey<String>('task-category-${category.name}')),
    );
    await tester.pump();
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

  testWidgets('TaskCenterScreen shows empty state when no tasks are present',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidgetUnderTest());
    expect(find.text('进行中（0）'), findsOneWidget);
    expect(find.text('待校对（0）'), findsOneWidget);
    expect(find.text('已完成（0）'), findsOneWidget);
    expect(find.text('异常（0）'), findsOneWidget);
    expect(find.text('当前没有正在导入的文件'), findsOneWidget);
  });

  testWidgets('categories filter tasks and derive live counts',
      (WidgetTester tester) async {
    final processing = ImportTask(
      id: 'category-processing',
      title: 'processing.pdf',
      status: TaskStatus.processing,
    );
    final review = ImportTask(
      id: 'category-review',
      title: 'review.pdf',
      status: TaskStatus.pendingReview,
    );
    final completed = ImportTask(
      id: 'category-completed',
      title: 'completed.pdf',
      status: TaskStatus.completed,
    );
    final error = ImportTask(
      id: 'category-error',
      title: 'error.pdf',
      status: TaskStatus.error,
    );
    TaskManager.instance.tasks.addAll(
      <ImportTask>[processing, review, completed, error],
    );

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();

    expect(find.text('进行中（1）'), findsOneWidget);
    expect(find.text('待校对（1）'), findsOneWidget);
    expect(find.text('已完成（1）'), findsOneWidget);
    expect(find.text('异常（1）'), findsOneWidget);
    expect(find.text('processing.pdf'), findsOneWidget);
    expect(find.text('review.pdf'), findsNothing);

    await selectCategory(tester, TaskCenterCategory.pendingReview);
    expect(find.text('review.pdf'), findsOneWidget);
    expect(find.text('completed.pdf'), findsNothing);

    await selectCategory(tester, TaskCenterCategory.completed);
    expect(find.text('completed.pdf'), findsOneWidget);
    expect(find.text('review.pdf'), findsNothing);
    expect(find.text('processing.pdf'), findsNothing);

    await selectCategory(tester, TaskCenterCategory.error);
    expect(find.text('error.pdf'), findsOneWidget);
    expect(find.text('review.pdf'), findsNothing);

    processing.status = TaskStatus.pendingReview;
    TaskManager.instance.notifyListeners();
    await tester.pump();
    expect(find.text('进行中（0）'), findsOneWidget);
    expect(find.text('待校对（2）'), findsOneWidget);
    expect(find.text('已完成（1）'), findsOneWidget);
    expect(find.text('异常（1）'), findsOneWidget);
    expect(find.text('error.pdf'), findsOneWidget);
  });

  testWidgets('each category has a distinct empty state',
      (WidgetTester tester) async {
    TaskManager.instance.tasks.add(
      ImportTask(
        id: 'only-processing',
        title: 'processing.pdf',
        status: TaskStatus.processing,
      ),
    );

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    expect(find.text('当前没有正在导入的文件'), findsNothing);

    await selectCategory(tester, TaskCenterCategory.pendingReview);
    expect(find.text('当前没有等待校对的任务'), findsOneWidget);

    await selectCategory(tester, TaskCenterCategory.completed);
    expect(find.text('暂无已完成的导入任务'), findsOneWidget);

    await selectCategory(tester, TaskCenterCategory.error);
    expect(find.text('没有解析失败的任务'), findsOneWidget);
  });

  testWidgets('review action is explicit and bound to the current task ID',
      (WidgetTester tester) async {
    final openedTaskIds = <String>[];
    TaskManager.instance.tasks.addAll(<ImportTask>[
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
      ),
    ]);

    await tester.pumpWidget(
      createWidgetUnderTest(
        onOpenReview: (task) => openedTaskIds.add(task.id),
      ),
    );
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.pendingReview);

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
    await tester.pump();
    expect(openedTaskIds, <String>['review-action']);
  });

  testWidgets('review action performs Navigator push for the selected task ID',
      (WidgetTester tester) async {
    String? builtTaskId;
    TaskManager.instance.tasks.addAll(<ImportTask>[
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
    await tester.pump();

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
    await tester.tap(
      find.byKey(
        const ValueKey<String>('task-review-same-name-second-review'),
      ),
    );
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
    TaskManager.instance.tasks.add(
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
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.error);

    expect(find.text(sensitiveSentinel), findsNothing);
    expect(find.text('导入失败，请查看诊断信息'), findsOneWidget);
    expect(find.text('Trace ID: trace-safe-error'), findsOneWidget);
    expect(find.text('解析失败'), findsOneWidget);
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
    TaskManager.instance.tasks.add(task);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.pendingReview);

    expect(find.text('Review Task 1'), findsOneWidget);
    expect(find.text('解析完成，但有 2 条注意事项'), findsOneWidget);
  });

  testWidgets('TaskCenterScreen displays processing batch statistics',
      (WidgetTester tester) async {
    final task = ImportTask(
      id: 'task_process_1',
      title: 'Processing Task 1',
      status: TaskStatus.processing,
      progressText: 'Parsing batch...',
      percent: 0.4,
      pendingChunks: ['chunk1', 'chunk2'],
      failedChunks: ['chunk3'],
    );
    TaskManager.instance.tasks.add(task);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();

    expect(find.text('Processing Task 1'), findsOneWidget);
    expect(find.text('待解析: 2 批次'), findsOneWidget);
    expect(find.text('失败: 1 批次'), findsOneWidget);
    expect(find.text('断点重试'), findsOneWidget);
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
    await tester.pump();

    final firstCancel =
        find.byKey(const ValueKey<String>('task-cancel-cancel-first'));
    expect(firstCancel, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('task-delete-cancel-first')),
      findsNothing,
    );
    await tester.ensureVisible(firstCancel);
    await tester.tap(firstCancel);
    await tester.pump();
    await tester.pump();

    // D2 publishes the lifecycle transition only after its durable snapshot
    // has been accepted. While that write is intentionally held open, the
    // action is pending but the task still projects its last persisted state.
    expect(first.attemptState, ImportAttemptState.running);
    expect(second.attemptState, ImportAttemptState.running);
    expect(persistenceWrites, 1);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('import-task-cancel-first'),
        ),
        matching: find.text('取消中'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<OutlinedButton>(firstCancel).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(
              const ValueKey<String>('task-cancel-cancel-second'),
            ),
          )
          .onPressed,
      isNotNull,
    );

    persistenceRelease.complete();
    await tester.pump();
    await tester.pump();
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
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.error);

    final retry =
        find.byKey(const ValueKey<String>('task-retry-retry-picker-cancelled'));
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();

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
    await tester.pump();
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

  testWidgets(
      'TaskCenterScreen displays diagnostics button for error tasks with diagnostics',
      (WidgetTester tester) async {
    final task = ImportTask(
      id: 'task_error_1',
      title: 'Error Task 1',
      status: TaskStatus.error,
      errorMsg: 'Parse failed',
      warnings: ['Unresolved image'],
      diagnostics: {
        'pdf_render': {'status': 'crash', 'error': 'corrupted'}
      },
    );
    TaskManager.instance.tasks.add(task);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.error);

    expect(find.text('Error Task 1'), findsOneWidget);
    expect(find.text('查看诊断'), findsOneWidget);

    // Tap on the diagnostics button
    await tester.tap(find.text('查看诊断'));
    await tester.pumpAndSettle();

    // Verify bottom sheet title is visible
    expect(find.text('解析诊断报告'), findsOneWidget);

    // Verify summary card details
    expect(find.text('解析失败'), findsWidgets);
    expect(find.text('Trace ID'), findsOneWidget);
    expect(find.text('不可用'), findsOneWidget);
    expect(find.byTooltip('复制 Trace ID'), findsNothing);
    expect(find.text('异常类型: '), findsWidgets);
    expect(find.text('Parse failed'), findsWidgets);

    // Tap on technical details
    await tester.tap(find.text('技术诊断详情'));
    await tester.pumpAndSettle();

    // Verify technical fields are shown (status: crash)
    expect(find.text('pdf_render.status'), findsOneWidget);
    expect(find.text('crash'), findsOneWidget);
  });

  testWidgets('all task states can open diagnostics with their own trace ID',
      (WidgetTester tester) async {
    final tasks = <ImportTask>[
      ImportTask(
        id: 'processing-task',
        title: 'same.pdf',
        status: TaskStatus.processing,
        diagnostics: {
          TaskManager.keyTraceId: 'trace-processing',
          TaskManager.keyParseMode: 'ocr',
          'pageCount': 2,
        },
      ),
      ImportTask(
        id: 'review-task',
        title: 'same.pdf',
        status: TaskStatus.pendingReview,
        parsedData: const [
          {'content': 'question'}
        ],
        diagnostics: {
          TaskManager.keyTraceId: 'trace-review',
          TaskManager.keyParseMode: 'vision',
        },
      ),
      ImportTask(
        id: 'completed-task',
        title: 'completed.pdf',
        status: TaskStatus.completed,
        completedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        diagnostics: {
          TaskManager.keyTraceId: 'trace-completed',
          TaskManager.keyParseMode: 'text',
          'questionCount': 3,
        },
      ),
      ImportTask(
        id: 'failed-task',
        title: 'failed.pdf',
        status: TaskStatus.error,
        errorMsg: 'Parse failed',
        completedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        diagnostics: {
          TaskManager.keyTraceId: 'trace-failed',
          TaskManager.keyParseMode: 'ocr',
        },
      ),
    ];
    TaskManager.instance.tasks.addAll(tasks);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();

    const expectations = <String, (TaskCenterCategory, String, String)>{
      'processing-task': (
        TaskCenterCategory.processing,
        'trace-processing',
        '正在解析',
      ),
      'review-task': (
        TaskCenterCategory.pendingReview,
        'trace-review',
        '等待用户校对',
      ),
      'completed-task': (
        TaskCenterCategory.completed,
        'trace-completed',
        '成功完成',
      ),
      'failed-task': (
        TaskCenterCategory.error,
        'trace-failed',
        '解析失败',
      ),
    };

    for (final entry in expectations.entries) {
      await selectCategory(tester, entry.value.$1);
      final button = find.byKey(ValueKey('task-diagnostics-${entry.key}'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(entry.value.$2), findsOneWidget);
      expect(find.text(entry.value.$3), findsWidgets);
      expect(find.text('解析模式'), findsOneWidget);
      expect(find.text('任务状态'), findsOneWidget);
      expect(find.text('导入耗时'), findsOneWidget);

      if (entry.key == 'processing-task') {
        final detailsToggle = find.text('技术诊断详情');
        await tester.ensureVisible(detailsToggle);
        await tester.tap(detailsToggle);
        await tester.pump();
        expect(find.text('pageCount'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
      }

      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(tasks.map((task) => task.status), [
      TaskStatus.processing,
      TaskStatus.pendingReview,
      TaskStatus.completed,
      TaskStatus.error,
    ]);
  });

  testWidgets('same-name tasks copy the trace ID bound to task identity',
      (WidgetTester tester) async {
    final first = ImportTask(
      id: 'same-name-first',
      title: 'same.pdf',
      status: TaskStatus.completed,
      diagnostics: {
        TaskManager.keyTraceId: 'trace-first',
        TaskManager.keyParseMode: 'ocr',
      },
    );
    final second = ImportTask(
      id: 'same-name-second',
      title: 'same.pdf',
      status: TaskStatus.pendingReview,
      diagnostics: {
        TaskManager.keyTraceId: 'trace-second',
        TaskManager.keyParseMode: 'ocr',
      },
    );
    TaskManager.instance.tasks.addAll([first, second]);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.completed);

    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-same-name-first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-trace-same-name-first')));
    await tester.pump();
    expect(clipboardText, 'trace-first');
    expect(first.status, TaskStatus.completed);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    await selectCategory(tester, TaskCenterCategory.pendingReview);
    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-same-name-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-trace-same-name-second')));
    await tester.pump();
    expect(clipboardText, 'trace-second');
    expect(second.status, TaskStatus.pendingReview);
  });

  testWidgets(
      'task cards retain task-ID identity through list and diagnostics updates',
      (WidgetTester tester) async {
    final taskA = ImportTask(
      id: 'task-a',
      title: 'same.pdf',
      status: TaskStatus.processing,
      progressText: 'processing-a',
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: 'trace-a',
        TaskManager.keyParseMode: 'ocr',
        'pageCount': 2,
      },
    );
    final taskB = ImportTask(
      id: 'task-b',
      title: 'same.pdf',
      status: TaskStatus.completed,
      progressText: 'processing-b',
      diagnostics: <String, dynamic>{
        TaskManager.keyTraceId: 'trace-b',
        TaskManager.keyParseMode: 'ocr',
      },
    );
    final taskManager = TaskManager.forTesting();
    taskManager.tasks.addAll(<ImportTask>[taskA, taskB]);

    await tester.pumpWidget(createWidgetUnderTest(taskManager: taskManager));
    await tester.pump();

    final cardA = find.byKey(const ValueKey<String>('import-task-task-a'));
    final cardB = find.byKey(const ValueKey<String>('import-task-task-b'));
    expect(cardA, findsOneWidget);
    expect(cardB, findsNothing);
    final taskAElement = tester.element(cardA);
    final diagnosticsA = find.descendant(
      of: cardA,
      matching: find.byKey(
        const ValueKey<String>('task-diagnostics-task-a'),
      ),
    );
    expect(
      tester.getSemantics(diagnosticsA).getSemanticsData().label,
      contains('查看诊断'),
    );

    final taskC = ImportTask(
      id: 'task-c',
      title: 'same.pdf',
      status: TaskStatus.completed,
      progressText: 'processing-c',
    );
    taskManager.tasks.insert(0, taskC);
    taskManager.notifyListeners();
    await tester.pump();

    expect(
        find.byKey(const ValueKey<String>('import-task-task-c')), findsNothing);
    expect(tester.element(cardA), same(taskAElement));

    taskA.status = TaskStatus.pendingReview;
    taskA.progressText = 'review-a';
    taskA.parsedData = const <Map<String, dynamic>>[];
    taskManager.notifyListeners();
    await tester.pump();
    expect(cardA, findsNothing);
    await selectCategory(tester, TaskCenterCategory.pendingReview);
    expect(cardA, findsOneWidget);
    expect(cardB, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('task-review-task-a')),
      findsOneWidget,
    );

    taskA.status = TaskStatus.completed;
    taskA.progressText = 'completed-a';
    taskA.completedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    taskManager.notifyListeners();
    await tester.pump();
    expect(cardA, findsNothing);
    await selectCategory(tester, TaskCenterCategory.completed);
    expect(cardA, findsOneWidget);
    expect(cardB, findsOneWidget);
    expect(find.text('任务已完成'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('task-review-task-a')),
      findsNothing,
    );
    final completedCategoryTaskAElement = tester.element(cardA);

    await tester.tap(diagnosticsA);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('trace-a'), findsOneWidget);
    final detailsToggle = find.text('技术诊断详情');
    expect(detailsToggle, findsOneWidget);
    await tester.ensureVisible(detailsToggle);
    await tester.pump();
    await tester.tap(detailsToggle);
    await tester.pump();
    expect(find.text('pageCount'), findsOneWidget);
    await tester.tap(detailsToggle);
    await tester.pump();
    expect(find.text('pageCount'), findsNothing);
    await tester.ensureVisible(detailsToggle);
    await tester.pump();
    await tester.tap(detailsToggle);
    await tester.pump();
    expect(find.text('pageCount'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('copy-trace-task-a')));
    await tester.pump();
    expect(clipboardText, 'trace-a');
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.element(cardA), same(completedCategoryTaskAElement));

    final deleteTaskB =
        find.byKey(const ValueKey<String>('task-delete-task-b'));
    await tester.ensureVisible(deleteTaskB);
    await tester.pump();
    await tester.tap(deleteTaskB);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(cardB, findsNothing);
    expect(cardA, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('task-summary-task-a')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('task center remains usable at 360 logical pixels wide',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const longProcessingTitle =
        'very-long-processing-file-name-that-must-not-overflow.pdf';
    const sensitiveError = 'PRIVATE_ERROR_BODY_MUST_STAY_HIDDEN';
    TaskManager.instance.tasks.addAll(<ImportTask>[
      ImportTask(
        id: 'narrow-processing',
        title: longProcessingTitle,
        status: TaskStatus.processing,
        progressText: '正在解析一个具有较长安全进度说明的合成文件，请耐心等待',
        percent: 0.42,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-narrow-processing',
        },
      ),
      ImportTask(
        id: 'narrow-review',
        title: 'very-long-review-file-name-that-must-not-overflow.pdf',
        status: TaskStatus.pendingReview,
        parsedData: const <Map<String, dynamic>>[
          <String, dynamic>{'q_num': '1', 'content': 'fixture'},
        ],
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-narrow-review',
        },
      ),
      ImportTask(
        id: 'narrow-completed',
        title: 'completed.pdf',
        status: TaskStatus.completed,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-narrow-completed',
        },
      ),
      ImportTask(
        id: 'narrow-error',
        title: 'very-long-error-file-name-that-must-not-overflow.pdf',
        status: TaskStatus.error,
        errorMsg: sensitiveError,
        diagnostics: const <String, dynamic>{
          TaskManager.keyTraceId: 'trace-narrow-error',
        },
      ),
    ]);

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();

    expect(find.text('进行中（1）'), findsOneWidget);
    expect(find.text('待校对（1）'), findsOneWidget);
    expect(find.text('已完成（1）'), findsOneWidget);
    expect(find.text('异常（1）'), findsOneWidget);
    final title = tester.widget<Text>(find.text(longProcessingTitle));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('Trace ID: trace-narrow-processing'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await selectCategory(tester, TaskCenterCategory.pendingReview);
    final reviewButton = find.byKey(
      const ValueKey<String>('task-review-narrow-review'),
    );
    final reviewDiagnostics = find.byKey(
      const ValueKey<String>('task-diagnostics-narrow-review'),
    );
    await tester.ensureVisible(reviewButton);
    await tester.ensureVisible(reviewDiagnostics);
    expect(reviewButton, findsOneWidget);
    expect(reviewDiagnostics, findsOneWidget);
    expect(tester.takeException(), isNull);

    await selectCategory(tester, TaskCenterCategory.completed);
    expect(
      find.byKey(const ValueKey<String>('task-review-narrow-completed')),
      findsNothing,
    );

    await selectCategory(tester, TaskCenterCategory.error);
    expect(find.text(sensitiveError), findsNothing);
    expect(find.text('导入失败，请查看诊断信息'), findsOneWidget);
    final errorDiagnostics = find.byKey(
      const ValueKey<String>('task-diagnostics-narrow-error'),
    );
    await tester.ensureVisible(errorDiagnostics);
    expect(errorDiagnostics, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('null trace is safe even without diagnostics',
      (WidgetTester tester) async {
    TaskManager.instance.tasks.add(
      ImportTask(
        id: 'legacy-task',
        title: 'legacy.pdf',
        status: TaskStatus.completed,
      ),
    );

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.completed);
    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-legacy-task')));
    await tester.pumpAndSettle();

    expect(find.text('不可用'), findsOneWidget);
    expect(find.byTooltip('复制 Trace ID'), findsNothing);
    final detailsToggle = find.text('技术诊断详情');
    await tester.ensureVisible(detailsToggle);
    await tester.tap(detailsToggle);
    await tester.pumpAndSettle();
    expect(find.text('无技术诊断信息'), findsOneWidget);
  });

  testWidgets('sensitive diagnostic fields stay hidden',
      (WidgetTester tester) async {
    TaskManager.instance.tasks.add(
      ImportTask(
        id: 'sensitive-task',
        title: 'sensitive.pdf',
        status: TaskStatus.completed,
        diagnostics: const {
          TaskManager.keyTraceId: 'trace-sensitive',
          TaskManager.keyParseMode: 'ocr',
          'status': 'success',
          'apiKey': 'secret-api-key',
          'Authorization': 'Bearer secret',
          'rawException': 'private exception body',
          'logPath': r'C:\private\import.log',
        },
      ),
    );

    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pump();
    await selectCategory(tester, TaskCenterCategory.completed);
    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-sensitive-task')));
    await tester.pumpAndSettle();
    final detailsToggle = find.text('技术诊断详情');
    await tester.ensureVisible(detailsToggle);
    await tester.tap(detailsToggle);
    await tester.pumpAndSettle();

    expect(find.text('secret-api-key'), findsNothing);
    expect(find.text('Bearer secret'), findsNothing);
    expect(find.text('private exception body'), findsNothing);
    expect(find.text(r'C:\private\import.log'), findsNothing);
  });

  group('OBS-1 import diagnostic activation', () {
    testWidgets(
        'failed Import exposes the diagnostic number and whitelist '
        'copy', (WidgetTester tester) async {
      TaskManager.instance.tasks.add(
        ImportTask(
          id: 'obs-failed',
          title: 'private-exam.pdf',
          status: TaskStatus.error,
          errorMsg: 'some internal exception detail that must not be copied',
          diagnostics: <String, dynamic>{
            TaskManager.keyTraceId: 'trace-obs-failed',
            TaskManager.keyCorrelationId: 'OBS-7Q2M-92KD',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyAttemptNumber: 2,
            TaskManager.keyAttemptToken: 'attempt-obs-failed',
            TaskManager.keyAttemptState: ImportAttemptState.failed.name,
            'errorType': 'ZhipuOcrRequestException',
          },
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pump();
      await selectCategory(tester, TaskCenterCategory.error);

      expect(find.text('诊断编号：OBS-7Q2M-92KD'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('task-copy-diagnostic-obs-failed')),
      );
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('diagnosticId=OBS-7Q2M-92KD'));
      expect(clipboardText, contains('operation=import_attempt'));
      expect(clipboardText, contains('taskId=obs-failed'));
      expect(clipboardText, contains('attemptNumber=2'));
      expect(clipboardText, contains('traceId=trace-obs-failed'));
      expect(clipboardText, contains('failure=ZhipuOcrRequestException'));
      // Whitelist only: no file title, no error body, no paths.
      expect(clipboardText, isNot(contains('private-exam.pdf')));
      expect(
        clipboardText,
        isNot(contains('internal exception detail')),
      );
      expect(clipboardText, isNot(contains(r'C:\')));
    });

    testWidgets('failed Import without correlation hides the diagnostic row',
        (WidgetTester tester) async {
      TaskManager.instance.tasks.add(
        createOcrAttemptTask(
          id: 'obs-no-correlation',
          status: TaskStatus.error,
          attemptState: ImportAttemptState.failed,
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pump();
      await selectCategory(tester, TaskCenterCategory.error);

      expect(find.textContaining('诊断编号：'), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>('task-copy-diagnostic-obs-no-correlation'),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'failed Import with a malformed correlation hides the '
        'diagnostic row and never copies it', (WidgetTester tester) async {
      const sentinel = 'SENTINEL-CORRELATION-SECRET';
      TaskManager.instance.tasks.add(
        ImportTask(
          id: 'obs-malformed',
          title: 'private-exam.pdf',
          status: TaskStatus.error,
          diagnostics: <String, dynamic>{
            TaskManager.keyTraceId: 'trace-obs-malformed',
            TaskManager.keyCorrelationId: 'OBS-<sentinel>',
            TaskManager.keyParseMode: 'ocr',
            TaskManager.keyAttemptNumber: 1,
            TaskManager.keyAttemptToken: 'attempt-obs-malformed',
            TaskManager.keyAttemptState: ImportAttemptState.failed.name,
          },
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pump();
      await selectCategory(tester, TaskCenterCategory.error);

      expect(find.textContaining('诊断编号：'), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>('task-copy-diagnostic-obs-malformed'),
        ),
        findsNothing,
      );
      expect(clipboardText, isNull);
      expect(find.textContaining(sentinel), findsNothing);
    });
  });
}
