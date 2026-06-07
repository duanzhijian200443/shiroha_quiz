import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  group('ImportStagingScreen Review Summary Widget Tests', () {
    testWidgets(
        'Displays quality summary bar correctly with standard_answer and answer fallback',
        (WidgetTester tester) async {
      final questions = [
        {
          'content': 'Valid Question 1',
          'type': 2,
          'standard_answer': 'Answer 1',
        },
        {
          'content': 'Valid Question 2 with answer fallback',
          'type': 2,
          'answer': 'Answer 2', // fallback compatible
        },
        {
          'content': '  ', // Empty stem -> Error
          'type': 2,
          'standard_answer': 'Answer',
        },
      ];

      await tester.pumpWidget(MaterialApp(
        home: ImportStagingScreen(
          parsedQuestions: questions,
        ),
      ));

      await tester.pumpAndSettle();

      // Check for summary bar text
      expect(find.textContaining('质量摘要'), findsOneWidget);
      expect(find.textContaining('错误: 1'), findsOneWidget);
      expect(find.textContaining('警告: 0'), findsOneWidget);
      expect(find.textContaining('85'), findsOneWidget); // 100 - 15 = 85
    });

    testWidgets('Validates before save with low score',
        (WidgetTester tester) async {
      final questions = [
        {
          'content': '无题干', // Error
          'type': 2,
          'standard_answer': '', // Error
        },
      ];

      await tester.pumpWidget(MaterialApp(
        home: ImportStagingScreen(
          parsedQuestions: questions,
        ),
      ));

      await tester.pumpAndSettle();

      // Tap the save button
      await tester.tap(find.textContaining('确认无误，将 1 题收入题库'));
      await tester.pumpAndSettle();

      // Verify the warning dialog popped up
      expect(find.text('提取质量不佳'), findsOneWidget);
      expect(find.textContaining('最终质量评分：'), findsOneWidget);
      expect(find.textContaining('仍然继续'), findsOneWidget);
    });
  });
}
