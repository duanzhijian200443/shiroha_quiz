// R3D1 read-only acceptance: authoritative legacy OCR question assembly
// against the stopped R3C typed shadow path.
//
// Evidence class: synthetic fixtures only. The harness is a pure in-memory
// chain with no Provider, Replay read/write, network, database, UI,
// filesystem, application, or environment-secret call site, so Provider calls
// are 0 by construction.
//
// Legacy path (authoritative):
//   OcrQuestionRegionizer -> OcrQuestionAssembler
// Shadow path (stopped R3C, no production wiring):
//   OcrSourceDocumentAdapter -> OcrQuestionRegionBridge ->
//   TypedQuestionAssembler -> QuestionDraftV2LegacyProjector(OCR profile)
//
// Expected legacy maps are never constructed by hand; both maps come from the
// real paths above. The only comparison normalization is the frozen bridge
// token mapping that collapses parameterized region diagnostics
// (kind_declared_from_section:*, kind_inferred_from_question_number_range:*,
// reference_answer_pattern:*) to their stable codes on the legacy side.
// legacy_provenance_coarse remains typed-only and must never appear in either
// legacy map's diagnostics.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

const _regionizer = OcrQuestionRegionizer();
const _legacyAssembler = OcrQuestionAssembler();
const _sourceAdapter = OcrSourceDocumentAdapter();
const _bridge = OcrQuestionRegionBridge();
const _typedAssembler = TypedQuestionAssembler();
const _projector = QuestionDraftV2LegacyProjector();

/// Provider calls in this pure harness: there is no callable Provider site,
/// so the count is constant zero.
const _providerCallCount = 0;

typedef _ShadowAssembly = ({
  QuestionRegion region,
  QuestionDraftV2 draft,
  LocalAssemblyResult result,
});

typedef _PathResult = ({
  OcrQuestionRegion region,
  LocalAssemblyResult legacy,
  _ShadowAssembly shadow,
});

void main() {
  group('R3D1 read-only shadow parity acceptance', () {
    test(
      '2022-equivalent 22/22 ordered questions match on both real paths',
      () {
        final document = _build2022Equivalent();
        final paths = _runBothPaths(document, 'r3d1_2022_source');

        expect(paths, hasLength(22));
        expect(
          paths.map((path) => path.region.number).toList(),
          List<int>.generate(22, (index) => index + 1),
        );
        for (final path in paths) {
          _expectQuestionParity(
            path.region,
            path.legacy,
            path.shadow,
            kind: QuestionKind.shortAnswer,
            readiness: QuestionRegionReadiness.needsReview,
          );
        }
        // Question 21 keeps dropped option text in both maps (subjective).
        final question21 =
            paths.singleWhere((path) => path.region.number == 21);
        expect(question21.legacy.question['content'], contains('A. 选项甲'));
        expect(
          question21.shadow.result.question['content'],
          contains('A. 选项甲'),
        );
        expect(question21.legacy.question['options'], isEmpty);
        expect(question21.shadow.result.question['options'], isEmpty);
        // Question 20 has no answer block: missing_answer parity.
        final question20 =
            paths.singleWhere((path) => path.region.number == 20);
        expect(
          question20.legacy.question['diagnostics'],
          contains('missing_answer'),
        );
        expect(
          question20.shadow.result.question['diagnostics'],
          contains('missing_answer'),
        );
        _expectZeroProviderCalls();
      },
    );

    test(
      '2019-equivalent 23/23 parenthesized questions keep Roman subquestions '
      'and match on both real paths',
      () {
        final document = _build2019Equivalent();
        final regionized = _regionizer.regionize(document);

        expect(regionized.regions, hasLength(23));
        expect(
          regionized.regions.map((region) => region.number).toList(),
          List<int>.generate(23, (index) => index + 1),
        );
        expect(regionized.diagnostics['parenthesizedArabicAcceptedCount'], 23);
        expect(regionized.diagnostics['romanSubquestionCount'], 2);
        final question15 =
            regionized.regions.singleWhere((region) => region.number == 15);
        expect(question15.stemText, contains('（Ⅰ）'));
        expect(question15.stemText, contains('（Ⅱ）'));

        final paths = _runBothPaths(document, 'r3d1_2019_source');
        for (final path in paths) {
          _expectQuestionParity(
            path.region,
            path.legacy,
            path.shadow,
            kind: QuestionKind.singleChoice,
            readiness: QuestionRegionReadiness.needsReview,
          );
        }

        // C4: the real bridge materializes a within-block SourceSlice for the
        // marker-prefixed first stem block.
        final sourceDocument =
            _sourceAdapter.convert(document, sourceId: 'r3d1_2019_source');
        final firstRegion = _bridge.convert(regionized.regions.first,
            sourceDocument: sourceDocument);
        final stemFragment =
            firstRegion.fragmentsFor(QuestionRegionField.stem).first;
        final slice = stemFragment.slice;
        expect(slice, isNotNull);
        expect(slice!.startNodeIndex, 0);
        expect(slice.startCodeUnitOffset, greaterThan(0));
        expect(slice.endNodeIndex, 1);
        expect(slice.endCodeUnitOffset, 0);
        expect(
          _materializedText(stemFragment),
          'Synthetic prompt marker 1.\n'
          'A. 选项甲\nB. 选项乙\nC. 选项丙\nD. 选项丁',
        );
        _expectZeroProviderCalls();
      },
    );

    test(
      'cross-page provenance stays precise in both maps and coarse typed-only',
      () {
        final document = _build2022Equivalent();
        final paths = _runBothPaths(document, 'r3d1_2022_source');
        final crossPage = paths.singleWhere((path) => path.region.number == 22);

        expect(crossPage.region.sourcePageIndices, <int>[1, 2]);
        expect(crossPage.region.isCrossPage, isTrue);
        expect(
          crossPage.legacy.question['source_page_indices'],
          <int>[1, 2],
        );
        expect(
          crossPage.shadow.result.question['source_page_indices'],
          <int>[1, 2],
        );
        expect(
          crossPage.shadow.result.question['source_block_ids'],
          crossPage.legacy.question['source_block_ids'],
        );
        expect(
          crossPage.shadow.region.issues.map((issue) => issue.code).toList(),
          contains('legacy_provenance_coarse'),
        );
        expect(
          crossPage.shadow.draft.issues.map((issue) => issue.code).toList(),
          contains('legacy_provenance_coarse'),
        );
        expect(
          crossPage.shadow.result.diagnostics,
          isNot(contains('legacy_provenance_coarse')),
        );
        expect(
          crossPage.legacy.diagnostics,
          isNot(contains('legacy_provenance_coarse')),
        );
        expect(crossPage.legacy.repairRecommended, isTrue);
        expect(crossPage.shadow.result.repairRecommended, isTrue);
        _expectZeroProviderCalls();
      },
    );

    test(
      'document-coarse provenance stays typed-only and never enters legacy '
      'diagnostics',
      () {
        final document = _buildDuplicateBlockIdDocument();
        final paths = _runBothPaths(document, 'r3d1_duplicate_source');
        expect(paths, hasLength(2));
        final first = paths.first;

        expect(
          first.shadow.region.issues.map((issue) => issue.code).toList(),
          contains('legacy_provenance_coarse'),
        );
        expect(
          first.shadow.draft.issues.map((issue) => issue.code).toList(),
          contains('legacy_provenance_coarse'),
        );
        expect(
          first.shadow.result.diagnostics,
          isNot(contains('legacy_provenance_coarse')),
        );
        expect(
          first.legacy.diagnostics,
          isNot(contains('legacy_provenance_coarse')),
        );
        // Document-coarse degradation: the legacy string model keeps the
        // duplicated block identity while the typed path cannot recover it.
        final legacyBlocks =
            (first.legacy.question['source_block_ids'] as List<dynamic>)
                .cast<String>();
        final shadowBlocks =
            (first.shadow.result.question['source_block_ids'] as List<dynamic>)
                .cast<String>();
        expect(legacyBlocks, contains('dup_q'));
        expect(shadowBlocks, isNot(contains('dup_q')));
        expect(
          first.shadow.result.question['source_page_indices'],
          first.legacy.question['source_page_indices'],
        );
        _expectZeroProviderCalls();
      },
    );

    test(
      'raw fallback is preserved typed and stops legacy projection explicitly',
      () {
        final raw = RawFallbackNode(<Object?, Object?>{
          'type': 'raw_fallback',
          'payload': <Object?, Object?>{'kind': 'span'},
        });
        final ref = SourceRef.document(sourceId: 'r3d1_boundary_source');
        final region = QuestionRegion(
          questionNumber: 1,
          fragments: <QuestionRegionFragment>[
            QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: SourceContentPart(
                sourceRef: ref,
                content: RichContent(nodes: <ContentNode>[raw]),
              ),
            ),
          ],
          kindHint: QuestionRegionKindHint.unknown,
        );
        final draft =
            _typedAssembler.assemble(region, questionId: 'shadow_boundary_raw');

        // Explicit-stop evidence, not parity: the typed draft preserves the
        // node and the legacy projector refuses to drop it.
        expect(draft.stem.nodes, <ContentNode>[raw]);
        expect(
          () => _projector.project(
            draft: draft,
            region: region,
            profile: const OcrLegacyProjectionProfile(),
          ),
          throwsA(
            isA<LegacyProjectionUnsupportedException>().having(
              (error) => error.kindCode,
              'kindCode',
              'raw_fallback',
            ),
          ),
        );
        _expectZeroProviderCalls();
      },
    );

    test(
      'same localAssetId across sourceIds stays source-qualified and stops '
      'typed assembly explicitly',
      () {
        final asset = AssetRef(assetId: 'img_001', kind: AssetKind.image);
        final region = QuestionRegion(
          questionNumber: 1,
          fragments: <QuestionRegionFragment>[
            QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: SourceAssetPart(
                sourceRef: SourceRef.at(
                  sourceId: 'r3d1_source_a',
                  point: SourcePoint.block(
                    pageNumber: 1,
                    blockId: 'b1',
                    readingOrder: 0,
                  ),
                ),
                asset: asset,
              ),
            ),
            QuestionRegionFragment(
              field: QuestionRegionField.answer,
              part: SourceAssetPart(
                sourceRef: SourceRef.at(
                  sourceId: 'r3d1_source_b',
                  point: SourcePoint.block(
                    pageNumber: 1,
                    blockId: 'b1',
                    readingOrder: 0,
                  ),
                ),
                asset: asset,
              ),
            ),
          ],
          kindHint: QuestionRegionKindHint.unknown,
        );

        // Explicit-stop evidence, not parity: the legacy string model cannot
        // represent two source-qualified identities with one local id.
        expect(region.assetRefs, hasLength(2));
        expect(
          region.assetRefs.map((ref) => ref.localAssetId).toSet(),
          <String>{'img_001'},
        );
        expect(
          region.assetRefs.map((ref) => ref.sourceId).toSet(),
          <String>{'r3d1_source_a', 'r3d1_source_b'},
        );
        final draft = _typedAssembler.assemble(
          region,
          questionId: 'shadow_boundary_asset',
        );
        expect(draft.assetRefs, hasLength(2));
        expect(
          draft.assetRefs.map((ref) => ref.localAssetId).toSet(),
          <String>{'img_001'},
        );
        expect(
          draft.assetRefs.map((ref) => ref.sourceId).toSet(),
          <String>{'r3d1_source_a', 'r3d1_source_b'},
        );
        expect(draft.stem.nodes.first, isA<ImageNode>());
        _expectZeroProviderCalls();
      },
    );
  });
}

/// Runs both real paths over one synthetic [document] and pairs each legacy
/// region with its typed shadow assembly.
List<_PathResult> _runBothPaths(OcrDocument document, String sourceId) {
  final regionized = _regionizer.regionize(document);
  final sourceDocument = _sourceAdapter.convert(document, sourceId: sourceId);
  final results = <_PathResult>[];
  for (final region in regionized.regions) {
    results.add((
      region: region,
      legacy: _legacyAssembler.assemble(region),
      shadow: _shadowAssemble(
        region,
        sourceDocument,
        'shadow_${sourceId}_q${region.number}',
      ),
    ));
  }
  return results;
}

_ShadowAssembly _shadowAssemble(
  OcrQuestionRegion region,
  SourceDocument sourceDocument,
  String questionId,
) {
  final typedRegion = _bridge.convert(region, sourceDocument: sourceDocument);
  final draft = _typedAssembler.assemble(typedRegion, questionId: questionId);
  final result = _projector.project(
    draft: draft,
    region: typedRegion,
    profile: const OcrLegacyProjectionProfile(),
  );
  return (region: typedRegion, draft: draft, result: result);
}

/// Asserts full legacy-map parity for one question plus the typed
/// QuestionRegion/QuestionDraft semantics that have no legacy-map field.
void _expectQuestionParity(
  OcrQuestionRegion region,
  LocalAssemblyResult legacy,
  _ShadowAssembly shadow, {
  required QuestionKind kind,
  required QuestionRegionReadiness readiness,
}) {
  final label = 'question ${region.number}';
  _expectFullParity(legacy.question, shadow.result.question, label: label);
  expect(
    shadow.result.repairRecommended,
    legacy.repairRecommended,
    reason: '$label repairRecommended',
  );
  expect(
    shadow.result.rejected,
    legacy.rejected,
    reason: '$label rejected',
  );
  expect(shadow.region.questionNumber, region.number, reason: label);
  expect(shadow.draft.questionNumber, region.number, reason: label);
  expect(shadow.draft.kind, kind, reason: label);
  // The typed draft copies region issues first and may append typed-only
  // issues (for example choice_options_less_than_2) that have no legacy
  // counterpart; the region issues must remain an ordered prefix.
  expect(
    shadow.draft.issues.take(shadow.region.issues.length).toList(),
    shadow.region.issues,
    reason: label,
  );
  expect(shadow.region.readiness, readiness, reason: label);
}

/// Compares every legacy-map field after applying the frozen bridge token
/// normalization to legacy diagnostics only.
void _expectFullParity(
  Map<String, dynamic> legacy,
  Map<String, dynamic> shadow, {
  required String label,
}) {
  final normalizedLegacy = <String, dynamic>{...legacy};
  final legacyDiagnostics =
      (legacy['diagnostics'] as List<dynamic>).cast<String>();
  for (final raw in legacyDiagnostics) {
    final mapped = _normalizeLegacyDiagnostic(raw);
    if (mapped != raw) {
      expect(
        _parameterizedDiagnosticPrefixes.any(raw.startsWith),
        isTrue,
        reason: '$label: unexpected parameterized legacy diagnostic: $raw',
      );
    }
  }
  normalizedLegacy['diagnostics'] =
      legacyDiagnostics.map(_normalizeLegacyDiagnostic).toList();
  expect(shadow.keys.toSet(), legacy.keys.toSet(), reason: label);
  expect(shadow, normalizedLegacy, reason: label);
}

const _parameterizedDiagnosticPrefixes = <String>[
  'kind_declared_from_section:',
  'kind_inferred_from_question_number_range:',
  'reference_answer_pattern:',
];

/// Mirrors the frozen OcrQuestionRegionBridge token mapping so the legacy
/// diagnostics can be compared against the shadow projection's stable codes.
String _normalizeLegacyDiagnostic(String raw) {
  if (raw.startsWith('kind_declared_from_section:')) {
    return 'kind_declared_from_section';
  }
  if (raw.startsWith('kind_inferred_from_question_number_range:')) {
    return 'kind_inferred_from_question_number_range';
  }
  if (raw.startsWith('reference_answer_pattern:')) {
    return 'reference_answer_pattern';
  }
  return raw;
}

/// Materializes the UTF-16 half-open SourceSlice interval of [fragment] with
/// the documented SourceSlice semantics shared by the typed assembler and the
/// legacy projector.
String _materializedText(QuestionRegionFragment fragment) {
  final part = fragment.part;
  if (part is! SourceContentPart) return '';
  final nodes = part.content.nodes;
  final slice = fragment.slice;
  if (slice == null) {
    return nodes.map(_searchNodeText).join();
  }
  final endExcluded = slice.endCodeUnitOffset == 0;
  final lastIncluded =
      endExcluded ? slice.endNodeIndex - 1 : slice.endNodeIndex;
  final buffer = StringBuffer();
  for (var index = slice.startNodeIndex; index <= lastIncluded; index++) {
    final node = nodes[index];
    final startOffset =
        index == slice.startNodeIndex ? slice.startCodeUnitOffset : 0;
    final endOffset =
        index == slice.endNodeIndex ? slice.endCodeUnitOffset : null;
    if (node is TextNode) {
      buffer.write(
        endOffset == null
            ? node.text.substring(startOffset)
            : node.text.substring(startOffset, endOffset),
      );
    } else {
      buffer.write(_searchNodeText(node));
    }
  }
  return buffer.toString();
}

String _searchNodeText(ContentNode node) {
  return switch (node) {
    TextNode(:final text) => text,
    InlineMathNode(:final latex) => latex,
    BlockMathNode(:final latex) => latex,
    ImageNode(:final altText) => altText ?? '',
    RawFallbackNode() => '',
  };
}

void _expectZeroProviderCalls() {
  expect(
    _providerCallCount,
    0,
    reason: 'the pure harness has no Provider, Replay, network, database, '
        'UI, filesystem, or application call site',
  );
}

OcrBlock _block(
  String blockId,
  int pageIndex,
  int readingOrder,
  String text,
) {
  return OcrBlock(
    blockId: blockId,
    pageIndex: pageIndex,
    type: 'text',
    text: text,
    bbox: const <double>[],
    readingOrder: readingOrder,
  );
}

OcrDocument _document(String sourceName, List<OcrPage> pages) {
  return OcrDocument(
    sourceName: sourceName,
    pages: pages,
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

/// 2022-equivalent paper: 22 ordered subjective questions with answers and
/// explanations; question 21 carries dropped A-D options, question 20 has no
/// answer block, and question 22 spans two pages.
OcrDocument _build2022Equivalent() {
  final blocks = <OcrBlock>[
    _block('section_heading', 1, 0, '三、解答题'),
  ];
  var order = 1;
  for (var number = 1; number <= 21; number++) {
    final stemText = number == 21
        ? '21. Synthetic prompt marker 21.\n'
            'A. 选项甲\nB. 选项乙\nC. 选项丙\nD. 选项丁'
        : '$number. Synthetic prompt marker $number.';
    blocks.add(_block('q_$number', 1, order++, stemText));
    if (number != 20) {
      blocks.add(
        _block(
          'answer_$number',
          1,
          order++,
          '答案：synthetic-result-$number',
        ),
      );
    }
    blocks.add(
      _block(
        'explanation_$number',
        1,
        order++,
        '解析：Synthetic rationale marker $number.',
      ),
    );
  }
  blocks.add(_block('q_22', 1, order++, '22. Synthetic prompt marker 22.'));
  blocks.add(_block('answer_22', 2, 0, '答案：synthetic-result-22'));
  blocks
      .add(_block('explanation_22', 2, 1, '解析：Synthetic rationale marker 22.'));
  return _document(
    'r3d1_synthetic_2022_equivalent',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: blocks.where((block) => block.pageIndex == 1).toList(),
      ),
      OcrPage(
        pageIndex: 2,
        blocks: blocks.where((block) => block.pageIndex == 2).toList(),
      ),
    ],
  );
}

/// 2019-equivalent paper: 23 parenthesized Arabic choice questions; question
/// 15 keeps two Roman subquestions inside its parent; question 3 has an
/// incomplete A/B option pair; question 23 has no answer block.
OcrDocument _build2019Equivalent() {
  final blocks = <OcrBlock>[
    _block('section_heading', 1, 0, '一、选择题'),
  ];
  var order = 1;
  for (var number = 1; number <= 23; number++) {
    final stemText = switch (number) {
      3 => '（3）Synthetic prompt marker 3.\nA. 选项甲\nB. 选项乙',
      15 => '（15）Synthetic prompt marker 15.',
      _ => '（$number）Synthetic prompt marker $number.\n'
          'A. 选项甲\nB. 选项乙\nC. 选项丙\nD. 选项丁',
    };
    blocks.add(_block('q_$number', 1, order++, stemText));
    if (number == 15) {
      blocks
        ..add(_block('q_15_roman_1', 1, order++, '（Ⅰ）Synthetic subpart one.'))
        ..add(
          _block('q_15_roman_2', 1, order++, '（Ⅱ）Synthetic subpart two.'),
        );
    }
    if (number != 23) {
      blocks.add(
        _block(
          'answer_$number',
          1,
          order++,
          number.isEven ? '答案：B' : '答案：A',
        ),
      );
    }
    blocks.add(
      _block(
        'explanation_$number',
        1,
        order++,
        '解析：Synthetic rationale marker $number.',
      ),
    );
  }
  return _document(
    'r3d1_synthetic_2019_equivalent',
    <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
  );
}

/// Forces document-coarse provenance through the real paths: two blocks share
/// one blockId so the adapter falls back to page-level refs and the bridge
/// cannot resolve a precise per-question source range.
OcrDocument _buildDuplicateBlockIdDocument() {
  return _document(
    'r3d1_duplicate_block_id',
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section_heading', 1, 0, '一、选择题'),
          _block('dup_q', 1, 1, '（1）Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：A'),
          _block('explanation_1', 1, 3, '解析：Synthetic rationale marker 1.'),
          _block('dup_q', 1, 4, '（2）Synthetic prompt marker 2.'),
          _block('answer_2', 1, 5, '答案：B'),
          _block('explanation_2', 1, 6, '解析：Synthetic rationale marker 2.'),
        ],
      ),
    ],
  );
}
