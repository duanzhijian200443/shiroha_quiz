import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_codec.dart';

void main() {
  const codec = RichContentCodec();

  group('RichContentCodec round-trip', () {
    test('preserves known node types, content, and order', () {
      final content = RichContent(nodes: <ContentNode>[
        const TextNode('  第一行\n**Markdown 字符保持**  '),
        const InlineMathNode(r'\frac{1}{2}'),
        const TextNode(''),
        const BlockMathNode(r'\sum_{i=1}^{n}x_i'),
        const TextNode('duplicate'),
        const TextNode('duplicate'),
        RawFallbackNode(<Object?, Object?>{
          'type': 'raw_fallback',
          'payload': <Object?, Object?>{
            'kind': 'synthetic_table',
            'rows': <Object?>[
              <Object?>[1, true, null, 'x'],
            ],
          },
        }),
      ]);

      final firstEncoding = codec.encode(content);
      final decoded = codec.decode(firstEncoding);
      final secondEncoding = codec.encode(decoded);

      expect(firstEncoding['schemaVersion'], 1);
      expect(decoded.nodes, hasLength(7));
      expect(decoded.nodes[0], isA<TextNode>());
      expect(decoded.nodes[1], isA<InlineMathNode>());
      expect(decoded.nodes[2], isA<TextNode>());
      expect(decoded.nodes[3], isA<BlockMathNode>());
      expect(decoded.nodes[6], isA<RawFallbackNode>());
      expect(
        (decoded.nodes[0] as TextNode).text,
        '  第一行\n**Markdown 字符保持**  ',
      );
      expect((decoded.nodes[1] as InlineMathNode).latex, r'\frac{1}{2}');
      expect((decoded.nodes[2] as TextNode).text, isEmpty);
      expect(
        (decoded.nodes[3] as BlockMathNode).latex,
        r'\sum_{i=1}^{n}x_i',
      );
      expect(secondEncoding, equals(firstEncoding));
    });

    test('allows an empty node list', () {
      final decoded = codec.decode(<String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[],
      });

      expect(decoded.nodes, isEmpty);
      expect(
        codec.encode(decoded),
        <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[],
        },
      );
    });

    test('round-trips images, alternative text, tables, and spans', () {
      final table = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: const <ContentNode>[TextNode('a')]),
              columnSpan: 2,
            ),
          ]),
          TableRow(cells: <TableCell>[
            TableCell(content: RichContent(nodes: const <ContentNode>[])),
            TableCell(
              content: RichContent(
                nodes: const <ContentNode>[BlockMathNode(r'b')],
              ),
            ),
          ]),
        ]),
      );
      final content = RichContent(nodes: <ContentNode>[
        ImageNode(sourceId: 'source_001', localAssetId: 'asset_null'),
        ImageNode(
          sourceId: 'source_001',
          localAssetId: 'asset_text',
          alternativeText: RichContent(nodes: const <ContentNode>[
            TextNode('alt'),
          ]),
        ),
        ImageNode(
          sourceId: 'source_001',
          localAssetId: 'asset_inline',
          alternativeText: RichContent(nodes: const <ContentNode>[
            InlineMathNode(r'x+1'),
          ]),
        ),
        ImageNode(
          sourceId: 'source_001',
          localAssetId: 'asset_block',
          alternativeText: RichContent(nodes: const <ContentNode>[
            BlockMathNode(r'\sum x'),
          ]),
        ),
        table,
      ]);

      final firstEncoding = codec.encode(content);
      final decoded = codec.decode(firstEncoding);

      expect(decoded, content);
      expect(codec.encode(decoded), equals(firstEncoding));
      final encodedNodes = firstEncoding['nodes']! as List<Object?>;
      expect(
        (encodedNodes.first as Map<String, Object?>)['alternativeText'],
        isNull,
      );
      expect(
        (encodedNodes.last as Map<String, Object?>)['rows'],
        isA<List<Object?>>(),
      );
    });
  });

  group('RichContentCodec fallback preservation', () {
    test('rejects fallback shapes that cannot preserve their node type', () {
      final invalidFallbacks = <Map<Object?, Object?>>[
        <Object?, Object?>{'type': 'text'},
        <Object?, Object?>{'type': 'text', 'text': 'synthetic'},
        <Object?, Object?>{'type': 'inline_math'},
        <Object?, Object?>{
          'type': 'inline_math',
          'latex': r'\alpha',
        },
        <Object?, Object?>{'type': 'block_math'},
        <Object?, Object?>{
          'type': 'block_math',
          'latex': r'\sum_i x_i',
        },
        <Object?, Object?>{'type': 'raw_fallback'},
      ];

      for (final rawJson in invalidFallbacks) {
        expect(
          () => RawFallbackNode(rawJson),
          throwsFormatException,
          reason:
              'Fallback construction must be closed under codec round-trip.',
        );
      }
    });

    test(
        'directly constructed valid fallbacks remain fallbacks after round-trip',
        () {
      final content = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'text',
          'text': 'synthetic',
          'futureStyle': true,
        }),
        RawFallbackNode(<Object?, Object?>{
          'type': 'raw_fallback',
          'payload': <Object?, Object?>{'kind': 'synthetic'},
        }),
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'payload': <Object?, Object?>{'id': 1},
        }),
      ]);

      final firstEncoding = codec.encode(content);
      final decoded = codec.decode(firstEncoding);

      expect(decoded.nodes, everyElement(isA<RawFallbackNode>()));
      expect(codec.encode(decoded), equals(firstEncoding));
    });

    test('round-trips an unknown node without wrapping or field loss', () {
      final originalItems = <Object?>[1, true, null, 'x'];
      final unknownNode = <String, Object?>{
        'type': 'future_diagram',
        'id': 'diagram-1',
        'nested': <String, Object?>{'items': originalItems},
        'extra': <Object?>['a', 'b'],
      };
      final input = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[unknownNode],
      };

      final decoded = codec.decode(input);
      originalItems[0] = 99;
      unknownNode['extra'] = <Object?>['changed'];

      expect(decoded.nodes.single, isA<RawFallbackNode>());
      expect(
        codec.encode(decoded),
        <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'future_diagram',
              'id': 'diagram-1',
              'nested': <String, Object?>{
                'items': <Object?>[1, true, null, 'x'],
              },
              'extra': <Object?>['a', 'b'],
            },
          ],
        },
      );
    });

    test('preserves extra fields on a known type as raw fallback', () {
      final input = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'type': 'text',
            'text': 'synthetic',
            'futureStyle': <String, Object?>{'weight': 600},
          },
        ],
      };

      final decoded = codec.decode(input);

      expect(decoded.nodes.single, isA<RawFallbackNode>());
      expect(codec.encode(decoded), equals(input));
    });

    test('keeps an extended image as lossless raw fallback', () {
      final input = <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[
          <String, Object?>{
            'type': 'image',
            'sourceId': 'source_001',
            'assetId': 'asset_001',
            'alternativeText': null,
            'futureCrop': <String, Object?>{'left': 1},
          },
        ],
      };

      final decoded = codec.decode(input);

      expect(decoded.nodes.single, isA<RawFallbackNode>());
      expect(codec.encode(decoded), equals(input));
    });

    test('returns a fresh mutable deep copy from encode', () {
      final content = RichContent(nodes: <ContentNode>[
        RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'nested': <Object?, Object?>{
            'items': <Object?>[1, 2],
          },
        }),
      ]);

      final encoded = codec.encode(content);
      final encodedNodes = encoded['nodes']! as List<Object?>;
      final encodedNode = encodedNodes.single as Map<String, Object?>;
      final nested = encodedNode['nested']! as Map<String, Object?>;
      final items = nested['items']! as List<Object?>;
      items[0] = 99;
      nested['added'] = true;
      encodedNodes.clear();

      expect(
        codec.encode(content),
        <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'future_diagram',
              'nested': <String, Object?>{
                'items': <Object?>[1, 2],
              },
            },
          ],
        },
      );
    });
  });

  group('RichContentCodec invalid input', () {
    test('rejects malformed roots and nodes without returning empty content',
        () {
      final invalidCases = <String, Object?>{
        'root is not a map': <Object?>[],
        'schemaVersion is missing': <String, Object?>{
          'nodes': <Object?>[],
        },
        'schemaVersion is bool': <String, Object?>{
          'schemaVersion': true,
          'nodes': <Object?>[],
        },
        'schemaVersion is double': <String, Object?>{
          'schemaVersion': 1.0,
          'nodes': <Object?>[],
        },
        'nodes is missing': <String, Object?>{'schemaVersion': 1},
        'nodes is not a list': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <String, Object?>{},
        },
        'root has an extra field': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[],
          'extra': true,
        },
        'node is null': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[null],
        },
        'node is not a map': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>['text'],
        },
        'type is missing': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'text': 'synthetic'},
          ],
        },
        'type is not a string': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 1},
          ],
        },
        'type is blank': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': '  '},
          ],
        },
        'text is missing': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'text'},
          ],
        },
        'text has the wrong type': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'text', 'text': 1},
          ],
        },
        'inline math is missing latex': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'inline_math'},
          ],
        },
        'block math has the wrong type': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'block_math', 'latex': false},
          ],
        },
        'image is missing alternativeText': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'image',
              'sourceId': 'source_001',
              'assetId': 'asset_001',
            },
          ],
        },
        'image has malformed source identity': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'image',
              'sourceId': 'https://example.invalid/source',
              'assetId': 'asset_001',
              'alternativeText': null,
            },
          ],
        },
        'image has malformed alternativeText': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'image',
              'sourceId': 'source_001',
              'assetId': 'asset_001',
              'alternativeText': <String, Object?>{
                'schemaVersion': 1,
                'nodes': <Object?>[
                  <String, Object?>{
                    'type': 'image',
                    'sourceId': 'source_002',
                    'assetId': 'asset_002',
                    'alternativeText': null,
                  },
                ],
              },
            },
          ],
        },
        'raw fallback is missing payload': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'raw_fallback'},
          ],
        },
        'raw fallback contains a runtime object': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{
              'type': 'raw_fallback',
              'payload': Object(),
            },
          ],
        },
        'node has a non-string key': <String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <Object?, Object?>{'type': 'future_diagram', 1: 'invalid'},
          ],
        },
      };

      for (final entry in invalidCases.entries) {
        expect(
          () => codec.decode(entry.value),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('distinguishes an unsupported root schema version', () {
      expect(
        () => codec.decode(<String, Object?>{
          'schemaVersion': 2,
          'nodes': <Object?>[],
        }),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('fails the entire decode when one node is malformed', () {
      expect(
        () => codec.decode(<String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'valid'},
            <String, Object?>{'type': 'inline_math'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('rejects cyclic unknown-node data', () {
      final cyclic = <Object?, Object?>{'type': 'future_diagram'};
      cyclic['nested'] = cyclic;

      expect(
        () => codec.decode(<String, Object?>{
          'schemaVersion': 1,
          'nodes': <Object?>[cyclic],
        }),
        throwsFormatException,
      );
    });
  });
}
