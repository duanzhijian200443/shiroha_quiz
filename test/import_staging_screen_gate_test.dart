import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
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
  String? clipboardText;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('Save button is active when qualityGate is not blocked',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {}));
    await tester.pumpAndSettle();

    final elevatedButton = find.byType(ElevatedButton);
    expect(elevatedButton, findsOneWidget);

    final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
    expect(buttonWidget.onPressed, isNotNull,
        reason: 'Save button should be enabled');

    expect(find.textContaining('确认无误'), findsOneWidget);
  });

  testWidgets(
      'Save button is disabled and shows reason when qualityGate is blocked',
      (WidgetTester tester) async {
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
    expect(buttonWidget.onPressed, isNull,
        reason: 'Save button should be disabled');

    expect(find.textContaining(blockReason), findsOneWidget);
  });

  testWidgets('review screen displays and copies the task trace ID',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: {
      TaskManager.keyTraceId: 'trace-review-page',
      TaskManager.keyParseMode: 'ocr',
    }));
    await tester.pumpAndSettle();

    expect(find.text('导入追踪：trace-review-page'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-staging-trace')));
    await tester.pump();

    expect(clipboardText, 'trace-review-page');
    expect(find.text('Trace ID 已复制'), findsOneWidget);
  });

  testWidgets('review screen remains normal without a trace ID',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(diagnostics: const {
      'status': 'success',
      'apiKey': 'secret-api-key',
      'rawException': 'private exception body',
      'logPath': r'C:\private\import.log',
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('导入追踪：'), findsNothing);
    expect(find.byKey(const ValueKey('copy-staging-trace')), findsNothing);
    expect(find.text('secret-api-key'), findsNothing);
    expect(find.text('private exception body'), findsNothing);
    expect(find.text(r'C:\private\import.log'), findsNothing);
    expect(find.textContaining('确认无误'), findsOneWidget);
  });
}
