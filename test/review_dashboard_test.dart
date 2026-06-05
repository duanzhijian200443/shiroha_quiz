import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/review_dashboard_data.dart';
import 'package:shiroha_quiz/ui/widgets/review_dashboard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';

Future<ReviewDashboardData> _emptyDashboardData(String bankName) async {
  return ReviewDashboardData(
    total: 0,
    newCount: 0,
    dueReviewCount: 0,
    masteredCount: 0,
    scheduledCount: 0,
    forecast: List.generate(
      7,
      (index) => DailyReviewForecast(
        date: DateTime(2026, 1, 1).add(Duration(days: index)),
        count: 0,
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.deleteDatabaseFile();
    // Warm up the DB
    await DatabaseHelper.instance.database;
  });

  group('ReviewDashboardData Aggregation & Time Consistency', () {
    test('Empty bank returns all zeroes', () async {
      final data =
          await ReviewEngineService().getReviewDashboardData('Empty Bank');
      expect(data.total, 0);
      expect(data.newCount, 0);
      expect(data.dueReviewCount, 0);
      expect(data.masteredCount, 0);
      expect(data.scheduledCount, 0);

      expect(data.forecast.length, 7);
      for (final f in data.forecast) {
        expect(f.count, 0);
      }
    });

    test('Today boundary test and unix seconds / ms consistency', () async {
      final db = await DatabaseHelper.instance.database;

      // Insert some questions
      await db.insert('questions', {
        'id': 'q1',
        'type': 0,
        'content': 'C1',
        'standard_answer': 'A',
        'bank_name': 'TestBank',
        'created_at': 0,
      });
      await db.insert('questions', {
        'id': 'q2',
        'type': 0,
        'content': 'C2',
        'standard_answer': 'B',
        'bank_name': 'TestBank',
        'created_at': 0,
      });
      await db.insert('questions', {
        'id': 'q3',
        'type': 0,
        'content': 'C3',
        'standard_answer': 'C',
        'bank_name': 'TestBank',
        'created_at': 0,
      });

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final tomorrowStart = todayStart.add(const Duration(days: 1));
      final nextWeekStart = todayStart.add(const Duration(days: 7));

      // Question 1: Due today
      await db.insert('review_states', {
        'question_id': 'q1',
        'state': 2, // review
        'next_review_time':
            todayStart.millisecondsSinceEpoch ~/ 1000 + 3600, // 1 hr into today
      });

      // Question 2: Due tomorrow
      await db.insert('review_states', {
        'question_id': 'q2',
        'state': 2,
        'next_review_time': tomorrowStart.millisecondsSinceEpoch ~/ 1000 + 3600,
      });

      // Question 3: Mastered
      await db.insert('review_states', {
        'question_id': 'q3',
        'state': 3, // mastered
        'next_review_time': nextWeekStart.millisecondsSinceEpoch ~/ 1000 + 3600,
      });

      final data =
          await ReviewEngineService().getReviewDashboardData('TestBank');

      // We have 3 questions total
      expect(data.total, 3);
      expect(data.newCount, 0);
      expect(data.masteredCount, 1);

      // Due today
      expect(data.dueReviewCount, 1);
      // Not due yet (q2)
      expect(data.scheduledCount, 1);

      // Forecast test
      expect(data.forecast.length, 7);

      // Day 0 (Today): q1 is due
      expect(data.forecast[0].count, 1);
      // Day 1 (Tomorrow): q2 is due
      expect(data.forecast[1].count, 1);
      // Day 2-6: nothing
      for (int i = 2; i < 7; i++) {
        expect(data.forecast[i].count, 0);
      }
    });
  });

  group('ReviewDashboard Widget Tests', () {
    testWidgets('Empty state when no bank is selected',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ReviewDashboard(bankName: '点击修改选择题库'),
        ),
      ));

      expect(find.textContaining('暂无复习数据'), findsOneWidget);
    });

    testWidgets('Widget reacts to bankName switch',
        (WidgetTester tester) async {
      // Create a wrapper to test didUpdateWidget
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ReviewDashboard(bankName: '点击修改选择题库'),
        ),
      ));
      expect(find.textContaining('暂无复习数据'), findsOneWidget);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReviewDashboard(
            bankName: 'Real Bank',
            dataLoader: _emptyDashboardData,
          ),
        ),
      ));

      // Allow the async dashboard reload triggered by didUpdateWidget to finish.
      await tester.pump();

      expect(find.textContaining('暂无复习数据'), findsOneWidget);
      // But notice the secondary message is different ("先导入题库开始学习吧" instead of "请先选择题库")
      expect(find.textContaining('先导入题库'), findsOneWidget);
    });
  });
}
