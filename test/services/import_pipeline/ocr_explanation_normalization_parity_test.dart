import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_text_normalization.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';

void main() {
  test(
    'plain OCR explanation normalization stays exact across the full chain',
    () {
      final observation = _observeExplanationChain(
        explanationBlocks: <String>[
          '解析：Synthetic  premise\r\nnext line',
          'Continuation\t\tsegment',
        ],
      );

      expect(observation['regionFragmentCount'], 2, reason: '$observation');
      expect(observation['typedFragmentCount'], 2, reason: '$observation');
      expect(observation['bridgeNodeCount'], 3, reason: '$observation');
      expect(
        observation['bridgeNodeKinds'],
        <String>['text', 'text', 'text'],
        reason: '$observation',
      );
      expect(observation['draftNodeCount'], 1, reason: '$observation');
      expect(
        observation['draftNodeKinds'],
        <String>['text'],
        reason: '$observation',
      );
      expect(observation['assemblerJoinedTextIsNull'], isFalse,
          reason: '$observation');
      expect(observation['bridgeHasLeadingExplanationLabel'], isTrue,
          reason: '$observation');
      expect(observation['draftHasLeadingExplanationLabel'], isFalse,
          reason: '$observation');
      expect(observation['projectedHasLeadingExplanationLabel'], isFalse,
          reason: '$observation');
      expect(observation['regionVsBaselineExactEqual'], isTrue,
          reason: '$observation');
      expect(observation['draftVsProjectedExactEqual'], isTrue,
          reason: '$observation');
      expect(
        observation['baselineVsProjectedDiagnosticNormalizedEqual'],
        isTrue,
        reason: '$observation',
      );
      expect(
        observation['draftVsBaselineDiagnosticNormalizedEqual'],
        isTrue,
        reason: '$observation',
      );
      expect(observation['sharedNormalizeDraftVsBaselineExactEqual'], isTrue,
          reason: '$observation');
      expect(
        observation['sharedNormalizeProjectedVsBaselineExactEqual'],
        isTrue,
        reason: '$observation',
      );
      expect(observation['draftStripFieldLabelLengthDelta'], 0,
          reason: '$observation');
      expect(observation['projectedStripFieldLabelLengthDelta'], 0,
          reason: '$observation');
      expect(observation['projectedMinusBaselineLength'], 0,
          reason: '$observation');
      expect(observation['baselineVsProjectedExactEqual'], isTrue,
          reason: '$observation');
      expect(observation['draftOptionCount'], 4, reason: '$observation');
      expect(observation['projectedOptionCount'], 4, reason: '$observation');
      expect(observation['baselineOptionCount'], 4, reason: '$observation');
      expect(observation['gateRoute'], ImportStorageRoute.typedV2.name,
          reason: '$observation');
      expect(observation['gateReason'], ocrTypedCandidateReadyReason,
          reason: '$observation');
    },
  );

  for (final fixture in <({String name, List<String> explanationBlocks})>[
    (
      name: 'repeated horizontal whitespace',
      explanationBlocks: <String>['解析：Synthetic  premise'],
    ),
    (
      name: 'CRLF normalization',
      explanationBlocks: <String>['解析：Synthetic\r\npremise'],
    ),
    (
      name: 'multi-fragment boundary',
      explanationBlocks: <String>['解析：Synthetic premise', 'Continuation'],
    ),
    (
      name: 'explanation label stripping',
      explanationBlocks: <String>['解析：Synthetic premise'],
    ),
  ]) {
    test('${fixture.name} preserves exact explanation parity', () {
      final observation = _observeExplanationChain(
        explanationBlocks: fixture.explanationBlocks,
      );

      expect(
        <String, Object?>{
          'regionVsBaselineExactEqual':
              observation['regionVsBaselineExactEqual'],
          'draftVsBaselineExactEqual': observation['draftVsBaselineExactEqual'],
          'baselineVsProjectedExactEqual':
              observation['baselineVsProjectedExactEqual'],
          'projectedMinusBaselineLength':
              observation['projectedMinusBaselineLength'],
          'draftOptionCount': observation['draftOptionCount'],
          'projectedOptionCount': observation['projectedOptionCount'],
          'baselineOptionCount': observation['baselineOptionCount'],
          'gateRoute': observation['gateRoute'],
          'gateReason': observation['gateReason'],
        },
        <String, Object?>{
          'regionVsBaselineExactEqual': true,
          'draftVsBaselineExactEqual': true,
          'baselineVsProjectedExactEqual': true,
          'projectedMinusBaselineLength': 0,
          'draftOptionCount': 4,
          'projectedOptionCount': 4,
          'baselineOptionCount': 4,
          'gateRoute': ImportStorageRoute.typedV2.name,
          'gateReason': ocrTypedCandidateReadyReason,
        },
        reason: '$observation',
      );
    });
  }
}

Map<String, Object?> _observeExplanationChain({
  required List<String> explanationBlocks,
}) {
  final document = _choiceDocument(explanationBlocks);
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
  final explanationFragments =
      typedRegion.fragmentsFor(QuestionRegionField.explanation);
  final bridgeNodes = <ContentNode>[];
  for (final fragment in explanationFragments) {
    final part = fragment.part;
    if (part is! SourceContentPart) {
      throw StateError(
        'Synthetic plain-text fixture produced a structural explanation.',
      );
    }
    if (bridgeNodes.isNotEmpty) bridgeNodes.add(const TextNode('\n'));
    bridgeNodes.addAll(
      materializeQuestionRegionContent(part.content, fragment.slice),
    );
  }

  const textProjection = RichContentTextProjection();
  final bridgeMaterialized = textProjection.project(
    RichContent(nodes: bridgeNodes),
  );
  final draft = const TypedQuestionAssembler().assemble(
    typedRegion,
    questionId: 'synthetic_question',
  );
  final draftExplanation = textProjection.project(draft.explanation!);
  final projected = const QuestionDraftV2LegacyProjector().project(
    draft: draft,
    region: typedRegion,
    profile: OcrLegacyProjectionProfile(),
    explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
  );
  final projectedExplanation = projected.question['explanation'] as String;
  final baseline = const ImportQuestionFieldPolicy().applyToMap(
    const OcrQuestionAssembler().assemble(region).question,
    mode: ExplanationRetentionMode.allQuestionTypes,
  );
  final baselineExplanation = baseline['explanation'] as String;

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

  return <String, Object?>{
    'regionExplanationLength': region.explanationText.length,
    'bridgeMaterializedExplanationLength': bridgeMaterialized.length,
    'draftExplanationLength': draftExplanation.length,
    'projectedExplanationLength': projectedExplanation.length,
    'baselineExplanationLength': baselineExplanation.length,
    ..._prefixedMetrics('region', region.explanationText),
    ..._prefixedMetrics('bridge', bridgeMaterialized),
    ..._prefixedMetrics('draft', draftExplanation),
    ..._prefixedMetrics('projected', projectedExplanation),
    ..._prefixedMetrics('baseline', baselineExplanation),
    'regionFragmentCount': region.explanationParts.length,
    'typedFragmentCount': explanationFragments.length,
    'bridgeNodeCount': bridgeNodes.length,
    'bridgeNodeKinds': bridgeNodes.map(_nodeKind).toList(growable: false),
    'draftNodeCount': draft.explanation!.nodes.length,
    'draftNodeKinds':
        draft.explanation!.nodes.map(_nodeKind).toList(growable: false),
    'assemblerJoinedTextIsNull': bridgeNodes.any((node) => node is! TextNode),
    'bridgeHasLeadingExplanationLabel':
        _hasLeadingExplanationLabel(bridgeMaterialized),
    'draftHasLeadingExplanationLabel':
        _hasLeadingExplanationLabel(draftExplanation),
    'projectedHasLeadingExplanationLabel':
        _hasLeadingExplanationLabel(projectedExplanation),
    'regionVsBaselineExactEqual': region.explanationText == baselineExplanation,
    'draftVsBaselineExactEqual': draftExplanation == baselineExplanation,
    'draftVsProjectedExactEqual': draftExplanation == projectedExplanation,
    'baselineVsProjectedExactEqual':
        baselineExplanation == projectedExplanation,
    'baselineVsProjectedDiagnosticNormalizedEqual':
        _diagnosticNormalize(baselineExplanation) ==
            _diagnosticNormalize(projectedExplanation),
    'draftVsBaselineDiagnosticNormalizedEqual':
        _diagnosticNormalize(draftExplanation) ==
            _diagnosticNormalize(baselineExplanation),
    'sharedNormalizeDraftVsBaselineExactEqual':
        normalizeOcrText(draftExplanation) == baselineExplanation,
    'sharedNormalizeProjectedVsBaselineExactEqual':
        normalizeOcrText(projectedExplanation) == baselineExplanation,
    'draftStripFieldLabelLengthDelta':
        _diagnosticStripFieldLabels(draftExplanation).length -
            draftExplanation.length,
    'projectedStripFieldLabelLengthDelta':
        _diagnosticStripFieldLabels(projectedExplanation).length -
            projectedExplanation.length,
    'projectedMinusBaselineLength':
        projectedExplanation.length - baselineExplanation.length,
    'draftMinusBaselineLength':
        draftExplanation.length - baselineExplanation.length,
    'bridgeMinusDraftLength':
        bridgeMaterialized.length - draftExplanation.length,
    'draftOptionCount': draft.options.length,
    'projectedOptionCount': (projected.question['options'] as List).length,
    'baselineOptionCount': (baseline['options'] as List).length,
    'gateRoute': gate.route.name,
    'gateReason': gate.reason,
  };
}

Map<String, Object?> _prefixedMetrics(String prefix, String input) {
  return <String, Object?>{
    '${prefix}SpaceCount': _countCodeUnit(input, 0x20),
    '${prefix}TabCount': _countCodeUnit(input, 0x09),
    '${prefix}CrCount': _countCodeUnit(input, 0x0D),
    '${prefix}LfCount': _countCodeUnit(input, 0x0A),
  };
}

int _countCodeUnit(String input, int target) {
  return input.codeUnits.where((codeUnit) => codeUnit == target).length;
}

String _nodeKind(ContentNode node) {
  return switch (node) {
    TextNode() => 'text',
    InlineMathNode() => 'inlineMath',
    BlockMathNode() => 'blockMath',
    ImageNode() => 'image',
    TableNode() => 'table',
    RawFallbackNode() => 'rawFallback',
  };
}

String _diagnosticNormalize(String input) {
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

bool _hasLeadingExplanationLabel(String input) {
  return RegExp(
    r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*',
  ).hasMatch(input);
}

String _diagnosticStripFieldLabels(String input) {
  return input
      .replaceFirst(RegExp(r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*'), '')
      .replaceFirst(
        RegExp(r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*'),
        '',
      )
      .trim();
}

OcrDocument _choiceDocument(List<String> explanationBlocks) {
  final blocks = <OcrBlock>[
    _block('section', 0, '一、选择题'),
    _block(
      'question',
      1,
      '1. Synthetic question\n'
          '(A) Alpha\n'
          '(B) Beta\n'
          '(C) Gamma\n'
          '(D) Delta',
    ),
    _block('answer', 2, '答案：A'),
    for (var index = 0; index < explanationBlocks.length; index++)
      _block(
        'explanation_$index',
        index + 3,
        explanationBlocks[index],
      ),
  ];
  return OcrDocument(
    sourceName: 'synthetic_explanation_normalization.pdf',
    pages: <OcrPage>[
      OcrPage(pageIndex: 1, blocks: blocks),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
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

String Function() _uuidV4Sequence() {
  var value = 0;
  return () {
    value++;
    final suffix = value.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$suffix';
  };
}
