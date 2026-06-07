import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockQuestionRepository implements QuestionRepository {
  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<dynamic> questions,
  }) async {}

  @override
  Future<List<String>> getAvailableFolders() async {
    return [];
  }
  
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget createWidget({required Map<String, dynamic>? diagnostics}) {
    return MaterialApp(
      home: ImportStagingScreen(
        parsedQuestions: [
          {
            'q_num': 1,
            'question_type': 0,
            'content': 'Valid Question',
            'options': ['A', 'B', 'C', 'D'],
            'standard_answer': 'A',
          }
        ],
        diagnostics: diagnostics,
        questionRepository: MockQuestionRepository(),
      ),
    );
  }

  testWidgets('Save button is active when qualityGate is not blocked', (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {}));
    await tester.pumpAndSettle();

    final elevatedButton = find.byType(ElevatedButton);
    expect(elevatedButton, findsOneWidget);

    final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
    expect(buttonWidget.onPressed, isNotNull, reason: 'Save button should be enabled');

    expect(find.textContaining('确认无误'), findsOneWidget);
  });

  testWidgets('Save button is disabled and shows reason when qualityGate is blocked', (WidgetTester tester) async {
    final blockReason = '解析丢失率过高（实际 1，预期 10）';
    await tester.pumpWidget(createWidget(diagnostics: {
      'qualityGate': {
        'blocked': true,
        'reason': blockReason,
      }
    }));
    await tester.pumpAndSettle();

    final elevatedButton = find.byType(ElevatedButton);
    expect(elevatedButton, findsOneWidget);

    final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
    expect(buttonWidget.onPressed, isNull, reason: 'Save button should be disabled');

    expect(find.text(blockReason), findsOneWidget);
  });
}
