import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_repair_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_sanity_checker.dart';
import 'package:shiroha_quiz/services/import_review/import_review_analyzer.dart';
import 'package:shiroha_quiz/services/import_review/import_review_filter.dart';
import 'package:shiroha_quiz/services/import_review/import_review_issue.dart';
import 'package:shiroha_quiz/services/import_review/import_review_item.dart';

void main() {
  group('LaTeX control word boundaries', () {
    const checker = LatexSanityChecker();

    test('arrow commands are not left or right delimiters', () {
      for (final command in const [
        r'\rightarrow',
        r'\leftarrow',
        r'\leftrightarrow',
        r'\Rightarrow',
        r'\Leftarrow',
        r'\Leftrightarrow',
        r'\longrightarrow',
        r'\longleftarrow',
        r'\Longrightarrow',
        r'\Longleftarrow',
      ]) {
        expect(
          checker.hasDanglingDelimiters(command),
          isFalse,
          reason: command,
        );
        expect(repairLatexDeterministically(command), command);
      }
    });

    test('standalone left and right commands retain structural checks', () {
      expect(checker.hasDanglingDelimiters(r'\left(x\right)'), isFalse);
      expect(checker.hasDanglingDelimiters(r'\left(x'), isTrue);
      expect(checker.hasDanglingDelimiters(r'x\right)'), isTrue);
      expect(
        checker.hasDanglingDelimiters(r'\left.\frac{x}{y}\right|'),
        isFalse,
      );
    });

    test('arrow commands produce no latex risk or repair candidate', () {
      final result = auditFinalQuestionLatex(
        _question(content: r'Mapping \(A \rightarrow B\)'),
      );

      expect(result.invalidFields, isEmpty);
      expect(_riskHints(result.question), isEmpty);
      expect(
        const ImportQuestionRepairPolicy().candidateCodes(result.question),
        isNot(contains(ImportQuestionRepairPolicy.danglingLatexCode)),
      );
    });
  });

  group('auditFinalQuestionLatex', () {
    test('deterministically repairs an unpaired left command', () {
      final result = auditFinalQuestionLatex(_question(
        explanation: r'Explanation \(\left(x + 1\)',
      ));

      expect(result.invalidFields, isEmpty);
      expect(result.question['explanation'], r'Explanation \((x + 1\)');
      expect(_riskHints(result.question), isEmpty);
    });

    test('does not invent a missing environment terminator', () {
      final result = auditFinalQuestionLatex(_question(
        explanation: r'Explanation \(\begin{matrix}1 & 2',
      ));

      expect(result.invalidFields, ['explanation']);
      expect(
        result.question['explanation'],
        r'Explanation \(\begin{matrix}1 & 2\)',
      );
      expect(_riskHints(result.question), [latexUnrenderableIssue]);
    });

    test('leaves an ambiguous surplus right command for review', () {
      final result = auditFinalQuestionLatex(_question(
        explanation: r'Explanation \(\left(x\right)\right)',
      ));

      expect(result.invalidFields, ['explanation']);
      expect(
        result.question['explanation'],
        r'Explanation \(\left(x\right)\right)\)',
      );
      expect(_riskHints(result.question), [latexUnrenderableIssue]);
    });

    test('detects damaged content delimiters', () {
      final result = auditFinalQuestionLatex(_question(
        content: r'Question with x + 1\)',
      ));

      expect(result.invalidFields, ['content']);
      expect(_riskHints(result.question), [latexUnrenderableIssue]);
    });

    test('collapses multiple damaged options into one field issue', () {
      final result = auditFinalQuestionLatex(_question(
        options: const [
          r'\(\begin{matrix}a\end{pmatrix}\)',
          r'\(\right)b\)',
          r'\(c\)',
          r'\left(d\right)',
        ],
      ));

      expect(result.invalidFields, ['options']);
      expect(_riskHints(result.question), [latexUnrenderableIssue]);
    });

    test('normal formulas do not produce an issue', () {
      final question = _question(
        content: r'Question \(x + 1\)',
        options: const [r'\(a\)', r'\left(b\right)'],
        standardAnswer: r'\(a\)',
        explanation: r'\[\left(x + 1\right)^2\]',
      );

      final result = auditFinalQuestionLatex(question);

      expect(result.invalidFields, isEmpty);
      expect(_riskHints(result.question), isEmpty);
      expect(result.question, question);
    });

    test('normal array cases and matrix environments remain byte equivalent',
        () {
      const checker = LatexSanityChecker();
      for (final formula in const [
        r'\[\begin{array}{cc}1&2\\3&4\end{array}\]',
        r'\[\begin{cases}x&x>0\\-x&x\leq0\end{cases}\]',
        r'\(\begin{matrix}1&2\\3&4\end{matrix}\)',
      ]) {
        expect(repairLatexDeterministically(formula), formula);
        expect(checker.hasDanglingDelimiters(formula), isFalse);
      }
    });

    test('normalizes a bare block environment before final audit', () {
      const explanation =
          r'展开可得，\{\begin{array}{l}x_1=1\\x_2=2\end{array}于是成立。';

      final result =
          auditFinalQuestionLatex(_question(explanation: explanation));

      expect(result.invalidFields, isEmpty);
      expect(
        result.question['explanation'],
        r'展开可得，\[\{\begin{array}{l}x_1=1\\x_2=2\end{array}\]于是成立。',
      );
      expect(_riskHints(result.question), isEmpty);
    });

    test('keeps Q21-like missing array terminator as canonical review', () {
      const explanation = r'''Before.
$$\begin{array}{l}
x_1=1\\
x_2=2
$$
说明文字。
$$\begin{array}{l}y_1=3\\y_2=4\end{array}$$''';
      final question = _question(
        questionNumber: 21,
        explanation: explanation,
      );
      question['diagnostics'] = const ['dangling_latex'];
      final metadata = question['_import_review'] as Map<String, dynamic>;
      metadata['repairCandidateCodes'] = const ['dangling_latex'];

      final result = finalizeAndAuditImportQuestion(question);
      final finalMetadata = result['_import_review'] as Map<String, dynamic>;

      expect(result['explanation'], explanation);
      expect(result['diagnostics'], isNot(contains('dangling_latex')));
      expect(finalMetadata['riskHints'], [latexUnrenderableIssue]);
      expect(finalMetadata[latexInvalidFieldsKey], ['explanation']);
      expect(finalMetadata['repairCandidateCodes'], isEmpty);
    });

    test('keeps control-word-adjacent bare environments for review', () {
      for (final explanation in const [
        r'\text{\begin{matrix}1\end{matrix}}',
        r'\operatorname{foo}\begin{matrix}1\end{matrix}',
        r'\color{red}\begin{matrix}1\end{matrix}',
        r'\text {1}\begin{matrix}2\end{matrix}',
        r'\operatorname {+}\begin{matrix}1\end{matrix}',
        r'\color {1}\begin{matrix}2\end{matrix}',
      ]) {
        final result =
            auditFinalQuestionLatex(_question(explanation: explanation));

        expect(result.invalidFields, ['explanation'], reason: explanation);
        expect(
          result.question['explanation'],
          explanation,
          reason: explanation,
        );
        expect(
          _riskHints(result.question),
          [latexUnrenderableIssue],
          reason: explanation,
        );
      }
    });

    test('records only safe invalid field names for analyzer messaging', () {
      final result = auditFinalQuestionLatex(_question(
        explanation: r'\begin{array}{l}x',
      ));
      final metadata =
          result.question['_import_review'] as Map<String, dynamic>;
      final item = ImportReviewItem.fromMap(result.question, 0);
      final analysis = ImportReviewAnalyzer.analyzeItems([item]);

      expect(metadata[latexInvalidFieldsKey], ['explanation']);
      expect(analysis.issues.single.message, contains('解析中的 LaTeX'));
      expect(analysis.summary.warningCount, 1);
      expect(analysis.summary.qualityScore, lessThan(100));
    });

    test('detects mismatched LaTeX environments', () {
      final result = auditFinalQuestionLatex(_question(
        explanation: r'Explanation \(\begin{matrix}1 & 2\end{pmatrix}\)',
      ));

      expect(result.invalidFields, ['explanation']);
      expect(_riskHints(result.question), [latexUnrenderableIssue]);
    });

    test('deduplicates fields and emits one stable issue per question', () {
      final result = auditFinalQuestionLatex(_question(
        content: r'Question x\)',
        options: const [r'\(\begin{matrix}a\end{pmatrix}\)'],
        standardAnswer: r'answer\]',
        explanation: r'\(\right)explanation\)',
        riskHints: const ['existing_risk', latexUnrenderableIssue],
      ));

      expect(
        result.invalidFields,
        ['content', 'options', 'standard_answer', 'explanation'],
      );
      expect(
        _riskHints(result.question),
        ['existing_risk', latexUnrenderableIssue],
      );
    });

    test('preserves the count and order of 22 final questions', () {
      final questions = List.generate(
        22,
        (index) => _question(
          questionNumber: index + 1,
          explanation: index == 20
              ? r'Explanation \(\left(x\right)\right)'
              : r'Explanation \(x + 1\)',
        ),
      );

      final audited = questions.map(auditFinalQuestionLatex).toList();

      expect(audited, hasLength(22));
      expect(
        audited.map((result) => result.question['question_number']).toList(),
        List.generate(22, (index) => index + 1),
      );
      expect(
        audited.where((result) => result.hasUnrenderableLatex),
        hasLength(1),
      );
    });
  });

  test('latex issue reaches analyzer score and warning filter', () {
    final audited = auditFinalQuestionLatex(_question(
      explanation: r'Explanation \(\begin{matrix}1\end{pmatrix}\)',
    ));
    final items = [ImportReviewItem.fromMap(audited.question, 0)];

    final analysis = ImportReviewAnalyzer.analyzeItems(items);
    final warnings = ImportReviewFilterService.apply(
      items: items,
      analysis: analysis,
      filter: ImportReviewFilter.warningsOnly,
      sort: ImportReviewSort.originalOrder,
    );

    expect(analysis.summary.warningCount, 1);
    expect(analysis.summary.qualityScore, lessThan(100));
    expect(
      analysis.issues.single.code,
      ImportReviewIssueCode.latexUnrenderable,
    );
    expect(warnings, hasLength(1));
    expect(warnings.single.canonicalIndex, 0);
  });
}

Map<String, dynamic> _question({
  int questionNumber = 1,
  String content = 'Question content',
  List<String> options = const [],
  String standardAnswer = 'Answer',
  String explanation = 'Explanation',
  List<String> riskHints = const [],
}) {
  return {
    'question_number': questionNumber,
    'type': 3,
    'content': content,
    'options': options,
    'standard_answer': standardAnswer,
    'explanation': explanation,
    '_import_review': {
      'source': 'ocr',
      'sources': ['ocr'],
      'fragmentKinds': const <String>[],
      'originalIndices': [questionNumber - 1],
      'riskHints': riskHints,
    },
  };
}

List<String> _riskHints(Map<String, dynamic> question) {
  final metadata = question['_import_review'] as Map<String, dynamic>;
  return (metadata['riskHints'] as List).cast<String>();
}
