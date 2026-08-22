import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_limits.dart';
import 'package:shiroha_quiz/domain/content/rich_content_privacy_admission.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  const admission = RichContentPrivacyAdmission();

  group('RichContentPrivacyAdmission', () {
    test('rejects a direct unsafe raw fallback', () {
      final content = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'providerResponse': <Object?, Object?>{'status': 'synthetic'},
        }),
      ]);

      expect(() => admission.validate(content), throwsFormatException);
    });

    test('rejects deeply nested unsafe raw fallback', () {
      final keyContent = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'items': <Object?>[
              <Object?, Object?>{
                'nested': <Object?, Object?>{
                  'apiKey': true,
                },
              },
            ],
          },
        }),
      ]);
      final locatorContent = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'items': <Object?>[
              <Object?, Object?>{
                'ref': 'https://example.invalid/synthetic',
              },
            ],
          },
        }),
      ]);

      expect(() => admission.validate(keyContent), throwsFormatException);
      expect(() => admission.validate(locatorContent), throwsFormatException);
    });

    test('accepts a safe nested payload', () {
      final content = RichContent(nodes: <ContentNode>[
        const TextNode('synthetic'),
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'items': <Object?>[1, null, 'x'],
            'nested': <Object?, Object?>{
              'enabled': true,
              'kind': 'synthetic',
            },
          },
        }),
      ]);

      expect(() => admission.validate(content), returnsNormally);
    });

    test('ignores formal text with URL and path-like literals', () {
      final content = RichContent(nodes: const <ContentNode>[
        TextNode(r'C:\synthetic\path and https://example.invalid/reference'),
      ]);

      expect(() => admission.validate(content), returnsNormally);
    });

    test('ignores formal inline and block math with path-like literals', () {
      final content = RichContent(nodes: const <ContentNode>[
        InlineMathNode(r'\frac{a}{b} https://example.invalid/ref'),
        BlockMathNode(r'C:\synthetic\path'),
      ]);

      expect(() => admission.validate(content), returnsNormally);
    });

    test('admits a table cell image but rejects constrained image alt trees',
        () {
      final image = ImageNode(
        sourceId: 'source_001',
        localAssetId: 'asset_001',
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('safe alt'),
          BlockMathNode(r'x^2'),
        ]),
      );
      final table = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(content: RichContent(nodes: <ContentNode>[image])),
          ]),
        ]),
      );

      expect(
        () => admission.validate(RichContent(nodes: <ContentNode>[table])),
        returnsNormally,
      );

      final nestedImage = ImageNode(
        sourceId: 'source_002',
        localAssetId: 'asset_002',
      );
      final tableAlt = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(content: RichContent(nodes: const <ContentNode>[])),
          ]),
        ]),
      );
      final rawAlt = RawFallbackNode(<Object?, Object?>{
        'type': 'future_diagram',
        'payload': <Object?, Object?>{'kind': 'synthetic'},
      });

      expect(
        () => ImageNode(
          sourceId: 'source_003',
          localAssetId: 'asset_003',
          alternativeText: RichContent(nodes: <ContentNode>[nestedImage]),
        ),
        throwsFormatException,
      );
      expect(
        () => ImageNode(
          sourceId: 'source_003',
          localAssetId: 'asset_003',
          alternativeText: RichContent(nodes: <ContentNode>[tableAlt]),
        ),
        throwsFormatException,
      );
      expect(
        () => ImageNode(
          sourceId: 'source_003',
          localAssetId: 'asset_003',
          alternativeText: RichContent(nodes: <ContentNode>[rawAlt]),
        ),
        throwsFormatException,
      );
    });

    test('keeps image identities opaque and bounded', () {
      for (final invalid in <String>[
        '',
        'source id',
        'https://example.invalid/image',
        r'C:\fixtures\image.png',
        'a' * 129,
      ]) {
        expect(
          () => ImageNode(sourceId: invalid, localAssetId: 'asset_001'),
          throwsFormatException,
          reason: invalid,
        );
        expect(
          () => ImageNode(sourceId: 'source_001', localAssetId: invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
    });

    test('enforces content, image, and table resource boundaries', () {
      final atNodeLimit = RichContent(
        nodes: List<ContentNode>.generate(
          RichContentLimits.maxNodes,
          (_) => const TextNode('x'),
        ),
      );
      expect(() => admission.validate(atNodeLimit), returnsNormally);
      final overNodeLimit = RichContent(
        nodes: List<ContentNode>.generate(
          RichContentLimits.maxNodes + 1,
          (_) => const TextNode('x'),
        ),
      );
      expect(() => admission.validate(overNodeLimit), throwsFormatException);

      final atScalarLimit = RichContent(nodes: <ContentNode>[
        TextNode('x' * RichContentLimits.maxNodeScalars),
        TextNode('x' * RichContentLimits.maxNodeScalars),
      ]);
      expect(() => admission.validate(atScalarLimit), returnsNormally);
      final overScalarLimit = RichContent(nodes: <ContentNode>[
        TextNode('x' * RichContentLimits.maxNodeScalars),
        TextNode('x' * RichContentLimits.maxNodeScalars),
        const TextNode('x'),
      ]);
      expect(
        () => admission.validate(overScalarLimit),
        throwsFormatException,
      );

      final atImageLimit = RichContent(
        nodes: List<ContentNode>.generate(
          RichContentLimits.maxImages,
          (index) => ImageNode(
            sourceId: 'source_$index',
            localAssetId: 'asset_$index',
          ),
        ),
      );
      expect(() => admission.validate(atImageLimit), returnsNormally);
      final overImageLimit = RichContent(
        nodes: List<ContentNode>.generate(
          RichContentLimits.maxImages + 1,
          (index) => ImageNode(
            sourceId: 'source_$index',
            localAssetId: 'asset_$index',
          ),
        ),
      );
      expect(() => admission.validate(overImageLimit), throwsFormatException);

      final atTableRowLimit = TableNode(
        structure: TableStructure(
          rows: List<TableRow>.generate(
            RichContentLimits.maxTableRows,
            (_) => TableRow(cells: <TableCell>[
              TableCell(content: RichContent(nodes: const <ContentNode>[])),
            ]),
          ),
        ),
      );
      expect(
        () => admission.validate(
          RichContent(nodes: <ContentNode>[atTableRowLimit]),
        ),
        returnsNormally,
      );
      expect(
        () => TableStructure(
          rows: List<TableRow>.generate(
            RichContentLimits.maxTableRows + 1,
            (_) => TableRow(cells: <TableCell>[
              TableCell(content: RichContent(nodes: const <ContentNode>[])),
            ]),
          ),
        ),
        throwsFormatException,
      );
    });

    test('matches SourcePart rejection across every rich-content slot', () {
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
      final unsafeRaw = <Map<Object?, Object?>>[
        <Object?, Object?>{
          'type': 'future_diagram',
          'providerResponse': <Object?, Object?>{'status': 'synthetic'},
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'nested': <Object?, Object?>{
              'items': <Object?>[
                <Object?, Object?>{'apiKey': true},
              ],
            },
          },
        },
        <Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'path': 'fixtures/synthetic.bin',
          },
        },
      ];

      for (final rawJson in unsafeRaw) {
        final content = RichContent(
          nodes: <ContentNode>[RawFallbackNode(rawJson)],
        );
        expect(() => admission.validate(content), throwsFormatException);
        for (final build in builders) {
          expect(() => build(content), throwsFormatException);
        }
      }

      final safe = RichContent(nodes: <ContentNode>[
        const TextNode('synthetic'),
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{
            'nested': <Object?, Object?>{'kind': 'synthetic'},
          },
        }),
      ]);
      expect(() => admission.validate(safe), returnsNormally);
      for (final build in builders) {
        expect(() => build(safe), returnsNormally);
      }
    });

    test('preserves RawFallback deep-copy immutability', () {
      final items = <Object?>[1, true, null, 'x'];
      final original = <Object?, Object?>{
        'type': 'future_diagram',
        'payload': <Object?, Object?>{
          'items': items,
        },
      };

      final node = RawFallbackNode(original);
      original['type'] = 'changed';
      items
        ..[0] = 99
        ..add('later');

      expect(node.rawJson['type'], 'future_diagram');
      final payload = node.rawJson['payload']! as Map<String, Object?>;
      expect(payload['items'], <Object?>[1, true, null, 'x']);
      expect(
        () => node.rawJson['type'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => (payload['items']! as List<Object?>).add('later'),
        throwsUnsupportedError,
      );
      expect(
        () => admission.validate(
          RichContent(nodes: <ContentNode>[node]),
        ),
        returnsNormally,
      );
    });
  });
}
