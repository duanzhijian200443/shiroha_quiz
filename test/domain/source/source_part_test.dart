import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('SourceContentPart', () {
    test('preserves rich content, provenance, and conservative roles', () {
      final documentRef = SourceRef.document(sourceId: 'source_001');
      final pageRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.page(pageNumber: 2),
      );
      final blockRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_001',
          readingOrder: 3,
        ),
      );
      final rangeRef = SourceRef.range(
        sourceId: 'source_001',
        start: SourcePoint.block(
          pageNumber: 2,
          blockId: 'block_001',
          readingOrder: 3,
        ),
        end: SourcePoint.block(
          pageNumber: 3,
          blockId: 'block_002',
          readingOrder: 0,
        ),
      );
      final content = RichContent(nodes: <ContentNode>[
        const TextNode('合成文本\n保持换行'),
        const InlineMathNode(r'\alpha+1'),
        const BlockMathNode(r'\sum_i x_i'),
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{'kind': 'synthetic'},
        }),
      ]);

      final parts = <SourceContentPart>[
        SourceContentPart(sourceRef: documentRef, content: content),
        SourceContentPart(
          sourceRef: pageRef,
          content: content,
          role: SourceContentRole.paragraph,
        ),
        SourceContentPart(
          sourceRef: blockRef,
          content: content,
          role: SourceContentRole.heading,
        ),
        SourceContentPart(
          sourceRef: rangeRef,
          content: content,
          role: SourceContentRole.formula,
        ),
        SourceContentPart(
          sourceRef: documentRef,
          content: content,
          role: SourceContentRole.answerLike,
        ),
      ];

      expect(parts.first.role, SourceContentRole.unknown);
      expect(parts.map((part) => part.sourceRef), <SourceRef>[
        documentRef,
        pageRef,
        blockRef,
        rangeRef,
        documentRef,
      ]);
      expect(parts.first.content.nodes, hasLength(4));
      expect((parts.first.content.nodes[0] as TextNode).text, '合成文本\n保持换行');
      expect(
          (parts.first.content.nodes[1] as InlineMathNode).latex, r'\alpha+1');
      expect(parts.first.content.nodes[3], isA<RawFallbackNode>());
    });

    test('allows empty formal content', () {
      final part = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        content: RichContent(nodes: const <ContentNode>[]),
      );

      expect(part.content.nodes, isEmpty);
      expect(part.role, SourceContentRole.unknown);
    });

    test('uses deep RichContent value equality and stable hashes', () {
      final sourceRef = SourceRef.document(sourceId: 'source_001');
      final first = SourceContentPart(
        sourceRef: sourceRef,
        content: _futureContent(reverseKeys: false),
      );
      final equal = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        content: _futureContent(reverseKeys: true),
      );
      final differentRole = SourceContentPart(
        sourceRef: sourceRef,
        content: _futureContent(reverseKeys: true),
        role: SourceContentRole.heading,
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<SourcePart>{first}, contains(equal));
      expect(differentRole, isNot(first));
    });
  });

  group('SourceTablePart', () {
    test('preserves empty, ragged, and ordered rich-content cells', () {
      final firstRow = <RichContent>[_text('r1c1'), _text('')];
      final secondRow = <RichContent>[_text('r2c1')];
      final inputRows = <List<RichContent>>[firstRow, secondRow];
      final part = SourceTablePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        rows: inputRows,
      );
      final originalHash = part.hashCode;

      firstRow.clear();
      secondRow.add(_text('changed'));
      inputRows.clear();

      expect(part.rows, hasLength(2));
      expect(part.rows[0], hasLength(2));
      expect(part.rows[1], hasLength(1));
      expect((part.rows[0][0].nodes.single as TextNode).text, 'r1c1');
      expect((part.rows[0][1].nodes.single as TextNode).text, isEmpty);
      expect((part.rows[1][0].nodes.single as TextNode).text, 'r2c1');
      expect(part.hashCode, originalHash);
      expect(() => part.rows.clear(), throwsUnsupportedError);
      expect(() => part.rows.first.clear(), throwsUnsupportedError);

      final empty = SourceTablePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        rows: const <List<RichContent>>[],
      );
      final emptyRow = SourceTablePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        rows: const <List<RichContent>>[<RichContent>[]],
      );
      expect(empty.rows, isEmpty);
      expect(emptyRow.rows.single, isEmpty);
    });

    test('compares cells and row order by value without flattening', () {
      final sourceRef = SourceRef.document(sourceId: 'source_001');
      final first = SourceTablePart(
        sourceRef: sourceRef,
        rows: <List<RichContent>>[
          <RichContent>[_text('a'), _futureContent(reverseKeys: false)],
          <RichContent>[_text('b')],
        ],
      );
      final equal = SourceTablePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        rows: <List<RichContent>>[
          <RichContent>[_text('a'), _futureContent(reverseKeys: true)],
          <RichContent>[_text('b')],
        ],
      );
      final reordered = SourceTablePart(
        sourceRef: sourceRef,
        rows: <List<RichContent>>[
          <RichContent>[_text('b')],
          <RichContent>[_text('a'), _futureContent(reverseKeys: true)],
        ],
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(reordered, isNot(first));
      expect(first.rows.first.first, isA<RichContent>());
    });
  });

  group('SourceAssetPart', () {
    test('embeds only a safe asset reference and optional formal alt content',
        () {
      final sourceRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.page(pageNumber: 1),
      );
      final asset = AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 16,
        pixelHeight: 9,
      );
      final withoutAlt = SourceAssetPart(sourceRef: sourceRef, asset: asset);
      final withAlt = SourceAssetPart(
        sourceRef: sourceRef,
        asset: asset,
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('合成替代文本'),
          InlineMathNode(r'x+1'),
        ]),
      );
      final equal = SourceAssetPart(
        sourceRef: SourceRef.at(
          sourceId: 'source_001',
          point: SourcePoint.page(pageNumber: 1),
        ),
        asset: AssetRef(
          assetId: 'asset_001',
          kind: AssetKind.image,
          mimeType: 'image/png',
          pixelWidth: 16,
          pixelHeight: 9,
        ),
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('合成替代文本'),
          InlineMathNode(r'x+1'),
        ]),
      );

      expect(withoutAlt.alternativeText, isNull);
      expect(withAlt.alternativeText!.nodes, hasLength(2));
      expect(equal, withAlt);
      expect(equal.hashCode, withAlt.hashCode);
    });
  });

  group('UnsupportedSourcePart', () {
    test('preserves a stable kind and non-empty formal fallback', () {
      final part = UnsupportedSourcePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        kindCode: 'future_layout',
        fallbackContent: _futureContent(reverseKeys: false),
      );
      final equal = UnsupportedSourcePart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        kindCode: 'future_layout',
        fallbackContent: _futureContent(reverseKeys: true),
      );

      expect(part.kindCode, 'future_layout');
      expect(part.fallbackContent.nodes, isNotEmpty);
      expect(equal, part);
      expect(equal.hashCode, part.hashCode);
    });

    test('rejects unsafe kind codes and an empty fallback', () {
      final sourceRef = SourceRef.document(sourceId: 'source_001');
      for (final kindCode in <String>[
        '',
        'FutureLayout',
        'future-layout',
        'future layout',
        'a' * 65,
      ]) {
        expect(
          () => UnsupportedSourcePart(
            sourceRef: sourceRef,
            kindCode: kindCode,
            fallbackContent: _text('synthetic'),
          ),
          throwsFormatException,
        );
      }

      expect(
        () => UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'future_layout',
          fallbackContent: RichContent(nodes: const <ContentNode>[]),
        ),
        throwsFormatException,
      );
    });
  });

  group('SourcePart privacy admission', () {
    test('rejects unsafe raw fallback metadata in every content slot', () {
      final sourceRef = SourceRef.document(sourceId: 'source_001');
      final asset = AssetRef(assetId: 'asset_001', kind: AssetKind.image);
      final builders = <SourcePart Function(RichContent)>[
        (content) => SourceContentPart(
              sourceRef: sourceRef,
              content: content,
            ),
        (content) => SourceTablePart(
              sourceRef: sourceRef,
              rows: <List<RichContent>>[
                <RichContent>[content],
              ],
            ),
        (content) => SourceAssetPart(
              sourceRef: sourceRef,
              asset: asset,
              alternativeText: content,
            ),
        (content) => UnsupportedSourcePart(
              sourceRef: sourceRef,
              kindCode: 'future_layout',
              fallbackContent: content,
            ),
      ];
      final unsafeRawNodes = <Map<Object?, Object?>>[
        <Object?, Object?>{
          'type': 'future_diagram',
          'providerResponse': <Object?, Object?>{'status': 'synthetic'},
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'nested': <Object?, Object?>{'api_key': true},
          },
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{'path': 'fixtures/synthetic.bin'},
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'diagnostics': <Object?, Object?>{'count': 1},
          },
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'href': 'https://example.invalid/synthetic',
          },
        },
      ];

      for (final rawJson in unsafeRawNodes) {
        final content = RichContent(
          nodes: <ContentNode>[RawFallbackNode(rawJson)],
        );
        for (final build in builders) {
          expect(() => build(content), throwsFormatException);
        }
      }
    });

    test('freezes exact messages for forbidden keys and locators', () {
      final sourceRef = SourceRef.document(sourceId: 'source_001');
      final forbiddenKey = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{'path': 'fixtures/synthetic.bin'},
        }),
      ]);
      final forbiddenLocator = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'href': 'https://example.invalid/synthetic',
          },
        }),
      ]);

      expect(
        () => SourceContentPart(sourceRef: sourceRef, content: forbiddenKey),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Source fallback content contains prohibited side-channel metadata.',
          ),
        ),
      );
      expect(
        () =>
            SourceContentPart(sourceRef: sourceRef, content: forbiddenLocator),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Source fallback content contains a prohibited locator value.',
          ),
        ),
      );
    });

    test('does not treat formal text content as side-channel metadata', () {
      final part = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        content: RichContent(nodes: const <ContentNode>[
          TextNode('Synthetic source text: https://example.invalid/reference'),
        ]),
      );

      expect(
          (part.content.nodes.single as TextNode).text, contains('https://'));
    });

    test('does not treat formal math literals as side-channel metadata', () {
      final part = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_001'),
        content: RichContent(nodes: const <ContentNode>[
          InlineMathNode(r'\frac{a}{b} https://example.invalid/ref'),
          BlockMathNode(r'C:\synthetic\path'),
        ]),
      );

      expect(
        (part.content.nodes[0] as InlineMathNode).latex,
        r'\frac{a}{b} https://example.invalid/ref',
      );
      expect(
        (part.content.nodes[1] as BlockMathNode).latex,
        r'C:\synthetic\path',
      );
    });
  });
}

RichContent _text(String value) {
  return RichContent(nodes: <ContentNode>[TextNode(value)]);
}

RichContent _futureContent({required bool reverseKeys}) {
  final payload = reverseKeys
      ? <Object?, Object?>{
          'enabled': true,
          'items': <Object?>[1, null, 'x'],
        }
      : <Object?, Object?>{
          'items': <Object?>[1, null, 'x'],
          'enabled': true,
        };
  return RichContent(nodes: <ContentNode>[
    const TextNode('synthetic'),
    RawFallbackNode(<Object?, Object?>{
      'type': 'future_diagram',
      'payload': payload,
    }),
  ]);
}
