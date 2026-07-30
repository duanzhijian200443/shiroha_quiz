import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_block_environment_normalizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_renderability_checker.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  Widget host(String text) {
    return MaterialApp(
      home: Scaffold(
        body: StructuredContentRenderer(text: text),
      ),
    );
  }

  group('legacy HTML characterization', () {
    test('table markup is preserved and produces the current HTML review', () {
      const rawTable = '<table><tr><td>Synthetic cell</td></tr></table>';
      final audited = finalizeAndAuditImportQuestion(
        <String, dynamic>{
          'question_number': 1,
          'type': 3,
          'content': rawTable,
          'options': const <String>[],
          'standard_answer': 'synthetic-result',
          'explanation': '',
        },
      );

      expect(audited['content'], rawTable);
      final review = ImportReviewAnalyzer.analyzeItems(
        <ImportReviewItem>[
          ImportReviewItem.fromMap(audited, 0),
        ],
      );
      expect(
        review.issues.map((issue) => issue.code),
        contains(ImportReviewIssueCode.rawHtmlTag),
      );
    });
  });

  group('legacy LaTeX characterization', () {
    testWidgets('complete formula uses the math renderer', (tester) async {
      await tester.pumpWidget(host(r'Synthetic \(x^2 + 1\)'));
      await tester.pump();

      expect(find.byType(Math), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'unclosed array and matrix stay unchanged and use localized fallback',
      (tester) async {
        for (final environment in const <String>['array', 'matrix']) {
          final input = environment == 'array'
              ? r'Before \(\begin{array}{c}1\\2\) after'
              : r'Before \(\begin{matrix}1&2\) after';
          final normalization =
              const LatexBlockEnvironmentNormalizer().normalize(input);

          expect(normalization.text, input);
          expect(normalization.changed, isFalse);
          expect(normalization.text, isNot(contains(r'\end{')));
          expect(normalization.renderability.isRenderable, isFalse);

          await tester.pumpWidget(host(input));
          await tester.pump();

          expect(find.textContaining('Before'), findsWidgets);
          expect(find.textContaining('after'), findsWidgets);
          expect(
            find.textContaining(
              r'\begin{',
              findRichText: true,
            ),
            findsWidgets,
          );
          expect(find.byType(Math), findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      r'\textcircled passes preflight but falls back to the original formula',
      (tester) async {
        const input = r'Synthetic \(\textcircled{1}\)';
        final renderability = const LatexRenderabilityChecker().check(input);

        expect(renderability.isRenderable, isTrue);
        await tester.pumpWidget(host(input));
        await tester.pump();

        expect(find.byType(Math), findsOneWidget);
        expect(
          find.textContaining(
            r'\textcircled{1}',
            findRichText: true,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
