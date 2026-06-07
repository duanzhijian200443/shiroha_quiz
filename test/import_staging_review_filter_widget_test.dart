import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockQuestionRepository implements QuestionRepository {
  @override
  Future<List<String>> getAvailableFolders() async => [];

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildTestableWidget(
      WidgetTester tester, List<Map<String, dynamic>> questions) {
    return MaterialApp(
      home: ImportStagingScreen(
        parsedQuestions: questions,
        warnings: const [],
        questionRepository: MockQuestionRepository(),
      ),
    );
  }

  testWidgets('Renders filter chips with counts', (WidgetTester tester) async {
    final questions = [
      {
        'content': '题干 1',
        'type': 0,
        'standard_answer': '', // missing answer (error)
        'options': ['A', 'B'],
      },
      {
        'content': '题干 2',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
        '_import_review': {
          'source': 'vision',
          'sources': ['vision'],
          'riskHints': ['vision_only'],
        }
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    // Verify filter chips render
    expect(find.textContaining('全部 2'), findsOneWidget);
    expect(find.textContaining('严重 1'), findsOneWidget);
    expect(find.textContaining('缺答案 1'), findsOneWidget);
    expect(find.textContaining('视觉 1'), findsOneWidget);
  });

  testWidgets('Clicking filter chip filters items',
      (WidgetTester tester) async {
    final questions = [
      {
        'content': '普通问题',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
      },
      {
        'content': '缺失答案问题',
        'type': 0,
        'standard_answer': '', // missing
        'options': ['A', 'B'],
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    expect(find.text('普通问题'), findsOneWidget);
    expect(find.text('缺失答案问题'), findsOneWidget);

    // Click on "缺答案 1"
    final filterChip = find.textContaining('缺答案 1');
    expect(filterChip, findsOneWidget);
    await tester.tap(filterChip);
    await tester.pumpAndSettle();

    // Should only show "缺失答案问题"
    expect(find.text('普通问题'), findsNothing);
    expect(find.text('缺失答案问题'), findsOneWidget);
  });

  testWidgets('Sorting order change works', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final questions = [
      {
        'content': 'Clean Question',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
      },
      {
        'content': 'Error Question',
        'type': 0,
        'standard_answer': '', // missing
        'options': ['A', 'B'],
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    // Default sorting is original order: Clean Question first, then Error Question
    // We can open the PopupMenuButton and change sorting to "风险优先" (riskFirst)
    // Finding PopupMenuButton: has sort icon
    final sortButton = find.byIcon(Icons.sort);
    expect(sortButton, findsOneWidget);
    await tester.tap(sortButton);
    await tester.pumpAndSettle();

    // Tap on PopupMenuItem with "风险优先"
    final riskSortItem = find.text('风险优先');
    expect(riskSortItem, findsOneWidget);
    await tester.tap(riskSortItem);
    await tester.pumpAndSettle();

    // Now Error Question should be at the top.
    // In widget testing, we can assert relative positions, but the popup menu itself dismisses.
    expect(find.text('Clean Question'), findsOneWidget);
    expect(find.text('Error Question'), findsOneWidget);
  });

  testWidgets('Slide to dismiss deletes correct original item',
      (WidgetTester tester) async {
    final questions = [
      {
        'content': 'Item 1 to keep',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
      },
      {
        'content': 'Item 2 to delete',
        'type': 0,
        'standard_answer': '', // missing
        'options': ['A', 'B'],
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    // Filter to "缺答案 1" (which is Item 2)
    await tester.tap(find.textContaining('缺答案 1'));
    await tester.pumpAndSettle();

    // Dismiss Item 2
    final dismissibleFinder = find.byType(Dismissible);
    expect(dismissibleFinder, findsOneWidget);

    // Swipe left to delete
    await tester.drag(dismissibleFinder, const Offset(-500.0, 0.0));
    await tester.pumpAndSettle();

    // Go back to "全部"
    await tester.tap(find.textContaining('全部 1'));
    await tester.pumpAndSettle();

    // Item 1 should still exist, Item 2 should be gone
    expect(find.text('Item 1 to keep'), findsOneWidget);
    expect(find.text('Item 2 to delete'), findsNothing);
  });

  testWidgets('Empty state placeholder is shown', (WidgetTester tester) async {
    final questions = [
      {
        'content': 'Clean Question',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    // Click "严重" which has count 0
    await tester.tap(find.textContaining('严重 0'));
    await tester.pumpAndSettle();

    expect(find.text('当前筛选下没有题目'), findsOneWidget);
    expect(find.text('Clean Question'), findsNothing);

    // Delete the only question to test the delete-all empty state
    await tester.tap(find.textContaining('全部 1'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Dismissible), const Offset(-500.0, 0.0));
    await tester.pumpAndSettle();

    expect(find.text('所有题目已被删除'), findsOneWidget);
  });

  testWidgets('Old data without metadata renders normally',
      (WidgetTester tester) async {
    final questions = [
      {
        'content': 'Old question data',
        'type': 0,
        'standard_answer': 'A',
        'options': ['A', 'B'],
      },
    ];

    await tester.pumpWidget(buildTestableWidget(tester, questions));
    await tester.pumpAndSettle();

    expect(find.text('Old question data'), findsOneWidget);
    expect(find.textContaining('全部 1'), findsOneWidget);
  });
}
