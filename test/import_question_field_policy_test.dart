import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_filter.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';

void main() {
  group('ImportQuestionFieldPolicy', () {
    const policy = ImportQuestionFieldPolicy();

    test('default clears final explanation but preserves raw for types 0, 1, 2',
        () {
      for (final type in const [0, 1, 2]) {
        final result = policy.applyToMap({
          'question_number': type + 1,
          'type': type,
          'content': 'Question',
          'options': const <String>[],
          'standard_answer': 'Answer',
          'explanation': 'Long explanation',
          'raw_explanation': 'Raw explanation',
        });

        expect(result['explanation'], isEmpty);
        expect(result['raw_explanation'], 'Raw explanation');
      }
    });

    test('type 3 preserves explanation by default', () {
      const explanation = r'Keep \(\textcircled{1}\) exactly';
      const rawExplanation = ' raw\nprovenance ';
      final result = policy.applyToMap({
        'question_number': 3,
        'type': 3,
        'content': 'Question',
        'options': const <String>[],
        'standard_answer': 'Answer',
        'explanation': explanation,
        'raw_explanation': rawExplanation,
      });

      expect(result['explanation'], same(explanation));
      expect(result['raw_explanation'], same(rawExplanation));
    });

    test('document mode retains choice and fill explanations', () {
      for (final type in const [0, 2]) {
        final result = policy.applyToMap(
          {
            'type': type,
            'explanation': '',
            'raw_explanation': 'Raw explanation',
          },
          mode: ExplanationRetentionMode.allQuestionTypes,
        );

        expect(result['explanation'], 'Raw explanation');
        expect(result['raw_explanation'], 'Raw explanation');
      }
    });

    test('per-question keep overrides document off', () {
      final result = policy.applyToMap(
        {
          'type': 0,
          'explanation': '',
          'raw_explanation': 'Raw explanation',
        },
        override: QuestionExplanationOverride.keep,
      );

      expect(result['explanation'], 'Raw explanation');
    });

    test('per-question discard overrides document on', () {
      final result = policy.applyToMap(
        {
          'type': 2,
          'explanation': 'Visible explanation',
          'raw_explanation': 'Raw explanation',
        },
        mode: ExplanationRetentionMode.allQuestionTypes,
        override: QuestionExplanationOverride.discard,
      );

      expect(result['explanation'], isEmpty);
      expect(result['raw_explanation'], 'Raw explanation');
    });

    test('discarded LaTeX and HTML clear stale derived issues', () {
      final result = finalizeAndAuditImportQuestions([
        {
          'question_number': 1,
          'type': 0,
          'content': r'Valid \(x\)',
          'options': const ['A', 'B'],
          'standard_answer': 'A',
          'explanation': '',
          'raw_explanation':
              r'Broken \(\begin{matrix}1\end{pmatrix}\) <table>x</table>',
          'diagnostics': const [
            'dangling_latex',
            'raw_html_tag',
            'unrelated',
          ],
          '_import_review': const {
            'riskHints': [
              latexUnrenderableIssue,
              rawHtmlTagIssue,
              'existing_risk',
            ],
          },
        },
      ]).single;

      expect(result['explanation'], isEmpty);
      expect(result['raw_explanation'], contains('<table>'));
      expect(
        (result['_import_review'] as Map)['riskHints'],
        ['existing_risk'],
      );
      expect(
        (result['_import_review'] as Map)['repairCandidateCodes'],
        isEmpty,
      );
      expect(result['diagnostics'], ['unrelated']);
    });

    test('enabled damaged explanation reaches analyzer and warning filter', () {
      final finalized = finalizeAndAuditImportQuestions(
        [
          {
            'question_number': 1,
            'type': 0,
            'content': 'Valid question',
            'options': const ['A', 'B'],
            'standard_answer': 'A',
            'explanation': '',
            'raw_explanation':
                r'Broken \(\begin{matrix}1\end{pmatrix}\) <table>x</table>',
          },
        ],
        mode: ExplanationRetentionMode.allQuestionTypes,
      ).single;
      final items = [ImportReviewItem.fromMap(finalized, 0)];
      final analysis = ImportReviewAnalyzer.analyzeItems(items);
      final warnings = ImportReviewFilterService.apply(
        items: items,
        analysis: analysis,
        filter: ImportReviewFilter.warningsOnly,
        sort: ImportReviewSort.originalOrder,
      );

      expect(
        analysis.issues.map((issue) => issue.code),
        containsAll([
          ImportReviewIssueCode.latexUnrenderable,
          ImportReviewIssueCode.rawHtmlTag,
        ]),
      );
      expect(analysis.summary.warningCount, 2);
      expect(analysis.summary.qualityScore, lessThan(100));
      expect(warnings, hasLength(1));
      expect(
        (finalized['_import_review'] as Map)['repairCandidateCodes'],
        contains('dangling_latex'),
      );
    });

    test('enabled safe HTML wrappers are cleaned from final explanation', () {
      final result = finalizeAndAuditImportQuestions(
        [
          {
            'type': 2,
            'content': 'Question',
            'options': const <String>[],
            'standard_answer': '42',
            'explanation': '',
            'raw_explanation': '<div>First<br>Second</div>',
          },
        ],
        mode: ExplanationRetentionMode.allQuestionTypes,
      ).single;

      expect(result['explanation'], 'First\nSecond');
      expect(result['raw_explanation'], '<div>First<br>Second</div>');
      expect(
        (result['_import_review'] as Map?)?['riskHints'],
        isNot(contains(rawHtmlTagIssue)),
      );
    });

    test('draft policy keeps raw in staging and strips it for commit', () {
      const objective = QuestionDraft(
        type: QuestionType.fillBlank,
        content: 'Fill question',
        options: [],
        standardAnswer: '42',
        explanation: 'Drop',
        rawExplanation: 'Drop raw',
      );
      const subjective = QuestionDraft(
        type: QuestionType.shortAnswer,
        content: 'Subjective question',
        options: [],
        standardAnswer: 'Conclusion',
        explanation: 'Keep',
        rawExplanation: 'Keep raw',
      );

      final objectiveResult = policy.applyToDraft(objective);
      final subjectiveResult = policy.applyToDraft(subjective);
      final committedObjective = policy.applyToDraft(
        objective,
        mode: ExplanationRetentionMode.allQuestionTypes,
        preserveRawExplanation: false,
      );

      expect(objectiveResult.explanation, isEmpty);
      expect(objectiveResult.rawExplanation, 'Drop raw');
      expect(subjectiveResult.explanation, 'Keep');
      expect(subjectiveResult.rawExplanation, 'Keep raw');
      expect(committedObjective.explanation, 'Drop');
      expect(committedObjective.rawExplanation, isNull);
    });

    test('policy is idempotent and preserves 22-question count and order', () {
      final questions = List.generate(
        22,
        (index) => <String, dynamic>{
          'question_number': index + 1,
          'type': index < 14 ? (index < 8 ? 0 : 2) : 3,
          'content': 'Question ${index + 1}',
          'options': index < 8 ? const ['A', 'B'] : const <String>[],
          'standard_answer': 'A',
          'explanation': '',
          'raw_explanation': 'Raw ${index + 1}',
        },
      );

      final once = policy.applyToMaps(questions);
      final twice = policy.applyToMaps(once);

      expect(twice, equals(once));
      expect(twice, hasLength(22));
      expect(
        twice.map((question) => question['question_number']),
        orderedEquals(List.generate(22, (index) => index + 1)),
      );
    });

    test('unknown map type is preserved defensively', () {
      final result = policy.applyToMap({
        'type': 99,
        'explanation': 'Keep unknown',
        'raw_explanation': 'Keep raw unknown',
      });

      expect(result['explanation'], 'Keep unknown');
      expect(result['raw_explanation'], 'Keep raw unknown');
    });
  });
}
