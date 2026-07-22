import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
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

  Widget createWidgetUnderTest() {
    return const MaterialApp(
      home: TaskCenterScreen(),
    );
  }

  testWidgets('TaskCenterScreen shows empty state when no tasks are present',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidgetUnderTest());
    expect(find.text('当前没有后台任务'), findsOneWidget);
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

    const expectations = <String, (String, String)>{
      'processing-task': ('trace-processing', '正在解析'),
      'review-task': ('trace-review', '等待用户校对'),
      'completed-task': ('trace-completed', '成功完成'),
      'failed-task': ('trace-failed', '解析失败'),
    };

    for (final entry in expectations.entries) {
      final button = find.byKey(ValueKey('task-diagnostics-${entry.key}'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(entry.value.$1), findsOneWidget);
      expect(find.text(entry.value.$2), findsWidgets);
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

    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-same-name-first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-trace-same-name-first')));
    await tester.pump();
    expect(clipboardText, 'trace-first');
    expect(first.status, TaskStatus.completed);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('task-diagnostics-same-name-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-trace-same-name-second')));
    await tester.pump();
    expect(clipboardText, 'trace-second');
    expect(second.status, TaskStatus.pendingReview);
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
}
