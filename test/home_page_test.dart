import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/ui/pages/home_page.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late TaskManager taskManager;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.deleteDatabaseFile();
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.instance.database;
    taskManager = TaskManager.forTesting();
  });

  tearDown(() async {
    SettingsRepository.instance.clearCache();
    await DatabaseHelper.deleteDatabaseFile();
  });

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    int maxFrames = 40,
  }) async {
    for (var frame = 0; frame < maxFrames; frame++) {
      await tester.pump();
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    fail('Expected widget did not appear within ${maxFrames * 25} ms.');
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(360, 720),
    double textScale = 1,
    VoidCallback? onSwitchBank,
    VoidCallback? onPracticeRequested,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: HomePage(
            taskManager: taskManager,
            onSwitchBank: onSwitchBank,
            onPracticeRequested: onPracticeRequested,
          ),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('home-bank-card')),
    );
  }

  testWidgets('empty home follows the compact today dashboard contract',
      (tester) async {
    await pumpHome(tester, textScale: 1.3);

    expect(find.byKey(const ValueKey('home-brand-title')), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.text('请选择题库'), findsOneWidget);
    expect(find.text('今日训练'), findsOneWidget);
    expect(find.text('开始今日训练'), findsOneWidget);
    expect(find.text('新题挑战'), findsOneWidget);
    expect(find.text('0 道新题'), findsOneWidget);
    expect(find.text('复习巩固'), findsOneWidget);
    expect(find.text('0 道待复习'), findsOneWidget);
    expect(find.text('暂无待复习题目'), findsOneWidget);
    expect(
      find.text('完成新题或产生错题后，将自动生成复习任务'),
      findsOneWidget,
    );

    expect(find.text('今日新学'), findsNothing);
    expect(find.text('今日复习'), findsNothing);
    expect(find.textContaining('个知识点'), findsNothing);
    expect(find.textContaining('个待复习'), findsNothing);
    expect(find.text('暂无复习数据'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real counts and existing home actions remain available',
      (tester) async {
    const bankName = '用于验证很长题库名称在窄窗口中不会溢出的合成题库';
    await tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      await db.insert('questions', {
        'id': 'home-new',
        'type': 0,
        'content': 'synthetic-new',
        'standard_answer': 'A',
        'created_at': 0,
        'bank_name': bankName,
      });
      await db.insert('questions', {
        'id': 'home-review',
        'type': 0,
        'content': 'synthetic-review',
        'standard_answer': 'B',
        'created_at': 0,
        'bank_name': bankName,
      });
      await db.insert('review_states', {
        'question_id': 'home-new',
        'state': 0,
      });
      await db.insert('review_states', {
        'question_id': 'home-review',
        'state': 2,
        'next_review_time': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      });
      await SettingsRepository.instance.setCurrentBank(bankName);
    });

    var switchCount = 0;
    var practiceCount = 0;
    await pumpHome(
      tester,
      onSwitchBank: () => switchCount++,
      onPracticeRequested: () => practiceCount++,
    );

    expect(find.text(bankName), findsOneWidget);
    expect(find.text('1 道新题'), findsOneWidget);
    expect(find.text('1 道待复习'), findsOneWidget);
    expect(find.text('已掌握 0 / 2'), findsOneWidget);
    expect(find.text('暂无待复习题目'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('home-switch-bank')));
    await tester.pump();
    expect(switchCount, 1);

    for (final key in const [
      'home-start-training',
      'home-new-task',
      'home-review-task',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }
    expect(practiceCount, 3);

    expect(tester.takeException(), isNull);
  });
}
