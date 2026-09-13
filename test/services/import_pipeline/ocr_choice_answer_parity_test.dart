import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';

void main() {
  group('Q7 choice answer first-loss', () {
    test('canonicalizes one explicit marker from a noisy answer field', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: _q7NoisyAnswerBody(),
          explanation: 'Synthetic rationale. 故选 A',
        ),
      );

      expect(observation['regionAnswerTextLength'], 542,
          reason: '$observation');
      expect(observation['bridgeMaterializedAnswerLength'], 542,
          reason: '$observation');
      expect(observation['regionVsBridgeExactEqual'], isTrue,
          reason: '$observation');
      expect(observation['typedAnswerFragmentsWithoutSlice'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInRegionAnswer'], 1,
          reason: '$observation');
      expect(observation['choiceMarkerCountInBridgeAnswer'], 1,
          reason: '$observation');
      expect(observation['choiceMarkerCountInExplanation'], 1,
          reason: '$observation');
      expect(observation['baselineStandardAnswerLength'], 1,
          reason: '$observation');

      expect(observation['draftAnswerKind'], 'ChoiceAnswer',
          reason: '$observation');
      expect(observation['draftAnswerProjectedLength'], 1,
          reason: '$observation');
      expect(observation['projectedStandardAnswerLength'], 1,
          reason: '$observation');
      expect(observation['projectedVsBaselineExactEqual'], isTrue,
          reason: '$observation');
      expect(observation['gateRoute'], ImportStorageRoute.typedV2.name,
          reason: '$observation');
      expect(observation['gateReason'], ocrTypedCandidateReadyReason,
          reason: '$observation');
    });

    test('uses the legacy-compatible explanation fallback', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: '未解析出的长答案片段',
          explanation: 'Synthetic rationale. 答案为 A',
        ),
      );

      expect(observation['choiceMarkerCountInRegionAnswer'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInBridgeAnswer'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInExplanation'], 1,
          reason: '$observation');
      expect(observation['explanationMarkerMatchesBaseline'], isTrue,
          reason: '$observation');
      expect(observation['draftAnswerKind'], 'ChoiceAnswer',
          reason: '$observation');
      expect(observation['projectedVsBaselineExactEqual'], isTrue,
          reason: '$observation');
    });

    test('does not treat unrelated A-D symbols as an answer marker', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: '变量 A B C D 仅用于公式标识',
          explanation: 'Synthetic rationale without a choice conclusion.',
        ),
      );

      expect(observation['choiceMarkerCountInRegionAnswer'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInBridgeAnswer'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInExplanation'], 0,
          reason: '$observation');
      expect(observation['draftAnswerKind'], 'ContentAnswer',
          reason: '$observation');
      expect(observation['projectedVsBaselineExactEqual'], isTrue,
          reason: '$observation');
    });

    test('keeps a noisy answer without a valid marker fail-closed', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: List<String>.filled(20, '未识别片段').join('；'),
          explanation: '未提供可验证的选择结论',
        ),
      );

      expect(observation['choiceMarkerCountInRegionAnswer'], 0,
          reason: '$observation');
      expect(observation['choiceMarkerCountInExplanation'], 0,
          reason: '$observation');
      expect(observation['draftAnswerKind'], 'ContentAnswer',
          reason: '$observation');
      expect(observation['projectedVsBaselineExactEqual'], isTrue,
          reason: '$observation');
    });

    test('preserves a precise answer SourceSlice', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: _q7NoisyAnswerBody(),
          explanation: 'Synthetic rationale. 应选 A',
        ),
      );

      expect(observation['regionOwnedAnswerSourceCount'], greaterThan(0),
          reason: '$observation');
      expect(observation['typedAnswerFragmentsWithSlice'], greaterThan(0),
          reason: '$observation');
      expect(observation['typedAnswerFragmentsWithoutSlice'], 0,
          reason: '$observation');
      expect(observation['regionVsBridgeExactEqual'], isTrue,
          reason: '$observation');
    });

    test('keeps a whole-part answer as a valid null-slice case', () {
      final observation = _observeChoiceChain(
        _singleChoiceDocument(
          answerBody: 'A',
          explanation: 'Synthetic rationale. 故选 A',
          splitAnswerValueIntoWholePart: true,
        ),
      );

      expect(observation['regionOwnedAnswerSourceCount'], 1,
          reason: '$observation');
      expect(observation['typedAnswerFragmentCount'], 1,
          reason: '$observation');
      expect(observation['typedAnswerFragmentsWithSlice'], 0,
          reason: '$observation');
      expect(observation['typedAnswerFragmentsWithoutSlice'], 1,
          reason: '$observation');
      expect(observation['regionVsBridgeExactEqual'], isTrue,
          reason: '$observation');
      expect(observation['draftAnswerKind'], 'ChoiceAnswer',
          reason: '$observation');
      expect(observation['projectedVsBaselineExactEqual'], isTrue,
          reason: '$observation');
    });
  });

  test('Q1-Q7 choice batch reaches exact typed gate parity', () {
    final document = _sevenChoiceQuestionDocument();
    final regionized = const OcrQuestionRegionizer().regionize(document);
    expect(
      regionized.regions.map((region) => region.number).toList(),
      <int>[1, 2, 3, 4, 5, 6, 7],
    );
    final baselines = regionized.regions.map(_legacyBaseline).toList();
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: baselines,
      uuidV4Factory: _uuidV4Sequence(),
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );
    expect(batch.failure, isNull);
    expect(batch.candidates, hasLength(7));

    final parity = <Map<String, Object?>>[];
    projectionParityTelemetryHandlerForTesting = parity.add;
    late final OcrTypedCandidateGateResult gate;
    try {
      gate = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: baselines,
        singleFile: true,
      );
    } finally {
      projectionParityTelemetryHandlerForTesting = null;
    }

    expect(
      parity
          .map(
            (entry) => <String, Object?>{
              'questionNumber': entry['questionNumber'],
              'baselineParity': entry['baselineParity'],
              'provenanceParity': entry['provenanceParity'],
              'firstMismatchField': entry['firstMismatchField'],
            },
          )
          .toList(),
      <Map<String, Object?>>[
        for (var questionNumber = 1; questionNumber <= 7; questionNumber++)
          <String, Object?>{
            'questionNumber': questionNumber,
            'baselineParity': true,
            'provenanceParity': true,
            'firstMismatchField': 'none',
          },
      ],
    );
    expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
    expect(gate.reason, ocrTypedCandidateReadyReason);
  });
}

Map<String, Object?> _observeChoiceChain(OcrDocument document) {
  final regionized = const OcrQuestionRegionizer().regionize(document);
  expect(regionized.regions, hasLength(1));
  final region = regionized.regions.single;
  final sourceDocument = const OcrSourceDocumentAdapter().convert(
    document,
    sourceId: _sourceId,
  );
  final typedRegion = const OcrQuestionRegionBridge().convert(
    region,
    sourceDocument: sourceDocument,
  );
  final answerFragments = typedRegion.fragmentsFor(QuestionRegionField.answer);
  final bridgeAnswer = _materializedAnswer(answerFragments);
  final draft = const TypedQuestionAssembler().assemble(
    typedRegion,
    questionId: 'synthetic_question',
  );
  final projected = const QuestionDraftV2LegacyProjector().project(
    draft: draft,
    region: typedRegion,
    profile: OcrLegacyProjectionProfile(),
    explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
  );
  final baseline = _legacyBaseline(region);
  final projectedAnswer = projected.question['standard_answer'] as String;
  final baselineAnswer = baseline['standard_answer'] as String;
  final batch = buildOcrTypedCandidateBatch(
    document: document,
    regions: <OcrQuestionRegion>[region],
    legacyQuestions: <Map<String, dynamic>>[baseline],
    uuidV4Factory: _uuidV4Sequence(),
    explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
  );
  final gate = applyOcrTypedCandidateGate(
    batch: batch,
    finalQuestions: <Map<String, dynamic>>[baseline],
    singleFile: true,
  );
  final answerOwned = region.ownedSources
      .where((owned) => owned.field == OcrRegionField.answer)
      .toList(growable: false);

  return <String, Object?>{
    'regionAnswerPartCount': region.answerParts.length,
    'regionAnswerTextLength': region.answerText.length,
    'regionOwnedAnswerSourceCount': answerOwned.length,
    'ownedAnswerSources': <Map<String, Object?>>[
      for (final owned in answerOwned)
        <String, Object?>{
          'hasExplicitStart': owned.startCodeUnitOffset != null,
          'hasExplicitEnd': owned.endCodeUnitOffset != null,
          'ownedTextLength': owned.text?.length,
          'sourcePartTextLength':
              _sourcePartTextLength(sourceDocument, owned.blockId),
        },
    ],
    'typedAnswerFragmentCount': answerFragments.length,
    'typedAnswerFragmentsWithSlice':
        answerFragments.where((fragment) => fragment.slice != null).length,
    'typedAnswerFragmentsWithoutSlice':
        answerFragments.where((fragment) => fragment.slice == null).length,
    'bridgeMaterializedAnswerLength': bridgeAnswer.length,
    'regionVsBridgeExactEqual': region.answerText == bridgeAnswer,
    'draftAnswerKind': _answerKind(draft.answer),
    'draftAnswerProjectedLength': _answerProjectedLength(draft.answer),
    'projectedStandardAnswerLength': projectedAnswer.length,
    'baselineStandardAnswerLength': baselineAnswer.length,
    'projectedVsBaselineExactEqual': projectedAnswer == baselineAnswer,
    'choiceMarkerCountInRegionAnswer':
        _answerChoiceMarkerCount(region.answerText),
    'choiceMarkerCountInBridgeAnswer': _answerChoiceMarkerCount(bridgeAnswer),
    'choiceMarkerCountInExplanation':
        _explanationChoiceMarkerCount(region.explanationText),
    'regionMarkerMatchesBaseline':
        _answerChoiceMarkerMatches(region.answerText, baselineAnswer),
    'bridgeMarkerMatchesBaseline':
        _answerChoiceMarkerMatches(bridgeAnswer, baselineAnswer),
    'explanationMarkerMatchesBaseline': _explanationChoiceMarkerMatches(
      region.explanationText,
      baselineAnswer,
    ),
    'gateRoute': gate.route.name,
    'gateReason': gate.reason,
  };
}

String _materializedAnswer(List<QuestionRegionFragment> fragments) {
  final nodes = <ContentNode>[];
  for (final fragment in fragments) {
    final part = fragment.part;
    if (part is! SourceContentPart) {
      throw StateError('Synthetic answer fixture produced structural content.');
    }
    if (nodes.isNotEmpty) nodes.add(const TextNode('\n'));
    nodes
        .addAll(materializeQuestionRegionContent(part.content, fragment.slice));
  }
  return const RichContentTextProjection().project(RichContent(nodes: nodes));
}

int _sourcePartTextLength(SourceDocument document, String blockId) {
  final part = document.parts.singleWhere(
    (candidate) => candidate.sourceRef.start?.blockId == blockId,
  );
  if (part is! SourceContentPart) {
    throw StateError('Synthetic answer source was not plain text.');
  }
  return const RichContentTextProjection().project(part.content).length;
}

String _answerKind(QuestionAnswer? answer) {
  return switch (answer) {
    null => 'null',
    ChoiceAnswer() => 'ChoiceAnswer',
    ContentAnswer() => 'ContentAnswer',
  };
}

int _answerProjectedLength(QuestionAnswer? answer) {
  return switch (answer) {
    null => 0,
    ChoiceAnswer(:final optionIds) => optionIds.join().length,
    ContentAnswer(:final content) =>
      const RichContentTextProjection().project(content).length,
  };
}

int _answerChoiceMarkerCount(String text) => RegExp(
      r'(?:^|答案|应选|选)\s*([A-D])(?:\b|[。．.、，,；;])',
    ).allMatches(text).length;

bool _answerChoiceMarkerMatches(String text, String baselineAnswer) {
  final match = RegExp(
    r'(?:^|答案|应选|选)\s*([A-D])(?:\b|[。．.、，,；;])',
  ).firstMatch(text);
  return match != null &&
      match.group(1)!.toUpperCase() == baselineAnswer.trim().toUpperCase();
}

int _explanationChoiceMarkerCount(String text) =>
    RegExp(r'(?:应选|故选|答案为?)\s*([A-D])').allMatches(text).length;

bool _explanationChoiceMarkerMatches(String text, String baselineAnswer) {
  final match = RegExp(r'(?:应选|故选|答案为?)\s*([A-D])').firstMatch(text);
  return match != null &&
      match.group(1)!.toUpperCase() == baselineAnswer.trim().toUpperCase();
}

Map<String, dynamic> _legacyBaseline(OcrQuestionRegion region) {
  return const ImportQuestionFieldPolicy().applyToMap(
    const OcrQuestionAssembler().assemble(region).question,
    mode: ExplanationRetentionMode.allQuestionTypes,
  );
}

OcrDocument _singleChoiceDocument({
  required String answerBody,
  required String explanation,
  bool splitAnswerValueIntoWholePart = false,
}) {
  final blocks = <OcrBlock>[
    _block('section', 0, '一、选择题'),
    _questionBlock(1, 1),
    if (splitAnswerValueIntoWholePart) ...<OcrBlock>[
      _block('answer_label', 2, '答案：'),
      _block('answer_value', 3, answerBody),
      _block('explanation', 4, '解析：$explanation'),
    ] else ...<OcrBlock>[
      _block('answer', 2, '答案：$answerBody'),
      _block('explanation', 3, '解析：$explanation'),
    ],
  ];
  return OcrDocument(
    sourceName: 'synthetic_choice_answer_fixture.pdf',
    pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrDocument _sevenChoiceQuestionDocument() {
  final blocks = <OcrBlock>[_block('section', 0, '一、选择题')];
  var readingOrder = 1;
  for (var number = 1; number <= 7; number++) {
    blocks.add(_questionBlock(number, readingOrder++));
    blocks.add(
      _block(
        'answer_$number',
        readingOrder++,
        '答案：${number == 7 ? _q7NoisyAnswerBody() : 'A'}',
      ),
    );
    blocks.add(
      _block(
        'explanation_$number',
        readingOrder++,
        '解析：Synthetic rationale. 故选 A',
      ),
    );
  }
  return OcrDocument(
    sourceName: 'synthetic_q1_q7_choice_batch.pdf',
    pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrBlock _questionBlock(int number, int readingOrder) {
  return _block(
    'question_$number',
    readingOrder,
    '$number. Synthetic choice prompt\n'
        '(A) Alpha\n'
        '(B) Beta\n'
        '(C) Gamma\n'
        '(D) Delta',
  );
}

OcrBlock _block(String id, int readingOrder, String text) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: 'text',
    text: text,
    bbox: const <double>[],
    readingOrder: readingOrder,
  );
}

String _q7NoisyAnswerBody() {
  return 'A ${List<String>.filled(540, 'x').join()}';
}

String Function() _uuidV4Sequence() {
  var value = 0;
  return () {
    value++;
    final suffix = value.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$suffix';
  };
}
