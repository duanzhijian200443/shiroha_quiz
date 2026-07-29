import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

class _MockRepo implements QuestionRepository {
  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<dynamic> questions,
  }) async {}

  @override
  Future<List<String>> getAvailableFolders() async => [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget createWidget({
    required Map<String, dynamic>? diagnostics,
    List<Map<String, dynamic>>? questions,
  }) {
    return MaterialApp(
      home: ImportStagingScreen(
        parsedQuestions: questions ??
            const [
              {
                'q_num': 1,
                'question_type': 0,
                'content': 'Normal question',
                'options': ['A', 'B'],
                'standard_answer': 'A',
              },
            ],
        diagnostics: diagnostics,
        questionRepository: _MockRepo(),
      ),
    );
  }

  testWidgets('shows vision low quality banner when hasLowQualityVisionParse',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': {
        'hasLowQualityVisionParse': true,
        'total': 10,
        'riskyCount': 7,
        'lowQualityFileCount': 1,
        'issueCounts': {'answer_leaked_to_content': 3},
        'recommendedAction': 'review_or_retry_stronger_vision',
      },
    }));
    await tester.pumpAndSettle();

    expect(find.text('视觉解析质量偏低'), findsOneWidget);
    expect(find.textContaining('建议人工复核'), findsOneWidget);
  });

  testWidgets('no banner when visionQualitySummary is missing',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {}));
    await tester.pumpAndSettle();

    expect(find.text('视觉解析质量偏低'), findsNothing);
  });

  testWidgets('no banner when hasLowQualityVisionParse is false',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': {
        'hasLowQualityVisionParse': false,
        'total': 10,
        'riskyCount': 2,
        'lowQualityFileCount': 0,
      },
    }));
    await tester.pumpAndSettle();

    expect(find.text('视觉解析质量偏低'), findsNothing);
  });

  testWidgets('no banner when visionQualitySummary is not a map',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': 'bad_value',
    }));
    await tester.pumpAndSettle();

    expect(find.text('视觉解析质量偏低'), findsNothing);
  });

  testWidgets('banner shows risky count', (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': {
        'hasLowQualityVisionParse': true,
        'total': 20,
        'riskyCount': 9,
        'lowQualityFileCount': 1,
      },
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('9'), findsWidgets);
    expect(find.textContaining('20'), findsWidgets);
  });

  testWidgets('banner shows top issue counts', (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': {
        'hasLowQualityVisionParse': true,
        'total': 20,
        'riskyCount': 9,
        'lowQualityFileCount': 1,
        'issueCounts': {
          'answer_leaked_to_content': 3,
          'missing_answer_or_explanation': '4',
          'type_options_mismatch': 2.0,
          'duplicate_q_num': 0,
        },
      },
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('主要风险'), findsOneWidget);
    expect(find.textContaining('缺少答案/解析 4'), findsOneWidget);
    expect(find.textContaining('答案混入题干 3'), findsOneWidget);
    expect(find.textContaining('题型选项不匹配 2'), findsOneWidget);
    expect(find.textContaining('重复题号'), findsNothing);
  });

  testWidgets('low quality banner does not affect save button disable state',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      'visionQualitySummary': {
        'hasLowQualityVisionParse': true,
        'total': 10,
        'riskyCount': 7,
        'lowQualityFileCount': 1,
      },
    }));
    await tester.pumpAndSettle();

    final elevatedButton = find.byType(ElevatedButton);
    final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
    // Save button should still be enabled – low quality alone is NOT a block
    expect(buttonWidget.onPressed, isNotNull,
        reason: 'Low quality vision should not block save');
  });

  testWidgets(
      'qualityGate blocked still takes priority over vision quality banner',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: {
        'qualityGate': {
          'blocked': true,
          'reason': '解析丢失率过高',
        },
        'visionQualitySummary': {
          'hasLowQualityVisionParse': true,
          'total': 10,
          'riskyCount': 7,
          'lowQualityFileCount': 1,
        },
      },
      questions: const [
        {
          'content': '',
          'type': 0,
          'options': ['A', 'B'],
        },
      ],
    ));
    await tester.pumpAndSettle();

    // Both banners should be visible
    expect(find.text('视觉解析质量偏低'), findsOneWidget);
    // Save button should still be disabled because qualityGate is blocked
    final elevatedButton = find.byType(ElevatedButton);
    final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
    expect(buttonWidget.onPressed, isNull,
        reason: 'qualityGate blocked must disable save');
  });
}
