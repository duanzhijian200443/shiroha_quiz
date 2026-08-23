import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ocr_content_admission_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('admits provider image bytes as a source-qualified asset part', () {
    const dataUrl = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final document = _document(<OcrBlock>[
      _block('img_001', 'image', dataUrl),
    ]);
    final store = ManagedContentAssetStore(managedRoot: temp);

    final withoutStore = const OcrSourceDocumentAdapter().convert(
      document,
      sourceId: 'source_a',
      displayLabel: null,
    );
    expect(withoutStore.parts.single, isA<UnsupportedSourcePart>());
    final fallback =
        (withoutStore.parts.single as UnsupportedSourcePart).fallbackContent;
    expect(
      const RichContentTextProjection().project(fallback),
      isNot(contains(dataUrl)),
    );

    final withStore = OcrSourceDocumentAdapter(assetStore: store).convert(
      document,
      sourceId: 'source_a',
    );
    final part = withStore.parts.single;
    expect(part, isA<SourceAssetPart>());
    expect((part as SourceAssetPart).asset.assetId, 'img_001');
    expect(
      store.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      isNotNull,
    );
    expect(withStore.parts.whereType<UnsupportedSourcePart>(), isEmpty);
  });

  test('rejects image bytes whose signature disagrees with declared MIME', () {
    const mismatchedDataUrl = 'data:image/png;base64,/9j/4AAQSkZJRg==';
    expect(OcrImagePayload.fromDataUrl(mismatchedDataUrl), isNull);

    final converted = OcrSourceDocumentAdapter(
      assetStore: ManagedContentAssetStore(managedRoot: temp),
    ).convert(
      _document(<OcrBlock>[
        _block('image_bad_signature', 'image', mismatchedDataUrl),
      ]),
      sourceId: 'source_a',
    );
    expect(converted.parts.single, isA<UnsupportedSourcePart>());
    expect(
      (converted.parts.single as UnsupportedSourcePart).kindCode,
      'ocr_image',
    );
  });

  test('projects a supported provider table into SourceTablePart', () {
    final document = _document(<OcrBlock>[
      _block(
        'table_001',
        'table',
        '<table><tr><th>A</th><th>B</th></tr>'
            '<tr><td>1</td><td>2</td></tr></table>',
      ),
    ]);

    final converted = const OcrSourceDocumentAdapter().convert(
      document,
      sourceId: 'source_a',
    );
    final table = converted.parts.single;
    expect(table, isA<SourceTablePart>());
    expect((table as SourceTablePart).rows, hasLength(2));
    expect(table.rows.first, hasLength(2));
    expect(converted.parts.whereType<UnsupportedSourcePart>(), isEmpty);
  });

  test('unsupported provider locators never enter fallback text', () {
    final values = <String>[
      'file:///private/crop.png',
      r'C:\private\crop.png',
      'custom+provider://crop/001',
      'data:image/png;base64,AAAA',
      'prefix https://provider.invalid/crop',
      r'provider crop at C:\private\crop.png',
      'iVBORw0KGgo=',
    ];

    for (final value in values) {
      final converted = const OcrSourceDocumentAdapter().convert(
        _document(<OcrBlock>[_block('unsupported', 'provider_blob', value)]),
        sourceId: 'source_a',
      );
      final part = converted.parts.single as UnsupportedSourcePart;
      expect(
        const RichContentTextProjection().project(part.fallbackContent),
        '[不支持的内容]',
      );
    }
  });

  test('does not classify ordinary long text as an image payload', () {
    const ordinary = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final converted = const OcrSourceDocumentAdapter().convert(
      _document(<OcrBlock>[_block('ordinary', 'provider_blob', ordinary)]),
      sourceId: 'source_a',
    );
    final part = converted.parts.single as UnsupportedSourcePart;
    expect(
      const RichContentTextProjection().project(part.fallbackContent),
      ordinary,
    );
  });

  test('markdown fallback also redacts provider locators', () {
    final document = OcrDocument(
      sourceName: 'synthetic.pdf',
      pages: const <OcrPage>[],
      markdown: '![crop](data:image/png;base64,AAAA)',
      rawResponses: const <Map<String, dynamic>>[],
      usage: const <String, dynamic>{},
    );
    final converted = const OcrSourceDocumentAdapter().convert(
      document,
      sourceId: 'source_a',
    );
    final part = converted.parts.single as UnsupportedSourcePart;
    expect(
      const RichContentTextProjection().project(part.fallbackContent),
      '[不支持的内容]',
    );
  });

  test('table provider image markup fails closed', () {
    final converted = const OcrSourceDocumentAdapter().convert(
      _document(<OcrBlock>[
        _block(
          'table_001',
          'table',
          '<table><tr><td><img src="https://provider.invalid/crop" />'
              '</td></tr></table>',
        ),
      ]),
      sourceId: 'source_a',
    );

    expect(converted.parts.single, isA<UnsupportedSourcePart>());
    expect(
      (converted.parts.single as UnsupportedSourcePart).kindCode,
      'ocr_table',
    );
    expect(converted.parts.single, isNot(isA<SourceTablePart>()));
  });
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

OcrBlock _block(String id, String type, String text) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: 0,
  );
}
