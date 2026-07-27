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

  Widget createWidget({
    required Map<String, dynamic>? diagnostics,
    List<Map<String, dynamic>>? questions,
  }) {
    return MaterialApp(
      home: ImportStagingScreen(
        parsedQuestions: questions ??
            [
              {
                'q_num': 1,
                'type': 0,
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

  testWidgets('historical blocked gate is diagnostic only for legal questions',
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
    expect(buttonWidget.onPressed, isNotNull);
    expect(find.textContaining('确认无误'), findsOneWidget);
    expect(find.textContaining(blockReason), findsNothing);

    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.text('初始质量门禁'), findsOneWidget);
    expect(find.textContaining('最终门禁以当前校对结果为准'), findsOneWidget);
  });

  testWidgets('historical blocked gate still blocks current structural issues',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: const {
        'qualityGate': {'blocked': true, 'reason': 'historical'},
      },
      questions: const [
        {
          'q_num': 1,
          'type': 0,
          'content': 'Broken choice question',
          'options': <String>['', '   '],
          'standard_answer': 'A',
        },
      ],
    ));
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
    expect(find.textContaining('题目结构错误'), findsOneWidget);
  });

  testWidgets('historical clear gate cannot allow current structural issues',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: const {
        'qualityGate': {'blocked': false},
      },
      questions: const [
        {
          'q_num': 1,
          'type': 0,
          'content': 'Broken choice question',
          'options': <String>['', '   '],
          'standard_answer': 'A',
        },
      ],
    ));
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('changing the blocking question type recomputes and unblocks',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: const {
        'qualityGate': {'blocked': true, 'reason': 'historical'},
      },
      questions: const [
        {
          'q_num': 1,
          'type': 0,
          'content': 'Broken choice question',
          'options': <String>[],
          'standard_answer': 'Answer',
        },
      ],
    ));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pump();
    final changeTypeQuestion = find.text('Broken choice question');
    await tester.ensureVisible(changeTypeQuestion);
    await tester.pumpAndSettle();
    await tester.tap(changeTypeQuestion);
    await tester.pump();
    await tester.tap(find.text('改题型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简答题'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('deleting the only blocking question recomputes and unblocks',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: const {
        'qualityGate': {'blocked': true, 'reason': 'historical'},
      },
      questions: const [
        {
          'q_num': 1,
          'type': 0,
          'content': 'Delete blocking question',
          'options': <String>[],
          'standard_answer': 'A',
        },
      ],
    ));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pump();
    final deleteQuestion = find.text('Delete blocking question');
    await tester.ensureVisible(deleteQuestion);
    await tester.pumpAndSettle();
    await tester.tap(deleteQuestion);
    await tester.pump();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    expect(find.text('所有题目已被删除'), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
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

  testWidgets(
      'document and per-question retention controls recompute quality state',
      (WidgetTester tester) async {
    await tester.pumpWidget(createWidget(
      diagnostics: const {},
      questions: const [
        {
          'q_num': 1,
          'type': 0,
          'content': 'Valid choice question',
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': '',
          'raw_explanation': r'Broken \(\begin{matrix}1\end{pmatrix}\)',
          '_import_review': {
            'riskHints': ['latex_unrenderable'],
          },
        },
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('警告: 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('question-repair-candidate-0')),
      findsNothing,
    );
    expect(find.text('保留解析'), findsOneWidget);
    expect(find.text('忽略解析'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('objective-explanation-document-switch')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('警告: 1'), findsOneWidget);
    expect(find.text('LaTeX 异常'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('question-repair-candidate-0')),
      findsOneWidget,
    );

    final discard =
        find.byKey(const ValueKey('question-explanation-discard-0'));
    tester.widget<FilterChip>(discard).onSelected!(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('警告: 0'), findsOneWidget);
    expect(find.text('LaTeX 异常'), findsNothing);
    expect(
      find.byKey(const ValueKey('question-repair-candidate-0')),
      findsNothing,
    );
  });
}
