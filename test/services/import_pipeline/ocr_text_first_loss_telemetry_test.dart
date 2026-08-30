import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

const _sourceUuid = '11111111-1111-4111-8111-111111111111';
const _questionUuid = '22222222-2222-4222-8222-222222222222';
const _reviewUuid = '33333333-3333-4333-8333-333333333333';

void main() {
  tearDown(() {
    typedCandidateConstructionTelemetryHandlerForTesting = null;
    ocrCompatibilityProjectionTelemetryHandlerForTesting = null;
  });

  group('OCR text first-loss telemetry', () {
    test('diagnostic normalization identifies a raw ownership divergence', () {
      final eventA = <Map<String, Object?>>[];
      final eventB = <Map<String, Object?>>[];
      typedCandidateConstructionTelemetryHandlerForTesting = eventA.add;
      ocrCompatibilityProjectionTelemetryHandlerForTesting = eventB.add;

      final fixture = _normalizationDivergenceFixture();
      final batch = _build(fixture);

      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(1));
      expect(eventA, hasLength(1));
      expect(eventB, hasLength(1));

      final construction = eventA.single;
      expect(construction['ocrRegionStemPartCount'], 1);
      expect(construction['ownedSourceCount'], 1);
      expect(construction['ownedSourceWithBothOffsetsCount'], 0);
      expect(construction['typedRegionStemFragmentWithSliceCount'], 0);
      expect(construction['typedRegionStemFragmentWithoutSliceCount'], 1);
      expect(
        construction['ocrRegionVsTypedMaterializedExactEqual'],
        isFalse,
      );
      expect(
        construction['ocrRegionVsTypedMaterializedDiagnosticNormalizedEqual'],
        isTrue,
      );
      expect(
          construction['typedRegionMaterializedStemTabCount'], greaterThan(0));
      expect(
          construction['typedRegionMaterializedStemCrCount'], greaterThan(0));
      expect(construction['draftStemTabCount'], 0);
      expect(construction['draftStemCrCount'], 0);

      final projection = eventB.single;
      expect(projection['ocrRawOptionCount'], 0);
      expect(projection['keepOcrOptions'], isFalse);
      expect(projection['draftStemVsOcrRegionStemExactEqual'], isFalse);
      expect(
        projection['draftStemVsOcrRegionStemDiagnosticNormalizedEqual'],
        isTrue,
      );
      expect(projection['draftStemVsOcrContentExactEqual'], isFalse);
      expect(
        projection['draftStemVsOcrContentDiagnosticNormalizedEqual'],
        isTrue,
      );
      expect(
        projection['ocrRegionStemDiagnosticNormalizedLength'],
        projection['draftStemLength'],
      );
    });

    test('explicit ownership offsets are observed as an actual SourceSlice',
        () {
      final events = <Map<String, Object?>>[];
      typedCandidateConstructionTelemetryHandlerForTesting = events.add;

      final batch = _build(_sliceFixture(explicitOffsets: true));

      expect(batch.failure, isNull);
      final event = events.single;
      expect(event['ownedSourceCount'], 1);
      expect(event['ownedSourceWithExplicitStartCount'], 1);
      expect(event['ownedSourceWithExplicitEndCount'], 1);
      expect(event['ownedSourceWithBothOffsetsCount'], 1);
      expect(event['typedRegionStemFragmentCount'], 1);
      expect(event['typedRegionStemFragmentWithSliceCount'], 1);
      expect(event['typedRegionStemFragmentWithoutSliceCount'], 0);
      expect(event['ocrRegionVsTypedMaterializedExactEqual'], isTrue);
    });

    test('full-part ownership is a valid offset-absent slice-null case', () {
      final events = <Map<String, Object?>>[];
      typedCandidateConstructionTelemetryHandlerForTesting = events.add;

      final batch = _build(_sliceFixture(explicitOffsets: false));

      expect(batch.failure, isNull);
      final event = events.single;
      expect(event['ownedSourceCount'], 1);
      expect(event['ownedSourceWithExplicitStartCount'], 0);
      expect(event['ownedSourceWithExplicitEndCount'], 0);
      expect(event['ownedSourceWithBothOffsetsCount'], 0);
      expect(event['typedRegionStemFragmentCount'], 1);
      expect(event['typedRegionStemFragmentWithSliceCount'], 0);
      expect(event['typedRegionStemFragmentWithoutSliceCount'], 1);
      expect(event['ocrRegionVsTypedMaterializedExactEqual'], isTrue);
    });

    test('construction and projector telemetry are aggregate-only', () {
      final eventA = <Map<String, Object?>>[];
      final eventB = <Map<String, Object?>>[];
      typedCandidateConstructionTelemetryHandlerForTesting = eventA.add;
      ocrCompatibilityProjectionTelemetryHandlerForTesting = eventB.add;

      final batch = _build(_privacyFixture());

      expect(batch.failure, isNull);
      expect(batch.candidates.single.draft.options, hasLength(4));
      expect(eventA.single.keys.toSet(), _eventAKeys);
      expect(eventB.single.keys.toSet(), _eventBKeys);
      expect(eventB.single['ocrRawOptionCount'], 4);
      expect(eventB.single['keepOcrOptions'], isTrue);
      expect(eventB.single['ocrPostPolicyStemLength'],
          eventB.single['ocrContentLength']);
      _expectTelemetryRedacted(eventA.single);
      _expectTelemetryRedacted(eventB.single);
    });

    test('throwing observers cannot alter candidate, projection, or gate', () {
      final fixture = _completeShortAnswerFixture();
      final legacyQuestion =
          const OcrQuestionAssembler().assemble(fixture.region).question;
      final baselineBatch = _build(fixture);
      final baselineGate = applyOcrTypedCandidateGate(
        batch: baselineBatch,
        finalQuestions: <Map<String, dynamic>>[
          Map<String, dynamic>.from(legacyQuestion),
        ],
        singleFile: true,
      );

      typedCandidateConstructionTelemetryHandlerForTesting =
          (_) => throw StateError('synthetic observer failure A');
      ocrCompatibilityProjectionTelemetryHandlerForTesting =
          (_) => throw StateError('synthetic observer failure B');

      final observedBatch = _build(fixture);
      final observedGate = applyOcrTypedCandidateGate(
        batch: observedBatch,
        finalQuestions: <Map<String, dynamic>>[
          Map<String, dynamic>.from(legacyQuestion),
        ],
        singleFile: true,
      );

      expect(_batchSnapshot(observedBatch), _batchSnapshot(baselineBatch));
      expect(observedGate.route, baselineGate.route);
      expect(observedGate.reason, baselineGate.reason);
      expect(observedGate.questions, baselineGate.questions);
    });
  });
}

({OcrDocument document, OcrQuestionRegion region})
    _normalizationDivergenceFixture() {
  const rawStem = '1. Alpha  Beta\t\tGamma\r\nLine\r\n\r\n\r\nTail';
  const normalizedStem = '1. Alpha Beta Gamma\nLine\n\nTail';
  const blockIdentity = 'normalization_stem_block';
  return (
    document: _document(
      sourceName: 'normalization_fixture.pdf',
      blocks: <OcrBlock>[_block(blockIdentity, 0, rawStem)],
    ),
    region: const OcrQuestionRegion(
      number: 1,
      stemParts: <String>[normalizedStem],
      answerParts: <String>[],
      explanationParts: <String>[],
      sourcePageIndices: <int>[1],
      sourceBlockIds: <String>[blockIdentity],
      diagnostics: <String>[],
      declaredKind: TextQuestionKind.subjective,
      ownedSources: <OcrQuestionRegionSource>[
        OcrQuestionRegionSource(
          blockId: blockIdentity,
          field: OcrRegionField.stem,
          text: normalizedStem,
        ),
      ],
    ),
  );
}

({OcrDocument document, OcrQuestionRegion region}) _sliceFixture({
  required bool explicitOffsets,
}) {
  const selected = '1. SLICE_STEM_SENTINEL';
  final source = explicitOffsets ? 'prefix::$selected::suffix' : selected;
  final start = source.indexOf(selected);
  const blockIdentity = 'slice_stem_block';
  return (
    document: _document(
      sourceName: 'slice_fixture.pdf',
      blocks: <OcrBlock>[_block(blockIdentity, 0, source)],
    ),
    region: OcrQuestionRegion(
      number: 1,
      stemParts: const <String>[selected],
      answerParts: const <String>[],
      explanationParts: const <String>[],
      sourcePageIndices: const <int>[1],
      sourceBlockIds: const <String>[blockIdentity],
      diagnostics: const <String>[],
      declaredKind: TextQuestionKind.subjective,
      ownedSources: <OcrQuestionRegionSource>[
        OcrQuestionRegionSource(
          blockId: blockIdentity,
          field: OcrRegionField.stem,
          text: selected,
          startCodeUnitOffset: explicitOffsets ? start : null,
          endCodeUnitOffset: explicitOffsets ? start + selected.length : null,
        ),
      ],
    ),
  );
}

({OcrDocument document, OcrQuestionRegion region}) _privacyFixture() {
  const stemBlock = 'PRIVACY_STEM_BLOCK_SENTINEL';
  const answerBlock = 'PRIVACY_ANSWER_BLOCK_SENTINEL';
  const explanationBlock = 'PRIVACY_EXPLANATION_BLOCK_SENTINEL';
  const stem = '1. STEM_SENTINEL \$LATEX_BODY_SENTINEL\$\n'
      '(A) OPTION_A_SENTINEL\n'
      '(B) OPTION_B_SENTINEL\n'
      '(C) OPTION_C_SENTINEL\n'
      '(D) OPTION_D_SENTINEL';
  return (
    document: _document(
      sourceName: r'C:\PRIVATE_PATH_SENTINEL\SOURCE_FILENAME_SENTINEL.pdf',
      blocks: <OcrBlock>[
        _block(
          stemBlock,
          0,
          stem,
          raw: const <String, dynamic>{
            'ocr': 'OCR_PAYLOAD_SENTINEL',
          },
        ),
        _block(answerBlock, 1, '答案：ANSWER_SENTINEL'),
        _block(explanationBlock, 2, '解析：EXPLANATION_SENTINEL'),
      ],
      rawResponses: const <Map<String, dynamic>>[
        <String, dynamic>{'provider': 'PROVIDER_PAYLOAD_SENTINEL'},
      ],
    ),
    region: const OcrQuestionRegion(
      number: 1,
      stemParts: <String>[stem],
      answerParts: <String>['ANSWER_SENTINEL'],
      explanationParts: <String>['EXPLANATION_SENTINEL'],
      sourcePageIndices: <int>[1],
      sourceBlockIds: <String>[stemBlock, answerBlock, explanationBlock],
      diagnostics: <String>[],
      declaredKind: TextQuestionKind.choice,
    ),
  );
}

({OcrDocument document, OcrQuestionRegion region})
    _completeShortAnswerFixture() {
  const stemBlock = 'outcome_stem_block';
  const answerBlock = 'outcome_answer_block';
  const explanationBlock = 'outcome_explanation_block';
  return (
    document: _document(
      sourceName: 'outcome_fixture.pdf',
      blocks: <OcrBlock>[
        _block(stemBlock, 0, '1. Outcome prompt'),
        _block(answerBlock, 1, '答案：Outcome answer'),
        _block(explanationBlock, 2, '解析：Outcome explanation'),
      ],
    ),
    region: const OcrQuestionRegion(
      number: 1,
      stemParts: <String>['1. Outcome prompt'],
      answerParts: <String>['Outcome answer'],
      explanationParts: <String>['Outcome explanation'],
      sourcePageIndices: <int>[1],
      sourceBlockIds: <String>[stemBlock, answerBlock, explanationBlock],
      diagnostics: <String>[],
      declaredKind: TextQuestionKind.subjective,
    ),
  );
}

OcrTypedCandidateBatch _build(
  ({OcrDocument document, OcrQuestionRegion region}) fixture,
) {
  final legacyQuestion =
      const OcrQuestionAssembler().assemble(fixture.region).question;
  return buildOcrTypedCandidateBatch(
    document: fixture.document,
    regions: <OcrQuestionRegion>[fixture.region],
    legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
    uuidV4Factory: _uuidSequence(),
  );
}

Map<String, Object?> _batchSnapshot(OcrTypedCandidateBatch batch) {
  if (batch.failure != null || batch.candidates.isEmpty) {
    return <String, Object?>{
      'failure': batch.failure?.name,
      'candidateCount': batch.candidates.length,
    };
  }
  final candidate = batch.candidates.single;
  const projection = RichContentTextProjection();
  return <String, Object?>{
    'failure': batch.failure?.name,
    'candidateCount': batch.candidates.length,
    'questionNumber': candidate.questionNumber,
    'questionId': candidate.questionId,
    'reviewItemId': candidate.reviewItemId,
    'draftKind': candidate.draft.kind.name,
    'draftStem': projection.project(candidate.draft.stem),
    'draftOptions': <String>[
      for (final option in candidate.draft.options)
        '${option.label}:${projection.project(option.content)}',
    ],
    'draftAnswer': _answerProjection(candidate.draft.answer),
    'draftExplanation': candidate.draft.explanation == null
        ? null
        : projection.project(candidate.draft.explanation!),
    'projectedType': candidate.projectedLegacy.type,
    'projectedQuestionNumber': candidate.projectedLegacy.questionNumber,
    'projectedStem': candidate.projectedLegacy.content,
    'projectedOptions': candidate.projectedLegacy.options,
    'projectedAnswer': candidate.projectedLegacy.standardAnswer,
    'projectedExplanation': candidate.projectedLegacy.explanation,
    'pageIndices': candidate.sourcePageIndices,
    'blockCount': candidate.sourceBlockIds.length,
  };
}

String? _answerProjection(QuestionAnswer? answer) {
  const projection = RichContentTextProjection();
  return switch (answer) {
    null => null,
    ChoiceAnswer(:final optionIds) => optionIds.join(','),
    ContentAnswer(:final content) => projection.project(content),
  };
}

OcrDocument _document({
  required String sourceName,
  required List<OcrBlock> blocks,
  List<Map<String, dynamic>> rawResponses = const <Map<String, dynamic>>[],
}) {
  return OcrDocument(
    sourceName: sourceName,
    pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: rawResponses,
    usage: const <String, dynamic>{},
  );
}

OcrBlock _block(
  String blockIdentity,
  int readingOrder,
  String stem, {
  Map<String, dynamic> raw = const <String, dynamic>{},
}) {
  return OcrBlock(
    blockId: blockIdentity,
    pageIndex: 1,
    type: 'text',
    text: stem,
    bbox: const <double>[],
    readingOrder: readingOrder,
    raw: raw,
  );
}

String Function() _uuidSequence() {
  final values = <String>[_sourceUuid, _questionUuid, _reviewUuid].iterator;
  return () {
    if (!values.moveNext()) {
      throw StateError('Synthetic UUID sequence exhausted.');
    }
    return values.current;
  };
}

void _expectTelemetryRedacted(Map<String, Object?> event) {
  expect(event.values.every((entry) => entry is num || entry is bool), isTrue);
  for (final forbiddenKey in const <String>[
    'text',
    'content',
    'raw',
    'sourceId',
    'blockId',
    'value',
    'payload',
    'assetId',
    'filePath',
    'sourceFilename',
  ]) {
    expect(event.containsKey(forbiddenKey), isFalse, reason: forbiddenKey);
  }
  final serialized = jsonEncode(<String, Object?>{
    'keys': event.keys.toList(growable: false),
    'values': event.values.toList(growable: false),
  });
  for (final sentinel in const <String>[
    'STEM_SENTINEL',
    'OPTION_A_SENTINEL',
    'OPTION_B_SENTINEL',
    'OPTION_C_SENTINEL',
    'OPTION_D_SENTINEL',
    'ANSWER_SENTINEL',
    'EXPLANATION_SENTINEL',
    'LATEX_BODY_SENTINEL',
    'PRIVACY_STEM_BLOCK_SENTINEL',
    'PRIVACY_ANSWER_BLOCK_SENTINEL',
    'PRIVACY_EXPLANATION_BLOCK_SENTINEL',
    'SOURCE_FILENAME_SENTINEL.pdf',
    'PRIVATE_PATH_SENTINEL',
    'OCR_PAYLOAD_SENTINEL',
    'PROVIDER_PAYLOAD_SENTINEL',
    _sourceUuid,
  ]) {
    expect(serialized, isNot(contains(sentinel)), reason: sentinel);
  }
}

const _eventAKeys = <String>{
  'questionNumber',
  'ocrRegionStemPartCount',
  'ocrRegionStemTextLength',
  'ocrRegionStemSpaceCount',
  'ocrRegionStemTabCount',
  'ocrRegionStemCrCount',
  'ocrRegionStemLfCount',
  'ocrRegionStemRepeatedHorizontalWhitespaceRuns',
  'ocrRegionStemTripleNewlineRuns',
  'ownedSourceCount',
  'ownedSourceWithExplicitStartCount',
  'ownedSourceWithExplicitEndCount',
  'ownedSourceWithBothOffsetsCount',
  'typedRegionStemFragmentCount',
  'typedRegionStemFragmentWithSliceCount',
  'typedRegionStemFragmentWithoutSliceCount',
  'typedRegionStemSourceContentCount',
  'typedRegionStemSourceAssetCount',
  'typedRegionStemSourceTableCount',
  'typedRegionStemUnsupportedCount',
  'typedRegionMaterializedStemLength',
  'typedRegionMaterializedStemSpaceCount',
  'typedRegionMaterializedStemTabCount',
  'typedRegionMaterializedStemCrCount',
  'typedRegionMaterializedStemLfCount',
  'draftStemProjectedLength',
  'draftStemSpaceCount',
  'draftStemTabCount',
  'draftStemCrCount',
  'draftStemLfCount',
  'ocrRegionVsTypedMaterializedExactEqual',
  'ocrRegionVsTypedMaterializedDiagnosticNormalizedEqual',
  'typedMaterializedVsDraftExactEqual',
  'typedMaterializedVsDraftDiagnosticNormalizedEqual',
};

const _eventBKeys = <String>{
  'questionNumber',
  'draftStemLength',
  'ocrRegionStemPreExtractLength',
  'ocrRegionStemPreExtractSpaceCount',
  'ocrRegionStemPreExtractTabCount',
  'ocrRegionStemPreExtractCrCount',
  'ocrRegionStemPreExtractLfCount',
  'ocrRegionStemDiagnosticNormalizedLength',
  'ocrRawOptionCount',
  'keepOcrOptions',
  'ocrRawExtractStemLength',
  'ocrPostPolicyStemLength',
  'ocrContentLength',
  'draftStemVsOcrRegionStemExactEqual',
  'draftStemVsOcrRegionStemDiagnosticNormalizedEqual',
  'draftStemVsOcrContentExactEqual',
  'draftStemVsOcrContentDiagnosticNormalizedEqual',
};
