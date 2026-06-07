import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';

class FakeQuestionRepository extends Fake implements QuestionRepository {
  List<QuestionDraft> savedQuestions = [];
  String? savedBankName;
  String? savedFolderName;

  @override
  Future<List<String>> getAvailableFolders() async => ['Folder A'];

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    savedBankName = bankName;
    savedFolderName = folderName;
    savedQuestions = questions;
  }
}

void main() {
  group('ImportStagingScreen Final Review Widget Tests', () {
    late FakeQuestionRepository fakeRepo;

    setUp(() {
      fakeRepo = FakeQuestionRepository();
    });

    Widget createWidget(List<Map<String, dynamic>> parsedQuestions) {
      return MaterialApp(
        home: Scaffold(
          body: ImportStagingScreen(
            parsedQuestions: parsedQuestions,
            questionRepository: fakeRepo,
          ),
        ),
      );
    }

    testWidgets('低分保存显示最终风险确认弹窗 (qualityScore < 60)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));

      // 所有的题都没有答案和解析，触发低分（qualityScore = 0）
      final parsedQuestions = [
        {
          'type': 0,
          'content': 'Q1',
          'options': <String>[], // error
          'standard_answer': '', // error
          'explanation': '',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
      ];

      await tester.pumpWidget(createWidget(parsedQuestions));
      await tester.pumpAndSettle();

      // 点击保存按钮
      await tester.tap(find.textContaining('收入题库'));
      await tester.pumpAndSettle();

      // 验证提取质量不佳弹窗显示
      expect(find.text('提取质量不佳'), findsOneWidget);
      expect(find.textContaining('严重错误：'), findsOneWidget);
      expect(find.text('返回检查'), findsOneWidget);
      expect(find.text('仍然继续'), findsOneWidget);

      // 点击“仍然继续” -> 进入选择保存位置弹窗
      await tester.tap(find.text('仍然继续'));
      await tester.pumpAndSettle();

      expect(find.text('选择保存位置'), findsOneWidget);
    });

    testWidgets('有 error 但分数 >= 60 时仍提示确认 (仍有严重问题)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));

      // 一道好题 + 一道带轻微错误的题 (总分拉上去但有 error)
      final parsedQuestions = [
        {
          'type': 0,
          'content': 'Clean question with options',
          'options': ['A', 'B', 'C', 'D'],
          'standard_answer': 'A',
          'explanation': 'Explanation',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
        {
          'type': 0,
          'content': '', // missingStem -> error
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': 'Exp',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [1],
          },
        },
      ];

      await tester.pumpWidget(createWidget(parsedQuestions));
      await tester.pumpAndSettle();

      // 点击保存按钮
      await tester.tap(find.textContaining('收入题库'));
      await tester.pumpAndSettle();

      // 验证“仍有严重问题”弹窗显示
      expect(find.text('仍有严重问题'), findsOneWidget);
      expect(find.text('返回检查'), findsOneWidget);
      expect(find.text('仍然继续'), findsOneWidget);

      // 点击“仍然继续” -> 进入选择保存位置弹窗
      await tester.tap(find.text('仍然继续'));
      await tester.pumpAndSettle();

      expect(find.text('选择保存位置'), findsOneWidget);
    });

    testWidgets('普通确认摘要弹窗显示并且可以继续保存', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));

      // 只有 warning (无 error) -> 质量分一般，进入普通确认摘要
      final parsedQuestions = [
        {
          'type': 0,
          'content': '题干包含假设', // placeholderStem -> warning
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': 'Exp',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
      ];

      await tester.pumpWidget(createWidget(parsedQuestions));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('收入题库'));
      await tester.pumpAndSettle();

      // 验证普通确认摘要弹窗
      expect(find.text('普通确认摘要'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);

      // 点击“继续” -> 进入选择保存位置弹窗
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      expect(find.text('选择保存位置'), findsOneWidget);

      // 输入题库名称并保存
      await tester.enterText(
          find.widgetWithText(TextField, '目标题库名称'), 'My Bank');
      await tester.tap(find.text('确定入库'));
      await tester.pumpAndSettle();

      // 应该展示“本次导入报告”弹窗
      expect(find.text('本次导入报告'), findsOneWidget);
      expect(find.textContaining('成功入库：1 题'), findsOneWidget);

      // 点击“完成”关闭所有弹窗并退出
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    });

    testWidgets('无任何问题时直接进入选择保存位置弹窗', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));

      // 干净完美的题目
      final parsedQuestions = [
        {
          'type': 0,
          'content': 'Perfect clean question',
          'options': ['A', 'B', 'C', 'D'],
          'standard_answer': 'A',
          'explanation': 'Exp',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
      ];

      await tester.pumpWidget(createWidget(parsedQuestions));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('收入题库'));
      await tester.pumpAndSettle();

      // 不应该显示确认/警告弹窗，直接进入“选择保存位置”弹窗
      expect(find.text('选择保存位置'), findsOneWidget);
    });

    testWidgets('删除所有题目后不允许入库', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));

      final parsedQuestions = [
        {
          'type': 0,
          'content': 'Q1',
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': 'Exp',
          '_import_review': {
            'source': 'text',
            'sources': ['doc1.pdf'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': [0],
          },
        },
      ];

      await tester.pumpWidget(createWidget(parsedQuestions));
      await tester.pumpAndSettle();

      // 进入多选模式并删除所有题目
      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      // 点击保存按钮
      await tester.tap(find.textContaining('收入题库'));
      await tester.pumpAndSettle();

      // 应该提示当前没有可入库题目
      expect(find.text('当前没有可入库题目'), findsOneWidget);
    });
  });
}
