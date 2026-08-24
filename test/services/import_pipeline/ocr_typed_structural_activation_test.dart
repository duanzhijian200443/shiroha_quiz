import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
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
    final batch = buildOcrTypedCandidateBatch(
      document: document,
      regions: regionized.regions,
      legacyQuestions: [
        for (final region in regionized.regions)
          const OcrQuestionAssembler().assemble(region).question,
      ],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
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
