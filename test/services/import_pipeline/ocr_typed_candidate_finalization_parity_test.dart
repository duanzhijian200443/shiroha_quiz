import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';

const _questionUuid = '22222222-2222-4222-8222-222222222222';
const _reviewUuid = '44444444-4444-4444-8444-444444444444';

void main() {
  group('deterministic explanation finalization parity', () {
    test('production comparison uses the frozen one-way transforms', () {
      final cases = <List<String>>[
        <String>['<p>wrapped</p>', 'wrapped'],
        <String>[
          '<div><span>one</span><br><p>two</p></div>',
          'one\ntwo',
        ],
        <String>['safe &amp; sound', 'safe & sound'],
        <String>[r'proof \(x=1', r'proof \(x=1\)'],
        <String>[
          r'\begin{matrix}1&2\\3&4\end{matrix}',
          r'\[\begin{matrix}1&2\\3&4\end{matrix}\]',
        ],
      ];

      for (final pair in cases) {
        final comparison = finalizeImportTextForParityComparison(pair[0]);
        expect(comparison.eligible, isTrue, reason: pair[0]);
        expect(comparison.text, pair[1], reason: pair[0]);

        final result = _gateForExplanation(
          projectedExplanation: pair[0],
          baselineExplanation: pair[1],
        );
        expect(result.route, ImportStorageRoute.typedV2, reason: pair[0]);
        expect(result.reason, ocrTypedCandidateReadyReason, reason: pair[0]);
      }
    });

    test('real finalizer and raw-like projection reach typedV2', () {
      const projected =
          '<div><span>Safe explanation</span><br><p>second line</p></div>';
      final rawQuestion = _finalQuestion()
        ..['explanation'] = projected
        ..['raw_explanation'] = projected;
      final finalized = finalizeAndAuditImportQuestions(
        <Map<String, dynamic>>[rawQuestion],
      );

      expect(finalized.single['explanation'], 'Safe explanation\nsecond line');
      expect(finalized.single['raw_explanation'], projected);

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(projectedExplanation: projected),
          ],
        ),
        finalQuestions: finalized,
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, ocrTypedCandidateReadyReason);
      expect(
        result.questions.single[TypedReviewSnapshotCodec.mapKey],
        isA<Map<String, Object?>>(),
      );
    });

    test('exact and N0 admission precede HTML finalization eligibility', () {
      final exact = _gateForExplanation(
        projectedExplanation: '<custom>synthetic</custom>',
        baselineExplanation: '<custom>synthetic</custom>',
      );
      expect(exact.route, ImportStorageRoute.typedV2);
      expect(exact.reason, ocrTypedCandidateReadyReason);

      final n0 = _gateForExplanation(
        projectedExplanation: '<custom>synthetic</custom>\t',
        baselineExplanation: '<custom>synthetic</custom>',
      );
      expect(n0.route, ImportStorageRoute.typedV2);
      expect(n0.reason, ocrTypedCandidateReadyReason);
    });

    test('unsafe and unsupported HTML cannot manufacture equivalence', () {
      for (final pair in const <List<String>>[
        <String>['<script>synthetic</script>safe', 'safe'],
        <String>['<custom>synthetic</custom>', 'synthetic'],
      ]) {
        final comparison = finalizeImportTextForParityComparison(pair[0]);
        expect(comparison.eligible, isFalse, reason: pair[0]);

        final result = _gateForExplanation(
          projectedExplanation: pair[0],
          baselineExplanation: pair[1],
        );
        expect(result.route, ImportStorageRoute.legacyV1, reason: pair[0]);
        expect(result.reason, isNotNull, reason: pair[0]);
      }
    });

    test('semantic mutation and internal line reflow remain rejected', () {
      for (final pair in const <List<String>>[
        <String>['same explanation', 'different explanation'],
        <String>['line one\nline two', 'line oneline two'],
      ]) {
        final result = _gateForExplanation(
          projectedExplanation: pair[0],
          baselineExplanation: pair[1],
          includeRawExplanation: false,
        );
        expect(result.route, ImportStorageRoute.legacyV1, reason: pair[0]);
        expect(
          result.reason,
          'typed_candidate_projection_mismatch',
          reason: pair[0],
        );
      }
    });
  });
}

OcrTypedCandidateGateResult _gateForExplanation({
  required String projectedExplanation,
  required String baselineExplanation,
  bool includeRawExplanation = true,
}) {
  final question = _finalQuestion()
    ..['explanation'] = baselineExplanation
    ..['raw_explanation'] = includeRawExplanation ? projectedExplanation : null;
  return applyOcrTypedCandidateGate(
    batch: OcrTypedCandidateBatch(
      candidates: <OcrTypedCandidate>[
        _candidate(projectedExplanation: projectedExplanation),
      ],
    ),
    finalQuestions: <Map<String, dynamic>>[question],
    singleFile: true,
  );
}

OcrTypedCandidate _candidate({required String projectedExplanation}) {
  return OcrTypedCandidate(
    questionNumber: 1,
    reviewItemId: _reviewUuid,
    questionId: _questionUuid,
    draft: QuestionDraftV2(
      questionId: _questionUuid,
      kind: QuestionKind.shortAnswer,
      questionNumber: 1,
      stem: RichContent(
        nodes: <ContentNode>[const TextNode('Synthetic prompt marker 1.')],
      ),
      answer: ContentAnswer(
        content: RichContent(
          nodes: <ContentNode>[const TextNode('synthetic-result-1')],
        ),
      ),
      explanation: RichContent(
        nodes: <ContentNode>[TextNode(projectedExplanation)],
      ),
    ),
    projectedLegacy: LegacyReviewBaseline(
      type: 3,
      questionNumber: 1,
      content: 'Synthetic prompt marker 1.',
      options: const <String>[],
      standardAnswer: 'synthetic-result-1',
      explanation: projectedExplanation,
    ),
    sourcePageIndices: const <int>[1],
    sourceBlockIds: const <String>['q_1', 'answer_1', 'explanation_1'],
  );
}

Map<String, dynamic> _finalQuestion() {
  return <String, dynamic>{
    'q_num': '1',
    'question_number': 1,
    'type': 3,
    'content': 'Synthetic prompt marker 1.',
    'options': <String>[],
    'standard_answer': 'synthetic-result-1',
    'explanation': 'Synthetic explanation 1',
    'raw_explanation': 'Synthetic explanation 1',
    'source_page_indices': <int>[1],
    'source_block_ids': <String>['q_1', 'answer_1', 'explanation_1'],
    'source': 'glm_ocr_intermediate',
    'diagnostics': <String>[],
  };
}
