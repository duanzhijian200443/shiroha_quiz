import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildTestableWidget(List<Map<String, dynamic>> questions) {
    return MaterialApp(
      home: ImportStagingScreen(
        parsedQuestions: questions,
        warnings: const [],
      ),
    );
  }

  testWidgets('Renders badges from metadata', (WidgetTester tester) async {
    final questions = [
      {
        'content': '题干',
        'type': 2,
        'standard_answer': 'A',
        '_import_review': {
          'source': 'fused',
          'sources': ['text', 'vision'],
          'fragmentKinds': ['fullQuestion'],
          'originalIndices': [0, 1],
          'riskHints': ['fused_from_text_vision', 'answer_conflict'],
        }
      },
    ];

    await tester.pumpWidget(buildTestableWidget(questions));
    await tester.pumpAndSettle();

    expect(find.text('图文融合'), findsOneWidget);
    expect(find.text('答案冲突'), findsOneWidget);
  });

  testWidgets('Old data without metadata renders normally',
      (WidgetTester tester) async {
    final questions = [
      {
        'content': '老题目数据',
        'type': 2,
        'standard_answer': 'A',
      },
    ];

    await tester.pumpWidget(buildTestableWidget(questions));
    await tester.pumpAndSettle();

    expect(find.text('图文融合'), findsNothing);
    expect(find.text('老题目数据'), findsOneWidget);
  });
}
