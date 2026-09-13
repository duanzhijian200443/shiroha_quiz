import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content_limits.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';
const _questionId = '22222222-2222-4222-8222-222222222222';
const _reviewId = '33333333-3333-4333-8333-333333333333';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ocr_typed_structural_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('typed candidate preserves image node and durable asset closure', () {
    const dataUrl = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final document = _document(<OcrBlock>[
      _block('section', 'text', '三、解答题', 0),
      _block('q_1', 'text', '1. Prompt before image', 1),
      _block('img_001', 'image', dataUrl, 2),
      _block('answer_1', 'text', '答案：synthetic-result-1', 3),
      _block('explanation_1', 'text', '解析：Synthetic explanation 1', 4),
    ]);
    final regionized = const OcrQuestionRegionizer().regionize(document);
    final store = ManagedContentAssetStore(managedRoot: temp);
    final legacyQuestions = <Map<String, dynamic>>[
      for (final region in regionized.regions)
        const OcrQuestionAssembler().assemble(region).question,
    ];
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: legacyQuestions,
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );

    expect(batch.failure, isNull);
    expect(batch.candidates, hasLength(1));
    final draft = batch.candidates.single.draft;
    expect(draft.stem.nodes.whereType<ImageNode>(), hasLength(1));
    expect(draft.stem.nodes.whereType<ImageNode>().single.sourceId, _sourceId);
    expect(
      draft.stem.nodes.whereType<ImageNode>().single.localAssetId,
      'img_001',
    );
    expect(draft.assetRefs, hasLength(1));
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );
  });

  test('typed candidate materializes a supported table node', () {
    final document = _document(<OcrBlock>[
      _block('section', 'text', '三、解答题', 0),
      _block(
        'q_1',
        'table',
        '<table><tr><td>1. Table prompt</td><td>x</td></tr></table>',
        1,
      ),
      _block('answer_1', 'text', '答案：synthetic-result-1', 2),
      _block('explanation_1', 'text', '解析：Synthetic explanation 1', 3),
    ]);
    final regionized = const OcrQuestionRegionizer().regionize(document);
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: [
        for (final region in regionized.regions)
          const OcrQuestionAssembler().assemble(region).question,
      ],
      uuidV4Factory: _uuidSequence(),
    );

    expect(batch.failure, isNull);
    expect(batch.candidates, hasLength(1));
    expect(batch.candidates.single.draft.stem.nodes, hasLength(1));
    expect(batch.candidates.single.draft.stem.nodes.single, isA<TableNode>());
  });

  test(
      'region bridge and assembler preserve mixed explanation ownership in order',
      () {
    const dataUrl = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final document = _document(<OcrBlock>[
      _block('section', 'text', '一、选择题（共 1 题）', 0),
      _block(
        'q_1',
        'text',
        '1. Synthetic prompt （A）one （B）two （C）three （D）four。'
            '解析：Synthetic explanation 1',
        1,
      ),
      _block('img_001', 'image', dataUrl, 2),
      _block(
        'table_001',
        'table',
        '<table>'
            '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
            '<tr><td>C</td></tr>'
            '</table>',
        3,
      ),
      _block('answer_1', 'text', '答案：A', 4),
    ]);
    final regionized = const OcrQuestionRegionizer().regionize(document);
    final store = ManagedContentAssetStore(managedRoot: temp);
    final legacyQuestions = <Map<String, dynamic>>[
      for (final region in regionized.regions)
        const OcrQuestionAssembler().assemble(region).question,
    ];
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: legacyQuestions,
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );

    expect(batch.failure, isNull);
    final explanation = batch.candidates.single.draft.explanation;
    expect(explanation, isNotNull);
    expect(
      explanation!.nodes.whereType<TextNode>().map((node) => node.text).join(),
      'Synthetic explanation 1\n\n',
    );
    expect(explanation.nodes.whereType<ImageNode>(), hasLength(1));
    expect(explanation.nodes.whereType<TableNode>(), hasLength(1));
    expect(
      explanation.nodes.where((node) => node is! TextNode).toList(),
      <Matcher>[isA<ImageNode>(), isA<TableNode>()],
    );
    final table = explanation.nodes.whereType<TableNode>().single;
    expect(table.structure.rows.first.cells.first.rowSpan, 2);
    expect(table.structure.rows.first.cells.first.columnSpan, 2);

    final finalQuestions = finalizeAndAuditImportQuestions(
      legacyQuestions,
      mode: ExplanationRetentionMode.allQuestionTypes,
    );
    final candidate = batch.candidates.single;
    final finalQuestion = finalQuestions.single;
    expect(candidate.projectedLegacy.type, finalQuestion['type'],
        reason: 'type');
    expect(candidate.projectedLegacy.content, finalQuestion['content'],
        reason: 'content');
    expect(candidate.projectedLegacy.options, finalQuestion['options'],
        reason: 'options');
    expect(
      candidate.projectedLegacy.standardAnswer,
      finalQuestion['standard_answer'],
      reason: 'answer',
    );
    expect(
      candidate.projectedLegacy.explanation,
      finalQuestion['explanation'],
      reason: 'explanation',
    );
    expect(candidate.sourcePageIndices, finalQuestion['source_page_indices'],
        reason: 'pages');
    expect(candidate.sourceBlockIds, finalQuestion['source_block_ids'],
        reason: 'blocks');
    final gate = applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: finalQuestions,
      singleFile: true,
      contentAssetAuthority: store,
    );
    expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
      gate.questions.single[TypedReviewSnapshotCodec.mapKey],
    );
    expect(snapshot.draft, batch.candidates.single.draft);
    expect(
        snapshot.draft.explanation!.nodes.whereType<ImageNode>(), hasLength(1));
    expect(
        snapshot.draft.explanation!.nodes.whereType<TableNode>(), hasLength(1));
    expect(snapshot.baselineLegacy.explanation,
        finalQuestions.single['explanation']);
  });

  test('assembler chunks long explanation text without scalar drift', () {
    final first = 'x' * 3000;
    final second = '😀' * 1200;
    final expected = '$first\n$second';
    final document = _document(<OcrBlock>[
      _block('section', 'text', '三、解答题', 0),
      _block('q_1', 'text', '1. Synthetic prompt marker 1.', 1),
      _block('answer_1', 'text', '答案：synthetic-result-1', 2),
      _block('explanation_1', 'text', '解析：$first', 3),
      _block('explanation_2', 'text', second, 4),
    ]);
    final regionized = const OcrQuestionRegionizer().regionize(document);
    final legacyQuestions = <Map<String, dynamic>>[
      for (final region in regionized.regions)
        const OcrQuestionAssembler().assemble(region).question,
    ];
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: legacyQuestions,
      uuidV4Factory: _uuidSequence(),
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );

    expect(batch.failure, isNull);
    final nodes = batch.candidates.single.draft.explanation!.nodes;
    expect(nodes, hasLength(2));
    expect(
      nodes.whereType<TextNode>().every(
            (node) =>
                node.text.runes.length <= RichContentLimits.maxNodeScalars,
          ),
      isTrue,
    );
    expect(
        nodes.whereType<TextNode>().map((node) => node.text).join(), expected);

    final finalQuestions = finalizeAndAuditImportQuestions(
      legacyQuestions,
      mode: ExplanationRetentionMode.allQuestionTypes,
    );
    final gate = applyOcrTypedCandidateGate(
      batch: batch,
      finalQuestions: finalQuestions,
      singleFile: true,
    );
    expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
      gate.questions.single[TypedReviewSnapshotCodec.mapKey],
    );
    final roundTrippedNodes = snapshot.draft.explanation!.nodes;
    expect(
      roundTrippedNodes.whereType<TextNode>().every(
            (node) =>
                node.text.runes.length <= RichContentLimits.maxNodeScalars,
          ),
      isTrue,
    );
    expect(
      roundTrippedNodes.whereType<TextNode>().map((node) => node.text).join(),
      expected,
    );
    expect(snapshot.baselineLegacy.explanation, expected);
  });
}

String Function() _uuidSequence() {
  final values = <String>[_sourceId, _questionId, _reviewId];
  var index = 0;
  return () => values[index++];
}

OcrDocument _document(List<OcrBlock> blocks) {
  return OcrDocument(
    sourceName: 'synthetic.pdf',
    pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrBlock _block(String id, String type, String text, int order) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: order,
  );
}
