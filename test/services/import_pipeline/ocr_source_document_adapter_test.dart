import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';

void main() {
  group('OcrSourceDocumentAdapter', () {
    test('preserves formal text, roles, provenance, and deterministic order',
        () {
      final pageTwoBlocks = <OcrBlock>[
        const OcrBlock(
          blockId: 'p002_heading',
          pageIndex: 2,
          type: ' Heading ',
          text: '第二页标题',
          bbox: <double>[],
          readingOrder: 0,
        ),
      ];
      final pageOneBlocks = <OcrBlock>[
        const OcrBlock(
          blockId: 'p001_formula',
          pageIndex: 1,
          type: 'equation',
          text: r'\[x^2 + y^2 = 1\]',
          bbox: <double>[],
          readingOrder: 2,
        ),
        const OcrBlock(
          blockId: 'p001_text',
          pageIndex: 1,
          type: ' TEXT ',
          text: '  合成正文\n保持换行与 Unicode：甲  ',
          bbox: <double>[],
          readingOrder: 0,
        ),
      ];
      final pages = <OcrPage>[
        OcrPage(pageIndex: 2, blocks: pageTwoBlocks),
        OcrPage(pageIndex: 1, blocks: pageOneBlocks),
      ];
      final document = OcrDocument(
        sourceName: r'C:\private\ignored.pdf',
        pages: pages,
        markdown: 'markdown must not be duplicated',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
      );

      final converted = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_001',
        displayLabel: 'synthetic.pdf',
      );

      expect(converted.documentRef.sourceId, 'source_001');
      expect(converted.documentRef.displayLabel, 'synthetic.pdf');
      expect(converted.parts.map(_formalText), <String?>[
        '  合成正文\n保持换行与 Unicode：甲  ',
        r'\[x^2 + y^2 = 1\]',
        '第二页标题',
      ]);
      expect(
        converted.parts.map((part) => (part as SourceContentPart).role),
        <SourceContentRole>[
          SourceContentRole.paragraph,
          SourceContentRole.formula,
          SourceContentRole.heading,
        ],
      );
      expect(
        converted.parts.map((part) => part.sourceRef.start!.pageNumber),
        <int>[1, 1, 2],
      );
      expect(
        converted.parts.map((part) => part.sourceRef.start!.blockId),
        <String?>['p001_text', 'p001_formula', 'p002_heading'],
      );
      expect(
        converted.parts.map((part) => part.sourceRef.start!.readingOrder),
        <int?>[0, 2, 0],
      );
      expect(converted.issues, isEmpty);
      expect(pages, <OcrPage>[pages[0], pages[1]]);
      expect(pageOneBlocks, <OcrBlock>[pageOneBlocks[0], pageOneBlocks[1]]);
    });

    test('uses encounter indices as a total-order tie breaker', () {
      final document = OcrDocument(
        sourceName: 'tie.pdf',
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
        pages: const <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'first_a',
                pageIndex: 1,
                type: 'text',
                text: 'first-a',
                bbox: <double>[],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'first_b',
                pageIndex: 1,
                type: 'text',
                text: 'first-b',
                bbox: <double>[],
                readingOrder: 0,
              ),
            ],
          ),
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'second_a',
                pageIndex: 1,
                type: 'text',
                text: 'second-a',
                bbox: <double>[],
                readingOrder: 0,
              ),
            ],
          ),
        ],
      );

      final converted = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_002',
      );

      expect(
        converted.parts.map(_formalText),
        <String?>['first-a', 'first-b', 'second-a'],
      );
      expect(converted.issues, isEmpty);
    });

    test('keeps malformed-location text with only safe fallback references',
        () {
      final document = OcrDocument(
        sourceName: 'invalid-locators.pdf',
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
        pages: const <OcrPage>[
          OcrPage(
            pageIndex: 0,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'zero_page',
                pageIndex: 0,
                type: 'text',
                text: 'zero-page-text',
                bbox: <double>[],
                readingOrder: 0,
              ),
            ],
          ),
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'negative_order',
                pageIndex: 1,
                type: 'text',
                text: 'negative-order-text',
                bbox: <double>[],
                readingOrder: -1,
              ),
              OcrBlock(
                blockId: '',
                pageIndex: 1,
                type: 'text',
                text: 'empty-id-text',
                bbox: <double>[],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'bad/id',
                pageIndex: 1,
                type: 'text',
                text: 'bad-id-text',
                bbox: <double>[],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'mismatch',
                pageIndex: 2,
                type: 'text',
                text: 'mismatch-text',
                bbox: <double>[],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'duplicate',
                pageIndex: 1,
                type: 'text',
                text: 'duplicate-first-text',
                bbox: <double>[],
                readingOrder: 3,
              ),
              OcrBlock(
                blockId: 'duplicate',
                pageIndex: 1,
                type: 'text',
                text: 'duplicate-second-text',
                bbox: <double>[],
                readingOrder: 4,
              ),
            ],
          ),
        ],
      );

      final converted = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_003',
      );

      expect(converted.parts, hasLength(7));
      expect(
        converted.parts.map(_formalText).toSet(),
        <String?>{
          'zero-page-text',
          'negative-order-text',
          'empty-id-text',
          'bad-id-text',
          'mismatch-text',
          'duplicate-first-text',
          'duplicate-second-text',
        },
      );
      expect(
          _partWithText(converted, 'zero-page-text').sourceRef.start, isNull);
      for (final text in <String>[
        'negative-order-text',
        'empty-id-text',
        'bad-id-text',
        'mismatch-text',
        'duplicate-first-text',
        'duplicate-second-text',
      ]) {
        final point = _partWithText(converted, text).sourceRef.start;
        expect(point, isNotNull);
        expect(point!.isBlock, isFalse);
        expect(point.pageNumber, 1);
      }
      expect(
        converted.issues.where((issue) => issue.code == 'ocr_location_invalid'),
        hasLength(4),
      );
      expect(
        converted.issues.where((issue) => issue.code == 'ocr_page_mismatch'),
        hasLength(1),
      );
      expect(
        converted.issues.where(
          (issue) => issue.code == 'ocr_block_identity_duplicate',
        ),
        hasLength(2),
      );
      expect(
        converted.issues.every(
          (issue) =>
              issue.field == ImportIssueField.source &&
              (issue.sourceRef?.start?.blockId == null),
        ),
        isTrue,
      );
      expect(
        _publicStrings(converted),
        isNot(contains(anyOf('', 'bad/id'))),
      );
    });

    test('uses a fixed type allowlist and explicit unsupported fallbacks', () {
      final labels = <String>[
        ' text ',
        'PARAGRAPH',
        'title',
        ' HEADING ',
        'formula',
        ' Equation ',
        'table',
        'IMAGE',
        'figure',
        'provider_widget',
        'te\u0000xt',
        List<String>.filled(65, 'x').join(),
        '',
      ];
      final blocks = <OcrBlock>[
        for (var index = 0; index < labels.length; index++)
          OcrBlock(
            blockId: 'block_$index',
            pageIndex: 1,
            type: labels[index],
            text: 'formal-text-$index',
            bbox: const <double>[],
            readingOrder: index,
          ),
      ];
      final converted = const OcrSourceDocumentAdapter().convert(
        OcrDocument(
          sourceName: 'types.pdf',
          pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
          markdown: '',
          rawResponses: const <Map<String, dynamic>>[],
          usage: const <String, dynamic>{},
        ),
        sourceId: 'source_004',
      );

      expect(
        converted.parts.take(6).map(
              (part) => (part as SourceContentPart).role,
            ),
        <SourceContentRole>[
          SourceContentRole.paragraph,
          SourceContentRole.paragraph,
          SourceContentRole.heading,
          SourceContentRole.heading,
          SourceContentRole.formula,
          SourceContentRole.formula,
        ],
      );
      expect(
        converted.parts.skip(6).map(
              (part) => (part as UnsupportedSourcePart).kindCode,
            ),
        <String>[
          'ocr_table',
          'ocr_image',
          'ocr_image',
          'ocr_unknown',
          'ocr_unknown',
          'ocr_unknown',
          'ocr_unknown',
        ],
      );
      expect(
        converted.parts.map(_formalText),
        <String?>[
          for (var index = 0; index < labels.length; index++)
            'formal-text-$index',
        ],
      );
      expect(
        converted.issues.where(
          (issue) => issue.code == 'ocr_structure_unsupported',
        ),
        hasLength(7),
      );
      expect(_allNodes(converted).whereType<RawFallbackNode>(), isEmpty);
    });

    test(
        'uses blocks before markdown and represents fallback states explicitly',
        () {
      final withBlock = const OcrSourceDocumentAdapter().convert(
        const OcrDocument(
          sourceName: 'blocks-win.pdf',
          pages: <OcrPage>[
            OcrPage(
              pageIndex: 1,
              blocks: <OcrBlock>[
                OcrBlock(
                  blockId: 'block',
                  pageIndex: 1,
                  type: 'text',
                  text: 'authoritative block',
                  bbox: <double>[],
                  readingOrder: 0,
                ),
              ],
            ),
          ],
          markdown: 'MARKDOWN_MUST_NOT_BE_DUPLICATED',
          rawResponses: <Map<String, dynamic>>[],
          usage: <String, dynamic>{},
        ),
        sourceId: 'source_005a',
      );
      const markdown = '  # Heading\nbody  ';
      final markdownOnly = const OcrSourceDocumentAdapter().convert(
        const OcrDocument(
          sourceName: 'markdown-only.pdf',
          pages: <OcrPage>[],
          markdown: markdown,
          rawResponses: <Map<String, dynamic>>[],
          usage: <String, dynamic>{},
        ),
        sourceId: 'source_005b',
      );
      final empty = const OcrSourceDocumentAdapter().convert(
        const OcrDocument(
          sourceName: 'empty.pdf',
          pages: <OcrPage>[
            OcrPage(
              pageIndex: 1,
              blocks: <OcrBlock>[
                OcrBlock(
                  blockId: 'blank',
                  pageIndex: 1,
                  type: 'text',
                  text: '  \n ',
                  bbox: <double>[],
                  readingOrder: 0,
                ),
              ],
            ),
          ],
          markdown: '\n  ',
          rawResponses: <Map<String, dynamic>>[],
          usage: <String, dynamic>{},
        ),
        sourceId: 'source_005c',
      );

      expect(
          withBlock.parts.map(_formalText), <String?>['authoritative block']);
      expect(
        _publicStrings(withBlock),
        isNot(contains('MARKDOWN_MUST_NOT_BE_DUPLICATED')),
      );
      expect(markdownOnly.parts, hasLength(1));
      expect(
        (markdownOnly.parts.single as UnsupportedSourcePart).kindCode,
        'ocr_markdown_fallback',
      );
      expect(_formalText(markdownOnly.parts.single), markdown);
      expect(
        markdownOnly.issues.single.code,
        'ocr_markdown_fallback',
      );
      expect(empty.parts, isEmpty);
      expect(empty.issues.single.code, 'ocr_content_empty');
      expect(empty.issues.single.severity, ImportIssueSeverity.error);
    });

    test(
        'drops every infrastructure side channel but preserves formal locators',
        () {
      const formalUrl = 'https://example.com';
      const formalPath = r'C:\course\example';
      const formalData = 'data:image/png;base64,example';
      const formalText = '$formalUrl\n$formalPath\n$formalData\napi_key 是什么';
      final raw = <String, dynamic>{
        'payload_blob': <String, dynamic>{
          'api_response': <String, dynamic>{
            'api_key': 'METADATA_ONLY_SECRET',
            'providerResponse': 'METADATA_ONLY_PROVIDER_BODY',
            'path': r'..\cache\file.png',
            'url': formalUrl,
            'diagnostics': 'METADATA_ONLY_DIAGNOSTICS',
            'base64': 'METADATA_ONLY_BASE64',
          },
        },
        'locators': <String>[
          'dir/file.png',
          r'..\cache\file.png',
          r'C:relative\file',
          r'\\server\share',
          'file://example',
          formalUrl,
          formalData,
          '  https://metadata.invalid',
        ],
      };
      final document = OcrDocument(
        sourceName: r'C:\private\source.pdf',
        pages: <OcrPage>[
          OcrPage(
            pageIndex: 1,
            width: 111,
            height: 222,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'formal',
                pageIndex: 1,
                type: 'text',
                text: formalText,
                bbox: const <double>[1, 2, 3, 4],
                readingOrder: 0,
                confidence: 0.123,
                width: 333,
                height: 444,
                raw: raw,
              ),
            ],
          ),
        ],
        markdown: '',
        rawResponses: <Map<String, dynamic>>[
          <String, dynamic>{
            'envelope': <String, dynamic>{
              'url': formalUrl,
              'providerResponse': 'RAW_RESPONSE_ONLY_BODY',
            },
          },
        ],
        usage: <String, dynamic>{
          'api_key': 'USAGE_ONLY_SECRET',
          'url': formalUrl,
        },
      );

      final converted = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_006',
      );
      final strings = _publicStrings(converted).toList(growable: false);

      expect(_formalText(converted.parts.single), formalText);
      expect(strings.where((value) => value.contains(formalUrl)), hasLength(1));
      expect(
          strings.where((value) => value.contains(formalPath)), hasLength(1));
      expect(
          strings.where((value) => value.contains(formalData)), hasLength(1));
      for (final forbidden in <String>[
        'METADATA_ONLY_SECRET',
        'METADATA_ONLY_PROVIDER_BODY',
        'METADATA_ONLY_DIAGNOSTICS',
        'METADATA_ONLY_BASE64',
        'RAW_RESPONSE_ONLY_BODY',
        'USAGE_ONLY_SECRET',
        r'..\cache\file.png',
        r'C:relative\file',
        r'\\server\share',
        'file://example',
        'https://metadata.invalid',
      ]) {
        expect(strings.any((value) => value.contains(forbidden)), isFalse);
      }
      expect(_allNodes(converted).whereType<RawFallbackNode>(), isEmpty);
    });

    test('keeps source identity caller-owned and degrades an unsafe label', () {
      const document = OcrDocument(
        sourceName: r'C:\private\same-name.pdf',
        pages: <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'block',
                pageIndex: 1,
                type: 'text',
                text: 'formal content',
                bbox: <double>[],
                readingOrder: 0,
              ),
            ],
          ),
        ],
        markdown: '',
        rawResponses: <Map<String, dynamic>>[],
        usage: <String, dynamic>{},
      );
      final first = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'caller_source_a',
      );
      final second = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'caller_source_b',
      );
      final unsafeLabel = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'caller_source_c',
        displayLabel: r'..\private.pdf',
      );

      expect(first.documentRef.sourceId, 'caller_source_a');
      expect(second.documentRef.sourceId, 'caller_source_b');
      expect(first.documentRef, isNot(second.documentRef));
      expect(first.documentRef.displayLabel, isNull);
      expect(unsafeLabel.documentRef.displayLabel, isNull);
      expect(_formalText(unsafeLabel.parts.single), 'formal content');
      expect(unsafeLabel.issues.single.code, 'ocr_display_label_invalid');
      expect(
        unsafeLabel.issues.single.severity,
        ImportIssueSeverity.info,
      );
      expect(
        () => const OcrSourceDocumentAdapter().convert(
          document,
          sourceId: 'unsafe/source',
        ),
        throwsFormatException,
      );
    });

    test('does not mutate DTO collections and returns an immutable value graph',
        () {
      final nestedRaw = <String, dynamic>{
        'nested': <String, dynamic>{'value': 'unchanged'},
      };
      final blocks = <OcrBlock>[
        OcrBlock(
          blockId: 'block',
          pageIndex: 1,
          type: 'text',
          text: 'repeatable',
          bbox: const <double>[],
          readingOrder: 0,
          raw: nestedRaw,
        ),
      ];
      final pages = <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)];
      final rawResponses = <Map<String, dynamic>>[
        <String, dynamic>{'value': 'unchanged'},
      ];
      final usage = <String, dynamic>{'count': 1};
      final document = OcrDocument(
        sourceName: 'immutable.pdf',
        pages: pages,
        markdown: '',
        rawResponses: rawResponses,
        usage: usage,
      );
      final adapter = const OcrSourceDocumentAdapter();

      final first = adapter.convert(document, sourceId: 'source_007');
      final second = adapter.convert(document, sourceId: 'source_007');

      expect(second, first);
      expect(identical(document.pages, pages), isTrue);
      expect(identical(document.pages.single.blocks, blocks), isTrue);
      expect(identical(document.pages.single.blocks.single.raw, nestedRaw),
          isTrue);
      expect(nestedRaw, <String, dynamic>{
        'nested': <String, dynamic>{'value': 'unchanged'},
      });
      expect(rawResponses, <Map<String, dynamic>>[
        <String, dynamic>{'value': 'unchanged'},
      ]);
      expect(usage, <String, dynamic>{'count': 1});
      expect(
        () => first.parts.add(first.parts.single),
        throwsUnsupportedError,
      );
      expect(
        () => first.issues.add(
          ImportIssue(
            code: 'later_issue',
            severity: ImportIssueSeverity.info,
          ),
        ),
        throwsUnsupportedError,
      );
      final content = (first.parts.single as SourceContentPart).content;
      expect(
        () => content.nodes.add(const TextNode('later')),
        throwsUnsupportedError,
      );
    });

    test('converts image block with data URL to SourceAssetPart', () {
      final imageBlock = OcrBlock(
        blockId: 'p001_img',
        pageIndex: 1,
        type: 'image',
        text:
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        bbox: const <double>[],
        readingOrder: 0,
      );
      final page = OcrPage(pageIndex: 1, blocks: <OcrBlock>[imageBlock]);
      final document = OcrDocument(
        sourceName: 'sample.pdf',
        pages: <OcrPage>[page],
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
      );

      final converted = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'src_img',
      );

      expect(converted.parts, hasLength(1));
      expect(converted.parts.single, isA<SourceAssetPart>());
      final assetPart = converted.parts.single as SourceAssetPart;
      expect(assetPart.asset.assetId, endsWith('.png'));
      expect(assetPart.asset.assetId, isNot(contains('/')));
      expect(assetPart.asset.kind, AssetKind.image);
      expect(converted.issues, isEmpty);
    });
  });
}

SourcePart _partWithText(SourceDocument document, String text) {
  return document.parts.singleWhere((part) => _formalText(part) == text);
}

String? _formalText(SourcePart part) {
  final content = switch (part) {
    SourceContentPart(:final content) => content,
    UnsupportedSourcePart(:final fallbackContent) => fallbackContent,
    SourceTablePart() || SourceAssetPart() => null,
  };
  if (content == null || content.nodes.length != 1) return null;
  final node = content.nodes.single;
  return node is TextNode ? node.text : null;
}

Iterable<ContentNode> _allNodes(SourceDocument document) sync* {
  for (final part in document.parts) {
    switch (part) {
      case SourceContentPart(:final content):
        yield* content.nodes;
      case SourceTablePart(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            yield* cell.nodes;
          }
        }
      case SourceAssetPart(:final alternativeText):
        if (alternativeText != null) yield* alternativeText.nodes;
      case UnsupportedSourcePart(:final fallbackContent):
        yield* fallbackContent.nodes;
    }
  }
}

Iterable<String> _publicStrings(SourceDocument document) sync* {
  yield* _sourceRefStrings(document.documentRef);
  for (final part in document.parts) {
    yield* _sourceRefStrings(part.sourceRef);
    switch (part) {
      case SourceContentPart(:final content, :final role):
        yield role.name;
        yield* _contentStrings(content);
      case SourceTablePart(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            yield* _contentStrings(cell);
          }
        }
      case SourceAssetPart(:final asset, :final alternativeText):
        yield asset.assetId;
        yield asset.kind.name;
        if (asset.mimeType != null) yield asset.mimeType!;
        if (alternativeText != null) yield* _contentStrings(alternativeText);
      case UnsupportedSourcePart(:final kindCode, :final fallbackContent):
        yield kindCode;
        yield* _contentStrings(fallbackContent);
    }
  }
  for (final issue in document.issues) {
    yield issue.code;
    yield issue.severity.name;
    if (issue.field != null) yield issue.field!.name;
    if (issue.sourceRef != null) yield* _sourceRefStrings(issue.sourceRef!);
  }
}

Iterable<String> _sourceRefStrings(SourceRef sourceRef) sync* {
  yield sourceRef.sourceId;
  if (sourceRef.displayLabel != null) yield sourceRef.displayLabel!;
  final start = sourceRef.start;
  final end = sourceRef.end;
  if (start?.blockId != null) yield start!.blockId!;
  if (end?.blockId != null && end!.blockId != start?.blockId) {
    yield end.blockId!;
  }
}

Iterable<String> _contentStrings(RichContent content) sync* {
  for (final node in content.nodes) {
    switch (node) {
      case TextNode(:final text):
        yield text;
      case InlineMathNode(:final latex):
        yield latex;
      case BlockMathNode(:final latex):
        yield latex;
      case ImageNode(:final altText):
        if (altText != null) yield altText;
      case RawFallbackNode(:final rawJson):
        yield* _jsonStrings(rawJson);
    }
  }
}

Iterable<String> _jsonStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String) yield entry.key as String;
      yield* _jsonStrings(entry.value);
    }
  } else if (value is Iterable) {
    for (final item in value) {
      yield* _jsonStrings(item);
    }
  }
}
