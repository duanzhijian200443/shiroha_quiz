import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/latex_fragment_repair.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_renderability_checker.dart';

const _reviewId = '44444444-4444-4444-8444-000000000021';
const _questionId = '22222222-2222-4222-8222-000000000021';
const _legacy = r'前 \(a\) 中 \(\begin{matrix}1\) 后 \(c\)';

TypedReviewSnapshot _snapshot({RichContent? explanation}) {
  return TypedReviewSnapshot(
    reviewItemId: _reviewId,
    questionId: _questionId,
    draft: QuestionDraftV2(
      questionId: _questionId,
      kind: QuestionKind.shortAnswer,
      questionNumber: 21,
      stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
      explanation: explanation ??
          RichContent(nodes: const <ContentNode>[
            TextNode('前 '),
            InlineMathNode('a'),
            TextNode(' 中 '),
            InlineMathNode(r'\begin{matrix}1'),
            TextNode(' 后 '),
            InlineMathNode('c'),
          ]),
    ),
    baselineLegacy: LegacyReviewBaseline(
      type: 3,
      questionNumber: 21,
      content: 'Stem',
      options: const <String>[],
      standardAnswer: '',
      explanation: _legacy,
    ),
  );
}

LatexFragmentLegacyView _current({String explanation = _legacy}) {
  return LatexFragmentLegacyView(
    content: 'Stem',
    options: const <String>[],
    standardAnswer: '',
    explanation: explanation,
  );
}

bool _isRenderable(String latex) => const LatexRenderabilityChecker()
    .check(latex, requireMathContext: false, assumeMathContext: true)
    .isRenderable;

void main() {
  const locator = LatexFragmentLocator();

  test('locates exactly one invalid typed math node and exact inner span', () {
    final target = locator.locate(
      reviewItemId: _reviewId,
      expectedRevision: 7,
      snapshot: _snapshot(),
      current: _current(),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );

    expect(target, isNotNull);
    expect(target!.nodeIndex, 3);
    expect(target.nodeKind, LatexFragmentNodeKind.inlineMath);
    expect(target.originalLatex, r'\begin{matrix}1');
    expect(
      _legacy.substring(target.legacyStart, target.legacyEnd),
      target.originalLatex,
    );
    expect(target.precedingContext, ' 中 ');
    expect(target.followingContext, ' 后 ');
  });

  test('bounds context to adjacent text nodes only', () {
    final before = '前' * 300;
    final after = '后' * 300;
    final legacy = '$before\\(${r'\begin{matrix}1'}\\)$after';
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _reviewId,
      questionId: _questionId,
      draft: QuestionDraftV2(
        questionId: _questionId,
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
        explanation: RichContent(nodes: <ContentNode>[
          TextNode(before),
          const InlineMathNode(r'\begin{matrix}1'),
          TextNode(after),
        ]),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: 21,
        content: 'Stem',
        options: const <String>[],
        standardAnswer: '',
        explanation: legacy,
      ),
    );

    final target = locator.locate(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: snapshot,
      current: _current(explanation: legacy),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );

    expect(target, isNotNull);
    expect(target!.precedingContext.runes.length, 256);
    expect(target.followingContext.runes.length, 256);
  });

  test('fails closed for multiple invalid nodes', () {
    const legacy = r'前 \(\begin{matrix}1\) 后 \(\begin{array}2\)';
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _reviewId,
      questionId: _questionId,
      draft: QuestionDraftV2(
        questionId: _questionId,
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
        explanation: RichContent(nodes: const <ContentNode>[
          TextNode('前 '),
          InlineMathNode(r'\begin{matrix}1'),
          TextNode(' 后 '),
          InlineMathNode(r'\begin{array}2'),
        ]),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: 21,
        content: 'Stem',
        options: const <String>[],
        standardAnswer: '',
        explanation: legacy,
      ),
    );

    final result = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: snapshot,
      current: _current(explanation: legacy),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );

    expect(result.target, isNull);
    expect(
      result.diagnostic.classification,
      LatexFragmentLocateClassification.candidateMultiple,
    );
    expect(result.diagnostic.candidateCount, 2);
    expect(result.diagnostic.unrenderableMathNodeCount, 2);
    expect(result.diagnostic.nodeShapes, hasLength(2));
  });

  test('fails closed for baseline drift and unsupported nodes', () {
    final drifted = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: _snapshot(),
      current: _current(explanation: 'changed'),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );
    expect(drifted.target, isNull);
    expect(
      drifted.diagnostic.classification,
      LatexFragmentLocateClassification.baselineDrift,
    );

    final unsupported = _snapshot(
      explanation: RichContent(nodes: <ContentNode>[
        RawFallbackNode(<String, Object?>{
          'type': 'future_node',
          'payload': 'redacted',
        }),
      ]),
    );
    final unsupportedResult = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: unsupported,
      current: _current(),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );
    expect(unsupportedResult.target, isNull);
    expect(
      unsupportedResult.diagnostic.classification,
      LatexFragmentLocateClassification.unsupportedNodeKind,
    );
    expect(unsupportedResult.diagnostic.unsupportedNodeCount, 1);
  });

  test('distinguishes zero candidates from typed legacy alignment failures',
      () {
    const cleanLegacy = r'前 \(x^2\) 后';
    final cleanSnapshot = _snapshot(
      explanation: RichContent(nodes: const <ContentNode>[
        TextNode('前 '),
        InlineMathNode('x^2'),
        TextNode(' 后'),
      ]),
    );
    final zero = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: TypedReviewSnapshot(
        reviewItemId: cleanSnapshot.reviewItemId,
        questionId: cleanSnapshot.questionId,
        draft: cleanSnapshot.draft,
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: <String>[],
          standardAnswer: '',
          explanation: cleanLegacy,
        ),
      ),
      current: _current(explanation: cleanLegacy),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );
    expect(
      zero.diagnostic.classification,
      LatexFragmentLocateClassification.candidateZero,
    );
    expect(zero.diagnostic.mathNodeCount, 1);
    expect(zero.diagnostic.candidateCount, 0);

    final countMismatch = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: _snapshot(
        explanation: RichContent(nodes: const <ContentNode>[
          TextNode(_legacy),
        ]),
      ),
      current: _current(),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );
    expect(
      countMismatch.diagnostic.classification,
      LatexFragmentLocateClassification.typedLegacyNodeCountMismatch,
    );
    expect(countMismatch.diagnostic.typedNodeCount, 1);
    expect(countMismatch.diagnostic.legacySpanCount, 6);
  });

  test('non-target normalization mismatches do not hide the unique bad node',
      () {
    LatexFragmentLocateResult inspect({
      required String legacy,
      required List<ContentNode> nodes,
    }) {
      final snapshot = TypedReviewSnapshot(
        reviewItemId: _reviewId,
        questionId: _questionId,
        draft: QuestionDraftV2(
          questionId: _questionId,
          kind: QuestionKind.shortAnswer,
          questionNumber: 21,
          stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
          explanation: RichContent(nodes: nodes),
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: const <String>[],
          standardAnswer: '',
          explanation: legacy,
        ),
      );
      return locator.inspect(
        reviewItemId: _reviewId,
        expectedRevision: 1,
        snapshot: snapshot,
        current: _current(explanation: legacy),
        fields: const <LatexFragmentField>{LatexFragmentField.explanation},
        isRenderable: _isRenderable,
        digest: (value) => 'digest:${value.length}',
      );
    }

    final mathResult = inspect(
      legacy: r'前 \(\begin{matrix}2\) 后',
      nodes: const <ContentNode>[
        TextNode('前 '),
        InlineMathNode(r'\begin{matrix}1'),
        TextNode(' 后'),
      ],
    );
    final mathDiagnostic = mathResult.diagnostic;
    expect(
      mathDiagnostic.classification,
      LatexFragmentLocateClassification.targetAvailable,
    );
    expect(mathResult.target!.originalLatex, r'\begin{matrix}2');
    expect(mathDiagnostic.uniqueUnrenderableNodeIndex, 1);
    expect(
      mathDiagnostic.uniqueUnrenderableNodeKind,
      LatexFragmentNodeKind.inlineMath,
    );
    expect(mathDiagnostic.mismatchNodeIndex, 1);
    expect(mathDiagnostic.mismatchTypedKind, 'inline_math');
    expect(mathDiagnostic.mismatchLegacyKind, 'inline_math');
    expect(mathDiagnostic.mismatchTypedCharacterLength, 15);
    expect(mathDiagnostic.mismatchLegacyCharacterLength, 15);
    expect(mathDiagnostic.mismatchAtUnrenderableMathNode, isTrue);

    final textResult = inspect(
      legacy: r'甲 \(\begin{matrix}1\) 后',
      nodes: const <ContentNode>[
        TextNode('乙 '),
        InlineMathNode(r'\begin{matrix}1'),
        TextNode(' 后'),
      ],
    );
    final textDiagnostic = textResult.diagnostic;
    expect(textDiagnostic.classification,
        LatexFragmentLocateClassification.targetAvailable);
    expect(textResult.target!.nodeIndex, 1);
    expect(textDiagnostic.uniqueUnrenderableNodeIndex, 1);
    expect(textDiagnostic.mismatchNodeIndex, 0);
    expect(textDiagnostic.mismatchTypedKind, 'text');
    expect(textDiagnostic.mismatchLegacyKind, 'text');
    expect(textDiagnostic.mismatchTypedCharacterLength, 2);
    expect(textDiagnostic.mismatchLegacyCharacterLength, 2);
    expect(textDiagnostic.mismatchAtUnrenderableMathNode, isFalse);
  });

  test('Q21-shaped early mismatch still locates the bad node at index 95', () {
    final nodes = <ContentNode>[];
    final legacy = StringBuffer();
    for (var mathIndex = 0; mathIndex < 57; mathIndex++) {
      final text = 't$mathIndex ';
      nodes.add(TextNode(text));
      legacy.write(text);
      if (mathIndex == 47) {
        nodes.add(const InlineMathNode(r'\begin{matrix}1'));
        legacy.write(r'\(\begin{matrix}1\)');
      } else if (mathIndex == 0) {
        nodes.add(const InlineMathNode('normalized'));
        legacy.write(r'\(legacy_normalized\)');
      } else {
        nodes.add(InlineMathNode('x_$mathIndex'));
        legacy
          ..write(r'\(')
          ..write('x_$mathIndex')
          ..write(r'\)');
      }
    }
    nodes.add(const TextNode('tail'));
    legacy.write('tail');
    final legacyText = legacy.toString();
    final result = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: TypedReviewSnapshot(
        reviewItemId: _reviewId,
        questionId: _questionId,
        draft: QuestionDraftV2(
          questionId: _questionId,
          kind: QuestionKind.shortAnswer,
          questionNumber: 21,
          stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
          explanation: RichContent(nodes: nodes),
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: const <String>[],
          standardAnswer: '',
          explanation: legacyText,
        ),
      ),
      current: _current(explanation: legacyText),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );

    expect(result.diagnostic.typedNodeCount, 115);
    expect(result.diagnostic.legacySpanCount, 115);
    expect(result.diagnostic.mathNodeCount, 57);
    expect(result.diagnostic.unrenderableMathNodeCount, 1);
    expect(result.diagnostic.mismatchNodeIndex, 1);
    expect(result.diagnostic.mismatchAtUnrenderableMathNode, isFalse);
    expect(result.target!.nodeIndex, 95);
    expect(result.target!.originalLatex, r'\begin{matrix}1');
  });

  test('fails closed when the typed target is bad but legacy target is valid',
      () {
    const legacy = r'前 \(x^2\) 后';
    final result = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: TypedReviewSnapshot(
        reviewItemId: _reviewId,
        questionId: _questionId,
        draft: QuestionDraftV2(
          questionId: _questionId,
          kind: QuestionKind.shortAnswer,
          questionNumber: 21,
          stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
          explanation: RichContent(nodes: const <ContentNode>[
            TextNode('前 '),
            InlineMathNode(r'\begin{matrix}1'),
            TextNode(' 后'),
          ]),
        ),
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 21,
          content: 'Stem',
          options: const <String>[],
          standardAnswer: '',
          explanation: legacy,
        ),
      ),
      current: _current(explanation: legacy),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );

    expect(result.target, isNull);
    expect(
      result.diagnostic.classification,
      LatexFragmentLocateClassification.targetLegacyRenderabilityMismatch,
    );
    expect(result.diagnostic.mismatchAtUnrenderableMathNode, isTrue);
  });

  test('diagnostic metadata is bounded and contains no node content', () {
    final nodes = <ContentNode>[];
    final legacy = StringBuffer();
    for (var index = 0; index < 40; index++) {
      nodes.add(InlineMathNode('x_$index'));
      legacy.write('\\(x_$index\\)');
    }
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _reviewId,
      questionId: _questionId,
      draft: QuestionDraftV2(
        questionId: _questionId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 21,
        stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
        explanation: RichContent(nodes: nodes),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: 21,
        content: 'Stem',
        options: const <String>[],
        standardAnswer: '',
        explanation: legacy.toString(),
      ),
    );

    final result = locator.inspect(
      reviewItemId: _reviewId,
      expectedRevision: 1,
      snapshot: snapshot,
      current: _current(explanation: legacy.toString()),
      fields: const <LatexFragmentField>{LatexFragmentField.explanation},
      isRenderable: _isRenderable,
      digest: (value) => 'digest:${value.length}',
    );
    final serialized = result.diagnostic.diagnosticData.toString();

    expect(result.diagnostic.nodeShapes, hasLength(32));
    expect(result.diagnostic.nodeShapesTruncated, isTrue);
    expect(serialized, isNot(contains('x_0')));
  });

  test('option target binds the stable option identity and body span', () {
    const option = r'A. 前 \(\begin{matrix}1\) 后';
    const body = r'前 \(\begin{matrix}1\) 后';
    final snapshot = TypedReviewSnapshot(
      reviewItemId: _reviewId,
      questionId: _questionId,
      draft: QuestionDraftV2(
        questionId: _questionId,
        kind: QuestionKind.singleChoice,
        questionNumber: 21,
        stem: RichContent(nodes: const <ContentNode>[TextNode('Stem')]),
        options: <QuestionOption>[
          QuestionOption(
            optionId: 'option_a',
            label: 'A',
            content: RichContent(nodes: const <ContentNode>[
              TextNode('前 '),
              InlineMathNode(r'\begin{matrix}1'),
              TextNode(' 后'),
            ]),
          ),
        ],
        answer: ChoiceAnswer(optionIds: const <String>['option_a']),
      ),
      baselineLegacy: LegacyReviewBaseline(
        type: 0,
        questionNumber: 21,
        content: 'Stem',
        options: const <String>[option],
        standardAnswer: 'A',
        explanation: '',
      ),
    );

    final target = locator.locate(
      reviewItemId: _reviewId,
      expectedRevision: 2,
      snapshot: snapshot,
      current: LatexFragmentLegacyView(
        content: 'Stem',
        options: const <String>[option],
        standardAnswer: 'A',
        explanation: '',
      ),
      fields: const <LatexFragmentField>{LatexFragmentField.options},
      isRenderable: _isRenderable,
      digest: (value) => <Object>['digest:', value.length].join(),
    );

    expect(target, isNotNull);
    expect(target!.field, LatexFragmentField.options);
    expect(target.optionId, 'option_a');
    expect(
      body.substring(target.legacyStart, target.legacyEnd),
      r'\begin{matrix}1',
    );
  });
}
