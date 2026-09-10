// Vertical contract for AI review repair: an accepted repair must survive the
// typed review commit with a structural, renderable representation instead of
// degrading to one literal text node. Synthetic fixtures only; no Provider,
// Replay, network, database, filesystem or application call site.
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_edit.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

const String _sourceId = '11111111-1111-4111-8111-111111111111';
const String _questionId = '22222222-2222-4222-8222-222222222222';
const String _reviewItemId = '44444444-4444-4444-8444-444444444444';
const String _taskId = 'review-repair-vertical-task';
const String _attemptToken = 'review-repair-vertical-attempt';

const String _brokenExplanation = r'推导 \(\begin{matrix}1 不完整';
const String _repairedExplanation =
    r'推导 \(\begin{matrix}1\end{matrix}\) 完整，且 $$\int_0^1 x\,dx=\frac{1}{2}$$';

List<SourceRef> _sourceRefs() {
  return <SourceRef>[
    SourceRef.document(sourceId: _sourceId, displayLabel: null)
  ];
}

List<SourcedAssetRef> _assetRefs() {
  return <SourcedAssetRef>[
    SourcedAssetRef(
      sourceId: _sourceId,
      asset: AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
      ),
    ),
  ];
}

QuestionDraftV2 _draft({bool withStemImage = false}) {
  return QuestionDraftV2(
    questionId: _questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 21,
    stem: RichContent(nodes: <ContentNode>[
      const TextNode('Stem '),
      const InlineMathNode('x+1'),
      if (withStemImage)
        ImageNode(sourceId: _sourceId, localAssetId: 'asset_001'),
    ]),
    answer: ContentAnswer(
      content: RichContent(nodes: <ContentNode>[const TextNode('Answer')]),
    ),
    explanation: RichContent(nodes: <ContentNode>[
      const TextNode('推导 '),
      const InlineMathNode(r'\begin{matrix}1'),
    ]),
    sourceRefs: _sourceRefs(),
    assetRefs: withStemImage ? _assetRefs() : const <SourcedAssetRef>[],
    issues: <ImportIssue>[
      ImportIssue(
        code: 'latex_unrenderable',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.explanation,
      ),
    ],
  );
}

TypedReviewSnapshot _snapshot({bool withStemImage = false}) {
  return TypedReviewSnapshot(
    reviewItemId: _reviewItemId,
    questionId: _questionId,
    draft: _draft(withStemImage: withStemImage),
    baselineLegacy: LegacyReviewBaseline(
      type: 3,
      questionNumber: 21,
      content: 'Stem x+1',
      options: const <String>[],
      standardAnswer: 'Answer',
      explanation: _brokenExplanation,
    ),
  );
}

QuestionDraft _currentDraft({String? explanation}) {
  return QuestionDraft(
    type: QuestionType.shortAnswer,
    content: 'Stem x+1',
    options: const <String>[],
    standardAnswer: 'Answer',
    explanation: explanation ?? _brokenExplanation,
  );
}

ReviewRepairEdit _markerFor({
  required QuestionDraft before,
  required QuestionDraft after,
}) {
  return ReviewRepairEdit.applied(
    before: before,
    after: after,
    fields: const <ReviewRepairField>[ReviewRepairField.explanation],
  );
}

TypedReviewBuildResult _build({
  required QuestionDraft current,
  ReviewRepairEdit? repairEdit,
  bool withStemImage = false,
}) {
  return TypedReviewResultBuilder(
    sessionIdFactory: () => 'review_vertical_session',
  ).build(
    inputs: <TypedReviewCommitInput>[
      TypedReviewCommitInput(
        reviewItemId: _reviewItemId,
        envelope: const TypedReviewSnapshotCodec()
            .encode(_snapshot(withStemImage: withStemImage)),
        currentDraft: current,
        repairEdit: repairEdit,
      ),
    ],
    taskId: _taskId,
    attemptToken: _attemptToken,
    attemptNumber: 1,
  );
}

void main() {
  group('repaired LaTeX survives the typed commit', () {
    test('a marked repair keeps structural math in the final draft', () {
      final before = _currentDraft();
      final after = before.copyWith(explanation: _repairedExplanation);

      final result = _build(
        current: after,
        repairEdit: _markerFor(before: before, after: after),
      );

      final explanation = result.acceptedDrafts.single.explanation!;
      expect(explanation.nodes.whereType<TextNode>(), isNotEmpty);
      expect(
        explanation.nodes.whereType<InlineMathNode>().map((n) => n.latex),
        contains(r'\begin{matrix}1\end{matrix}'),
      );
      final blockMath = explanation.nodes.whereType<BlockMathNode>().toList();
      expect(blockMath, hasLength(1));
      expect(blockMath.single.latex, contains(r'\int_0^1'));
      expect(
        explanation.nodes.any(
          (node) => node is TextNode && node.text.contains(r'\begin{matrix}'),
        ),
        isFalse,
        reason: 'the repaired math must not stay literal source text',
      );
    });

    test('without a marker the frozen exact literal text is kept', () {
      final before = _currentDraft();
      final after = before.copyWith(explanation: _repairedExplanation);

      final result = _build(current: after);

      final explanation = result.acceptedDrafts.single.explanation!;
      expect(explanation.nodes, hasLength(1));
      expect(explanation.nodes.single, TextNode(_repairedExplanation));
    });

    test('a stale marker cannot grant structural treatment', () {
      final before = _currentDraft();
      final marked = before.copyWith(explanation: _repairedExplanation);
      final marker = _markerFor(before: before, after: marked);
      final editedLater = before.copyWith(explanation: r'手工输入的文字 \(x\)');

      final result = _build(current: editedLater, repairEdit: marker);

      final explanation = result.acceptedDrafts.single.explanation!;
      expect(explanation.nodes, hasLength(1));
      expect(explanation.nodes.single, TextNode(r'手工输入的文字 \(x\)'));
    });

    test('a repaired stem keeps its math structure', () {
      final before = _currentDraft();
      final after = before.copyWith(content: r'New stem \(a^2+b^2\) end');

      final result = _build(
        current: after,
        repairEdit: ReviewRepairEdit.applied(
          before: before,
          after: after,
          fields: const <ReviewRepairField>[ReviewRepairField.content],
        ),
      );

      final stem = result.acceptedDrafts.single.stem;
      expect(stem.nodes.whereType<InlineMathNode>(), hasLength(1));
      expect(
        (stem.nodes.whereType<InlineMathNode>().single).latex,
        'a^2+b^2',
      );
    });
  });

  group('untouched structural content is preserved', () {
    test('an untouched stem image survives an explanation repair', () {
      final before = _currentDraft();
      final after = before.copyWith(explanation: _repairedExplanation);

      final result = _build(
        current: after,
        repairEdit: _markerFor(before: before, after: after),
        withStemImage: true,
      );

      final stem = result.acceptedDrafts.single.stem;
      expect(stem.nodes.whereType<ImageNode>(), hasLength(1));
      expect(stem.nodes.whereType<InlineMathNode>(), hasLength(1));
      expect(result.acceptedDrafts.single.assetRefs, hasLength(1));
    });
  });

  testWidgets('committed repaired LaTeX renders as math', (tester) async {
    final before = _currentDraft();
    final after = before.copyWith(explanation: _repairedExplanation);
    final result = _build(
      current: after,
      repairEdit: _markerFor(before: before, after: after),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RichContentRenderer(
              content: result.acceptedDrafts.single.explanation!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Math), findsNWidgets(2));
    expect(
      find.textContaining(r'\begin{matrix}', findRichText: true),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
