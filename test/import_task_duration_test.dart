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

  group('ImportTask Duration & Freeze Tests', () {
    test('1. processing 状态耗时随时间继续增长', () async {
      final startTime = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 10;
      final task = ImportTask(
        id: 't_running',
        title: 'Running Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );

      final elapsedInitial = task.elapsed.inSeconds;
      expect(elapsedInitial, greaterThanOrEqualTo(10));

      await Future<void>.delayed(const Duration(seconds: 2));

      final elapsedLater = task.elapsed.inSeconds;
      expect(elapsedLater, greaterThan(elapsedInitial));
    });

    test('2. pendingReview 状态耗时在进入校对时冻结', () async {
      final tm = TaskManager.forTesting();
      final startTime = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 15;
      final task = ImportTask(
        id: 't_review',
        title: 'Review Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );
      tm.addTask(task);

      // 进入校对状态
      tm.requireReview(
        't_review',
        '等待用户校对',
        [
          {'q_num': 1, 'stem': 'Test Question'}
        ],
        'DefaultBank',
        'DefaultFolder',
      );

      final taskInReview = tm.tasks.firstWhere((t) => t.id == 't_review');
      expect(taskInReview.status, TaskStatus.pendingReview);
      expect(taskInReview.completedAt, isNotNull);

      final frozenElapsed = taskInReview.elapsed.inSeconds;

      await Future<void>.delayed(const Duration(seconds: 2));

      // 耗时应当保持冻结，不再增加
      expect(taskInReview.elapsed.inSeconds, equals(frozenElapsed));
    });

    test('3. completed 与 error (failed) 状态耗时冻结', () async {
      final tm = TaskManager.forTesting();
      final startTime = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 20;

      final taskCompleted = ImportTask(
        id: 't_completed',
        title: 'Completed Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );
      tm.addTask(taskCompleted);
      tm.completeTask('t_completed', '导入成功');

      final completedTask = tm.tasks.firstWhere((t) => t.id == 't_completed');
      expect(completedTask.status, TaskStatus.completed);
      expect(completedTask.completedAt, isNotNull);
      final completedElapsed = completedTask.elapsed.inSeconds;

      final taskFailed = ImportTask(
        id: 't_failed',
        title: 'Failed Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );
      tm.addTask(taskFailed);
      tm.failTask('t_failed', '解析失败');

      final failedTask = tm.tasks.firstWhere((t) => t.id == 't_failed');
      expect(failedTask.status, TaskStatus.error);
      expect(failedTask.completedAt, isNotNull);
      final failedElapsed = failedTask.elapsed.inSeconds;

      await Future<void>.delayed(const Duration(seconds: 2));

      expect(completedTask.elapsed.inSeconds, equals(completedElapsed));
      expect(failedTask.elapsed.inSeconds, equals(failedElapsed));
    });

    test('3b. pendingReview 转换到 completed 时保留进入校对时的解析耗时', () async {
      final tm = TaskManager.forTesting();
      final startTime = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;
      final task = ImportTask(
        id: 't_review_then_complete',
        title: 'Review to Complete Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );
      tm.addTask(task);

      // 进入校对
      tm.requireReview(
        't_review_then_complete',
        '等待用户校对',
        [
          {'q_num': 1, 'stem': 'Q1'}
        ],
        'Bank',
        'Folder',
      );

      final reviewCompletedAt = tm.tasks
          .firstWhere((t) => t.id == 't_review_then_complete')
          .completedAt;
      final reviewElapsed = tm.tasks
          .firstWhere((t) => t.id == 't_review_then_complete')
          .elapsed
          .inSeconds;

      await Future<void>.delayed(const Duration(seconds: 2));

      // 用户确认入库
      tm.completeTask('t_review_then_complete', '导入成功');

      final finalTask =
          tm.tasks.firstWhere((t) => t.id == 't_review_then_complete');
      expect(finalTask.status, TaskStatus.completed);
      expect(finalTask.completedAt, equals(reviewCompletedAt));
      expect(finalTask.elapsed.inSeconds, equals(reviewElapsed));
    });

    test('5. 历史任务缺失 completedAt 时使用安全回退，不显示超大异常秒数', () {
      final historicalTime =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 100000;
      final oldTask = ImportTask(
        id: 't_historical',
        title: 'Historical Task Without CompletedAt',
        status: TaskStatus.pendingReview,
        createdAt: historicalTime,
        completedAt: null, // 模拟老版本缺字段
      );

      // 应当安全回退，不计算 now - createdAt (100000s+)，而是返回 0s
      expect(oldTask.elapsed.inSeconds, equals(0));
    });

    testWidgets('4. 重建 TaskCenterScreen / Widget 后耗时数值保持不变 (非运行状态)',
        (WidgetTester tester) async {
      TaskManager.instance.tasks.clear();
      final startTime = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 10;
      final task = ImportTask(
        id: 't_widget_freeze',
        title: 'Widget Freeze Task',
        status: TaskStatus.processing,
        createdAt: startTime,
      );
      TaskManager.instance.addTask(task);
      TaskManager.instance.requireReview(
        't_widget_freeze',
        '等待用户校对',
        [
          {'q_num': 1, 'stem': 'Q1'}
        ],
        'Bank',
        'Folder',
      );

      // 第一次 Build Widget
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TaskCenterScreen(),
          ),
        ),
      );
      await tester.pump();

      // 打开 诊断 Details Sheet
      final diagnosticsBtn = find.byKey(
        const ValueKey<String>('task-diagnostics-t_widget_freeze'),
      );
      await tester.tap(diagnosticsBtn);
      await tester.pumpAndSettle();

      expect(find.text('导入耗时'), findsOneWidget);
      final elapsedFinder = find.byWidgetPredicate(
        (w) => w is SelectableText && (w.data?.endsWith('s') ?? false),
      );
      final initialElapsedText =
          tester.widget<SelectableText>(elapsedFinder).data;

      // 等待时间流逝并重新触发 Build
      await tester.binding.delayed(const Duration(seconds: 2));
      await tester.pump();

      // 重新获取 UI 文本
      final rebuiltElapsedText =
          tester.widget<SelectableText>(elapsedFinder).data;

      expect(rebuiltElapsedText, equals(initialElapsedText));
    });
  });
}
