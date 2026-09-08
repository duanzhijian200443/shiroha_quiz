import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_rich_content_parser.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';

OcrTypedCandidateGateResult buildMathFixture(
    {bool assets = false, List<String>? lines, bool singleBlock = false}) {
  final texts = lines ??
      [
        '一、选择题',
        r'1. 设 $x_n$ 满足条件，则（ ）',
        r'A. $x_n=1$',
        r'B. \(x_n=2\)',
        r'C. $x_n=3$',
        r'D. $x_n=4$',
        '答案：A',
        r'解析：由 $x_n=1$ 可得 $$x_n^2=1$$，以及 \[x_n^3=1\]。'
      ];
  final document = OcrDocument(
      sourceName: 'synthetic.pdf',
      pages: [
        OcrPage(pageIndex: 1, blocks: [
          for (var i = 0; i < (singleBlock ? 1 : texts.length); i++)
            OcrBlock(
                blockId: 'block_$i',
                pageIndex: 1,
                type: 'paragraph',
                text: singleBlock ? texts.join('\n') : texts[i],
                bbox: const [],
                readingOrder: i),
          if (assets) ...[
            for (var i = 0; i < 5; i++)
              OcrBlock(
                  blockId: 'image_$i',
                  pageIndex: 1,
                  type: 'image',
                  text: '[图片]',
                  bbox: const [],
                  readingOrder: 20 + i,
                  imagePayload: OcrImagePayload.fromDataUrl(_png)),
            for (var i = 0; i < 3; i++)
              OcrBlock(
                  blockId: 'table_$i',
                  pageIndex: 1,
                  type: 'table',
                  text: '<table><tr><td>cell $i</td></tr></table>',
                  bbox: const [],
                  readingOrder: 30 + i),
          ]
        ])
      ],
      markdown: '',
      rawResponses: const [],
      usage: const {});
  final regions = const OcrQuestionRegionizer().regionize(document).regions;
  final legacy = [
    for (final region in regions)
      const ImportQuestionFieldPolicy().applyToMap(
          const OcrQuestionAssembler().assemble(region).question,
          mode: ExplanationRetentionMode.allQuestionTypes)
  ];
  var id = 0;
  final store = _Assets();
  final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regions,
      legacyQuestions: legacy,
      assetStore: store,
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      uuidV4Factory: () =>
          '11111111-1111-4111-8111-${(++id).toString().padLeft(12, '0')}');
  expect(batch.failure, isNull);
  return applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: legacy,
      singleFile: true,
      contentAssetAuthority: store);
}

void main() {
  test('real regionizer same-block ownership reaches typed gate', () {
    final result = buildMathFixture(singleBlock: true);
    expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        result.questions.single[TypedReviewSnapshotCodec.mapKey]);
    expect(snapshot.draft.options, hasLength(4));
    expect(snapshot.draft.explanation!.nodes.whereType<BlockMathNode>(),
        hasLength(2));
  });
  test('content answer preserves production math payload and delimiters', () {
    final result = buildMathFixture(
        lines: ['三、填空题', r'1. 求 $x$ = ___', r'答案：\( x+1 \)', r'解析：由 $x$ 可知']);
    expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        result.questions.single[TypedReviewSnapshotCodec.mapKey]);
    final answer = snapshot.draft.answer as ContentAnswer;
    expect(answer.content.nodes, [const InlineMathNode(' x+1 ')]);
    expect(snapshot.baselineLegacy.standardAnswer, r'\( x+1 \)');
  });

  test('six OCR textual roles classify math before assembly', () {
    for (final type in [
      'text',
      'paragraph',
      'title',
      'heading',
      'formula',
      'equation'
    ]) {
      final source = const OcrSourceDocumentAdapter().convert(
          OcrDocument(
              sourceName: 'synthetic.pdf',
              pages: [
                OcrPage(pageIndex: 1, blocks: [
                  OcrBlock(
                      blockId: 'role',
                      pageIndex: 1,
                      type: type,
                      text: r'设 $ x $',
                      bbox: const [],
                      readingOrder: 0)
                ])
              ],
              markdown: '',
              rawResponses: const [],
              usage: const {}),
          sourceId: '11111111-1111-4111-8111-111111111111');
      expect((source.parts.single as SourceContentPart).content.nodes,
          [const TextNode('设 '), const InlineMathNode(' x ')]);
    }
  });
  test('assembler never extracts labels or options inside math', () {
    const raw = r'1. 设 $x A. y 答案：A 解析：z$ 条件';
    final map = OcrMathSourceMap();
    final region = _bridge(raw, map, [
      const OcrQuestionRegionSource(
          blockId: 'mixed', field: OcrRegionField.stem, text: raw)
    ]);
    final draft = const TypedQuestionAssembler().assemble(region,
        questionId: '22222222-2222-4222-8222-222222222222', mathSourceMap: map);
    expect(draft.options, isEmpty);
    expect(draft.answer, isNull);
    expect(draft.explanation, isNull);
    expect(draft.stem.nodes.whereType<InlineMathNode>().single.latex,
        'x A. y 答案：A 解析：z');
  });

  test('five images and three tables coexist with production math', () {
    final result = buildMathFixture(assets: true);
    expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        result.questions.single[TypedReviewSnapshotCodec.mapKey]);
    final nodes = snapshot.draft.explanation!.nodes;
    expect(nodes.whereType<InlineMathNode>(), hasLength(1));
    expect(nodes.whereType<BlockMathNode>(), hasLength(2));
    expect(nodes.whereType<ImageNode>().map((n) => n.localAssetId),
        [for (var i = 0; i < 5; i++) 'image_$i']);
    expect(nodes.whereType<ImageNode>().map((n) => n.sourceId).toSet(),
        {snapshot.draft.sourceRefs.first.sourceId});
    expect(nodes.whereType<TableNode>(), hasLength(3));
    expect(snapshot.draft.assetRefs, hasLength(5));
  });
  test('same-block UTF16 fields preserve math instances and choice semantics',
      () {
    const raw = '1. 😀 设 \$x\$\nA. \$ a \$\nB. \$b\$\nC. \$c\$\nD. \$d\$\n答案：A';
    final map = OcrMathSourceMap();
    final boundary = raw.indexOf('答案');
    final region = _bridge(raw, map, [
      OcrQuestionRegionSource(
          blockId: 'mixed',
          field: OcrRegionField.stem,
          text: raw.substring(0, boundary),
          startCodeUnitOffset: 0,
          endCodeUnitOffset: boundary),
      OcrQuestionRegionSource(
          blockId: 'mixed',
          field: OcrRegionField.answer,
          text: raw.substring(boundary),
          startCodeUnitOffset: boundary,
          endCodeUnitOffset: raw.length),
    ]);
    final original = (region.fragments.first.part as SourceContentPart).content;
    final draft = const TypedQuestionAssembler().assemble(region,
        questionId: '22222222-2222-4222-8222-222222222222', mathSourceMap: map);
    expect(draft.options.map((o) => o.optionId), ['A', 'B', 'C', 'D']);
    expect((draft.answer as ChoiceAnswer).optionIds, ['A']);
    final originalMath = original.nodes.whereType<InlineMathNode>().toList();
    expect(
        identical(draft.stem.nodes.whereType<InlineMathNode>().single,
            originalMath[0]),
        isTrue);
    expect(identical(draft.options.first.content.nodes.single, originalMath[1]),
        isTrue);
    expect((draft.options.first.content.nodes.single as InlineMathNode).latex,
        ' a ');
  });
  test('ownership ambiguity and math interior boundaries are unsupported', () {
    for (final owned in [
      const OcrQuestionRegionSource(
          blockId: 'mixed', field: OcrRegionField.stem, text: r'$x$'),
      const OcrQuestionRegionSource(
          blockId: 'mixed',
          field: OcrRegionField.stem,
          startCodeUnitOffset: 1,
          endCodeUnitOffset: 3),
    ]) {
      final region = _bridge(r'$x$ $x$', OcrMathSourceMap(), [owned]);
      expect(region.fragments.single.part, isA<UnsupportedSourcePart>());
    }
    final map = OcrMathSourceMap();
    final region = _bridge(r'😀 $x$ 后', map, [
      const OcrQuestionRegionSource(
          blockId: 'mixed', field: OcrRegionField.stem, text: r'$x$'),
    ]);
    expect(
        materializeQuestionRegionContent(
            (region.fragments.single.part as SourceContentPart).content,
            region.fragments.single.slice),
        [const InlineMathNode('x')]);
  });

  test('production math remains typed through strict gate and snapshot', () {
    final result = buildMathFixture();
    expect(result.route, ImportStorageRoute.typedV2, reason: result.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        result.questions.single[TypedReviewSnapshotCodec.mapKey]);
    expect(snapshot.draft.stem.nodes.whereType<InlineMathNode>(), hasLength(1));
    expect(snapshot.draft.options, hasLength(4));
    for (final option in snapshot.draft.options) {
      expect(option.content.nodes.whereType<InlineMathNode>(), hasLength(1));
    }
    expect(snapshot.draft.explanation!.nodes.whereType<InlineMathNode>(),
        hasLength(1));
    expect(snapshot.draft.explanation!.nodes.whereType<BlockMathNode>(),
        hasLength(2));
  });
}

QuestionRegion _bridge(
    String raw, OcrMathSourceMap map, List<OcrQuestionRegionSource> ownership) {
  final document = OcrDocument(
      sourceName: 'synthetic.pdf',
      pages: [
        OcrPage(pageIndex: 1, blocks: [
          OcrBlock(
              blockId: 'mixed',
              pageIndex: 1,
              type: 'text',
              text: raw,
              bbox: const [],
              readingOrder: 0)
        ])
      ],
      markdown: '',
      rawResponses: const [],
      usage: const {});
  final source = const OcrSourceDocumentAdapter().convert(document,
      sourceId: '11111111-1111-4111-8111-111111111111', mathSourceMap: map);
  return const OcrQuestionRegionBridge().convert(
      OcrQuestionRegion(
          number: 1,
          stemParts: [ownership.first.text ?? raw],
          answerParts: const [],
          explanationParts: const [],
          sourcePageIndices: const [1],
          sourceBlockIds: const ['mixed'],
          diagnostics: const [],
          ownedSources: ownership),
      sourceDocument: source,
      mathSourceMap: map);
}

const _png = 'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _Assets implements ContentAssetStore, ContentAssetAuthority {
  final stored = <(String, String)>{};
  @override
  ContentAssetWriteResult storeBytesSync(
      {required String sourceId,
      required String localAssetId,
      required List<int> bytes,
      required String mimeType}) {
    stored.add((sourceId, localAssetId));
    return ContentAssetWriteResult(
        storageKey: 'synthetic',
        sha256: '0' * 64,
        sizeBytes: bytes.length,
        mimeType: mimeType,
        created: true);
  }

  @override
  bool isDurableAssetReady(SourcedAssetRef asset) =>
      stored.contains((asset.sourceId, asset.asset.assetId));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
