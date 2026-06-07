import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';

class FakeQuestionRepository extends Fake implements QuestionRepository {
  @override
  Future<List<String>> getAvailableFolders() async => ['Folder A'];
}

void main() {
  group('ImportStagingScreen Batch Actions Widget Tests', () {
    late List<Map<String, dynamic>> parsedQuestions;

    setUp(() {
      parsedQuestions = [
        {
          'type': 0,
          'content': 'Q1',
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': '',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
        {
          'type': 2,
          'content': 'Q2',
          'options': [],
          'standard_answer': 'Ans2',
          'explanation': '',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [1],
          },
        },
        {
          'type': 3,
          'content': 'Q3',
          'options': [],
          'standard_answer': '', // Missing answer
          'explanation': '',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [2],
          },
        },
      ];
    });

    Widget createWidget() {
      return MaterialApp(
        home: Scaffold(
            body: ImportStagingScreen(
          parsedQuestions: parsedQuestions,
          questionRepository: FakeQuestionRepository(),
        )),
      );
    }

    testWidgets('进入/退出多选模式，勾选单题显示已选1', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      await tester.pumpWidget(createWidget());
      await tester.pumpAndSettle();

      // Click multi-select button
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();

      expect(find.text('已选 0 题'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(3));

      // Check first item
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(find.text('已选 1 题'), findsOneWidget);

      // Exit multi-select
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('解析结果校对'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('全选当前并批量删除，有确认弹窗', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      await tester.pumpWidget(createWidget());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('全选当前'));
      await tester.pumpAndSettle();

      expect(find.text('已选 3 题'), findsOneWidget);

      // Tap delete
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // Check dialog
      expect(find.text('删除选中题目'), findsOneWidget);
      expect(find.text('将删除 3 道题，此操作仅影响本次导入暂存列表。'), findsOneWidget);

      // Confirm
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(find.text('所有题目已被删除'), findsOneWidget);
    });

    testWidgets('筛选状态下，全选当前只选择当前可见题，不删除隐藏题', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      await tester.pumpWidget(createWidget());
      await tester.pumpAndSettle();

      // Select '缺答案' filter
      await tester.tap(find.widgetWithText(FilterChip, '缺答案 1'));
      await tester.pumpAndSettle();

      expect(find.text('已筛选出 1 道题'), findsOneWidget);
      expect(find.text('Q3'), findsOneWidget);

      // Enter selection mode
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();

      // Select all visible
      await tester.tap(find.text('全选当前'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 题'), findsOneWidget);

      // Delete
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(find.text('当前筛选下没有题目'), findsOneWidget);

      // Switch back to '全部'
      await tester.tap(find.widgetWithText(FilterChip, '全部 2')); // 2 items left
      await tester.pumpAndSettle();

      expect(find.text('Q1'), findsOneWidget);
      expect(find.text('Q2'), findsOneWidget);
    });

    testWidgets('批量改题型后卡片题型更新', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      await tester.pumpWidget(createWidget());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();

      // Select the first item (singleChoice)
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('改题型'));
      await tester.pumpAndSettle();

      expect(find.text('批量修改题型'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, '简答题'));
      await tester.pumpAndSettle();

      // Exit selection mode automatically happens after apply
      expect(find.text('解析结果校对'), findsOneWidget);

      // Because it's now a short answer, the original single choice shouldn't be singleChoice anymore.
      // Wait, we need a way to verify it. The text '简答题' should exist for Q1 if it shows the type label.
      // Q1, Q2, Q3. So 2 简答题 (Q3 was already 简答题).
      expect(find.text('简答题'), findsNWidgets(2));
    });

    testWidgets('切换筛选/排序会退出选择态', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      await tester.pumpWidget(createWidget());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 题'), findsOneWidget);

      // Tap on a filter chip
      await tester.tap(find.widgetWithText(FilterChip, '缺答案 1'));
      await tester.pumpAndSettle();

      // Should exit selection mode
      expect(find.text('解析结果校对'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });
  });
}
