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

    expect(
      locator.locate(
        reviewItemId: _reviewId,
        expectedRevision: 1,
        snapshot: snapshot,
        current: _current(explanation: legacy),
        fields: const <LatexFragmentField>{LatexFragmentField.explanation},
        isRenderable: _isRenderable,
        digest: (value) => 'digest:${value.length}',
      ),
      isNull,
    );
  });

  test('fails closed for baseline drift and unsupported nodes', () {
    expect(
      locator.locate(
        reviewItemId: _reviewId,
        expectedRevision: 1,
        snapshot: _snapshot(),
        current: _current(explanation: 'changed'),
        fields: const <LatexFragmentField>{LatexFragmentField.explanation},
        isRenderable: _isRenderable,
        digest: (value) => 'digest:${value.length}',
      ),
      isNull,
    );

    final unsupported = _snapshot(
      explanation: RichContent(nodes: <ContentNode>[
        RawFallbackNode(<String, Object?>{
          'type': 'future_node',
          'payload': 'redacted',
        }),
      ]),
    );
    expect(
      locator.locate(
        reviewItemId: _reviewId,
        expectedRevision: 1,
        snapshot: unsupported,
        current: _current(),
        fields: const <LatexFragmentField>{LatexFragmentField.explanation},
        isRenderable: _isRenderable,
        digest: (value) => 'digest:${value.length}',
      ),
      isNull,
    );
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
