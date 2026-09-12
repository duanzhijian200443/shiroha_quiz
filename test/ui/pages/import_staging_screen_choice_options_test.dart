import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/application/questions/folder_query_port.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

import 'package:flutter_math_fork/flutter_math.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';

class _FakeFolderQuery implements FolderQueryPort {
  @override
  Future<List<String>> listAvailableFolders() async => const [];
}

Widget _buildScreen(
  List<Map<String, dynamic>> questions, {
  ExplanationRetentionMode retentionMode =
      ExplanationRetentionMode.allQuestionTypes,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ImportStagingScreen(
        parsedQuestions: questions,
        folderQuery: _FakeFolderQuery(),
        initialExplanationRetentionMode: retentionMode,
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ImportStagingScreen choice options presentation', () {
    testWidgets('renders all four choice options in original order',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final questions = [
        {
          'type': 0,
          'content': '设函数 f(x) 在区间上连续，则 ( )',
          'options': [
            'A. option one',
            'B. option two',
            'C. option three',
            'D. option four',
          ],
          'standard_answer': 'B',
          'explanation': '本题考查极限概念。',
        },
      ];

      await tester.pumpWidget(_buildScreen(questions));
      await tester.pumpAndSettle();

      // Stem is visible
      expect(find.textContaining('设函数 f(x) 在区间上连续'), findsOneWidget);

      // Four options must render
      final finderA = find.textContaining('A. option one');
      final finderB = find.textContaining('B. option two');
      final finderC = find.textContaining('C. option three');
      final finderD = find.textContaining('D. option four');

      expect(finderA, findsOneWidget);
      expect(finderB, findsOneWidget);
      expect(finderC, findsOneWidget);
      expect(finderD, findsOneWidget);

      // Order must be strictly preserved: A above B above C above D
      final dyA = tester.getTopLeft(finderA).dy;
      final dyB = tester.getTopLeft(finderB).dy;
      final dyC = tester.getTopLeft(finderC).dy;
      final dyD = tester.getTopLeft(finderD).dy;

      expect(dyA, lessThan(dyB));
      expect(dyB, lessThan(dyC));
      expect(dyC, lessThan(dyD));

      // Answer block is still present and below options
      expect(find.textContaining('B'), findsWidgets);
      expect(find.textContaining('本题考查极限概念。'), findsOneWidget);
      final dyAnswer = tester.getTopLeft(find.text('标准答案：')).dy;
      expect(dyD, lessThan(dyAnswer));
    });

    testWidgets('renders choice option with LaTeX via markdown/latex path',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final questions = [
        {
          'type': 0,
          'content': r'设 $\lim_{x\to 1}\frac{f(x)}{\ln x} = 1$，则 ( )',
          'options': [
            r'A. $f(1) = 0$',
            r'B. $\lim_{x\to 1}f(x) = 0$',
            r'C. $f^{\prime}(1) = 1$',
            r'D. $\lim_{x\to 1}f^{\prime}(x) = 1$',
          ],
          'standard_answer': 'B',
          'explanation': '考查导数定义。',
        },
      ];

      await tester.pumpWidget(_buildScreen(questions));
      await tester.pumpAndSettle();

      // Options labels and LaTeX Math widgets are rendered without crash
      expect(find.byType(Math), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('A.'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('B.'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('C.'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('D.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty options in subjective questions does not break layout',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final questions = [
        {
          'type': 3,
          'content': '证明方程在区间内有且仅有一个实根。',
          'options': <String>[],
          'standard_answer': '',
          'explanation': '由零点定理与单调性可得。',
        },
      ];

      await tester.pumpWidget(_buildScreen(questions));
      await tester.pumpAndSettle();

      expect(find.textContaining('证明方程在区间内有且仅有一个实根。'), findsOneWidget);
      expect(find.textContaining('由零点定理与单调性可得。'), findsOneWidget);
      expect(find.textContaining('A.'), findsNothing);
    });

    testWidgets(
        'choice question lacking answer still renders options and missing notice',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final questions = [
        {
          'type': 0,
          'content': '未提取到答案的选择题',
          'options': [
            'A. opt A',
            'B. opt B',
          ],
          'standard_answer': '',
          'explanation': '',
        },
      ];

      await tester.pumpWidget(_buildScreen(questions));
      await tester.pumpAndSettle();

      expect(find.textContaining('未提取到答案的选择题'), findsOneWidget);
      expect(find.textContaining('A. opt A'), findsOneWidget);
      expect(find.textContaining('B. opt B'), findsOneWidget);
      expect(find.text('暂无答案，导入后可编辑或使用 AI 解答'), findsOneWidget);
    });
  });
}
