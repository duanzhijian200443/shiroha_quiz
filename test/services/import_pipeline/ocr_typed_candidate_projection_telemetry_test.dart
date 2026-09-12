import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';

const _questionUuidA = '22222222-2222-4222-8222-222222222222';
const _questionUuidB = '33333333-3333-4333-8333-333333333333';
const _reviewUuidA = '44444444-4444-4444-8444-444444444444';
const _reviewUuidB = '55555555-5555-4555-8555-555555555555';
const _sourceUuid = '11111111-1111-4111-8111-111111111111';

void main() {
  group('typed candidate projection parity telemetry', () {
    tearDown(() {
      projectionParityTelemetryHandlerForTesting = null;
    });

    test('reports a complete parity pass without source text', () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[_finalQuestion(number: 1)],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, ocrTypedCandidateReadyReason);
      expect(telemetryEvents, hasLength(1));
      final event = telemetryEvents.single;
      expect(event['questionNumber'], 1);
      expect(event['baselineParity'], isTrue);
      expect(event['provenanceParity'], isTrue);
      expect(event['typeEqual'], isTrue);
      expect(event['questionNumberEqual'], isTrue);
      expect(event['contentEqual'], isTrue);
      expect(event['optionsEqual'], isTrue);
      expect(event['optionCountEqual'], isTrue);
      expect(event['standardAnswerEqual'], isTrue);
      expect(event['explanationEqual'], isTrue);
      expect(event['pageCountEqual'], isTrue);
      expect(event['pageOrderEqual'], isTrue);
      expect(event['blockCountEqual'], isTrue);
      expect(event['blockOrderEqual'], isTrue);
      expect(event['finalPageCount'], 1);
      expect(event['candidatePageCount'], 1);
      expect(event['finalBlockCount'], 3);
      expect(event['candidateBlockCount'], 3);
      expect(event['firstMismatchField'], 'none');
      _expectProjectionTelemetryRedacted(event);
    });

    test('identifies a strict content mismatch as the first field', () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1)..['content'] = 'Different content',
        ],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
      final event = telemetryEvents.single;
      expect(event['baselineParity'], isFalse);
      expect(event['provenanceParity'], isTrue);
      expect(event['contentEqual'], isFalse);
      expect(event['contentN0Equal'], isFalse);
      expect(event['contentFinalizerEligible'], isTrue);
      expect(event['contentFinalizerMatched'], isFalse);
      expect(event['firstMismatchField'], 'content');
      _expectProjectionTelemetryRedacted(event);
    });

    test('identifies a strict standard answer mismatch as the first field', () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1)..['standard_answer'] = 'Different answer',
        ],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
      final event = telemetryEvents.single;
      expect(event['baselineParity'], isFalse);
      expect(event['provenanceParity'], isTrue);
      expect(event['standardAnswerEqual'], isFalse);
      expect(event['standardAnswerN0Equal'], isFalse);
      expect(event['standardAnswerFinalizerEligible'], isTrue);
      expect(event['standardAnswerFinalizerMatched'], isFalse);
      expect(event['firstMismatchField'], 'standardAnswer');
      _expectProjectionTelemetryRedacted(event);
    });

    test('reports explanation finalization parity without relaxing baseline',
        () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final candidate = _candidate(
        questionNumber: 1,
        questionId: _questionUuidA,
        reviewItemId: _reviewUuidA,
        draft: _draftWithExplanation(
          questionNumber: 1,
          questionId: _questionUuidA,
          explanation: RichContent(
            nodes: <ContentNode>[const TextNode('<p>wrapped</p>')],
          ),
        ),
        projectedLegacy: _finalBaseline(
          number: 1,
          explanation: '<p>wrapped</p>',
        ),
      );
      final question = _finalQuestion(number: 1)
        ..['explanation'] = 'wrapped'
        ..['raw_explanation'] = null;

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[candidate],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.typedV2);
      expect(result.reason, ocrTypedCandidateReadyReason);
      final event = telemetryEvents.single;
      expect(event['baselineParity'], isTrue);
      expect(event['provenanceParity'], isTrue);
      expect(event['explanationEqual'], isFalse);
      expect(event['explanationN0Equal'], isFalse);
      expect(event['explanationParityAllowed'], isTrue);
      expect(event['explanationFinalizerEligible'], isTrue);
      expect(event['explanationFinalizerMatched'], isTrue);
      expect(event['firstMismatchField'], 'none');
      _expectProjectionTelemetryRedacted(event);
    });

    test('identifies block order provenance mismatch independently', () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final question = _finalQuestion(number: 1)
        ..['source_block_ids'] = <String>[
          'answer_1',
          'q_1',
          'explanation_1',
        ];
      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[question],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
      final event = telemetryEvents.single;
      expect(event['baselineParity'], isTrue);
      expect(event['provenanceParity'], isFalse);
      expect(event['pageCountEqual'], isTrue);
      expect(event['pageOrderEqual'], isTrue);
      expect(event['blockCountEqual'], isTrue);
      expect(event['blockOrderEqual'], isFalse);
      expect(event['firstMismatchField'], 'blockIds');
      _expectProjectionTelemetryRedacted(event);
    });

    test('emits through the first failing question only', () {
      final telemetryEvents = <Map<String, Object?>>[];
      projectionParityTelemetryHandlerForTesting = telemetryEvents.add;

      final result = applyOcrTypedCandidateGate(
        batch: OcrTypedCandidateBatch(
          candidates: <OcrTypedCandidate>[
            _candidate(
              questionNumber: 1,
              questionId: _questionUuidA,
              reviewItemId: _reviewUuidA,
            ),
            _candidate(
              questionNumber: 2,
              questionId: _questionUuidB,
              reviewItemId: _reviewUuidB,
            ),
          ],
        ),
        finalQuestions: <Map<String, dynamic>>[
          _finalQuestion(number: 1),
          _finalQuestion(number: 2)..['content'] = 'Different content',
        ],
        singleFile: true,
      );

      expect(result.route, ImportStorageRoute.legacyV1);
      expect(result.reason, 'typed_candidate_projection_mismatch');
      expect(telemetryEvents, hasLength(2));
      expect(telemetryEvents[0]['questionNumber'], 1);
      expect(telemetryEvents[0]['firstMismatchField'], 'none');
      expect(telemetryEvents[1]['questionNumber'], 2);
      expect(telemetryEvents[1]['baselineParity'], isFalse);
      expect(telemetryEvents[1]['firstMismatchField'], 'content');
    });
  });
}

OcrTypedCandidate _candidate({
  required int questionNumber,
  required String questionId,
  required String reviewItemId,
  QuestionDraftV2? draft,
  LegacyReviewBaseline? projectedLegacy,
}) {
  return OcrTypedCandidate(
    questionNumber: questionNumber,
    questionId: questionId,
    reviewItemId: reviewItemId,
    draft: draft ??
        QuestionDraftV2(
          questionId: questionId,
          kind: QuestionKind.shortAnswer,
          questionNumber: questionNumber,
          stem: RichContent(
            nodes: <ContentNode>[
              TextNode('Synthetic prompt marker $questionNumber.'),
            ],
          ),
          answer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[const TextNode('synthetic-result-1')],
            ),
          ),
          explanation: RichContent(
            nodes: <ContentNode>[const TextNode('Synthetic explanation 1')],
          ),
        ),
    projectedLegacy: projectedLegacy ?? _finalBaseline(number: questionNumber),
    sourcePageIndices: const <int>[1],
    sourceBlockIds: const <String>['q_1', 'answer_1', 'explanation_1'],
  );
}

QuestionDraftV2 _draftWithExplanation({
  required int questionNumber,
  required String questionId,
  required RichContent explanation,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: questionNumber,
    stem: RichContent(
      nodes: <ContentNode>[
        TextNode('Synthetic prompt marker $questionNumber.')
      ],
    ),
    answer: ContentAnswer(
      content: RichContent(
        nodes: <ContentNode>[const TextNode('synthetic-result-1')],
      ),
    ),
    explanation: explanation,
  );
}

LegacyReviewBaseline _finalBaseline({
  required int number,
  String explanation = 'Synthetic explanation 1',
}) {
  return LegacyReviewBaseline(
    type: 3,
    questionNumber: number,
    content: 'Synthetic prompt marker $number.',
    options: const <String>[],
    standardAnswer: 'synthetic-result-1',
    explanation: explanation,
  );
}

Map<String, dynamic> _finalQuestion({required int number}) {
  return <String, dynamic>{
    'q_num': number.toString(),
    'question_number': number,
    'type': 3,
    'content': 'Synthetic prompt marker $number.',
    'options': <String>[],
    'standard_answer': 'synthetic-result-1',
    'explanation': 'Synthetic explanation 1',
    'raw_explanation': 'Synthetic explanation 1',
    'source_page_indices': <int>[1],
    'source_block_ids': <String>['q_1', 'answer_1', 'explanation_1'],
  };
}

void _expectProjectionTelemetryRedacted(Map<String, Object?> event) {
  expect(
    event.values.every(
      (value) =>
          value == null || value is bool || value is num || value is String,
    ),
    isTrue,
  );
  for (final forbiddenKey in const <String>[
    'content',
    'options',
    'standard_answer',
    'explanation',
    'raw_explanation',
    'source_page_indices',
    'source_block_ids',
    'sourceId',
    'source_id',
    'assetId',
    'localAssetId',
  ]) {
    expect(event.containsKey(forbiddenKey), isFalse, reason: forbiddenKey);
  }
  for (final forbiddenValue in const <String>[
    'Synthetic prompt marker 1.',
    'synthetic-result-1',
    'Synthetic explanation 1',
    'q_1',
    'answer_1',
    'explanation_1',
    _sourceUuid,
  ]) {
    expect(event.values, isNot(contains(forbiddenValue)));
  }
}
