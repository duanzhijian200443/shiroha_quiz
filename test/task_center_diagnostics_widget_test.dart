import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/task_center_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // Clear task manager state
    TaskManager.instance.tasks.clear();
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
    expect(find.text('查看详细诊断原因'), findsOneWidget);

    // Tap on the diagnostics button
    await tester.tap(find.text('查看详细诊断原因'));
    await tester.pumpAndSettle();

    // Verify bottom sheet title is visible
    expect(find.text('解析诊断报告'), findsOneWidget);
    expect(find.text('PDF 渲染失败'), findsOneWidget);
    expect(find.text('corrupted'), findsOneWidget);
  });
}
