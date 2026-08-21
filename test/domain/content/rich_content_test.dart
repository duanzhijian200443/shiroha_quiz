import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';

void main() {
  group('RichContent', () {
    test('preserves order, duplicates, empty text, and adjacent text nodes',
        () {
      const first = TextNode('');
      const second = TextNode('  合成文本\n**保持原样**  ');
      const repeated = TextNode('duplicate');
      final source = <ContentNode>[
        first,
        second,
        repeated,
        repeated,
        const InlineMathNode(r'\frac{1}{2}'),
        const BlockMathNode(r'\sum_{i=1}^{n}x_i'),
      ];

      final content = RichContent(nodes: source);
      source
        ..clear()
        ..add(const TextNode('changed'));

      expect(content.nodes, hasLength(6));
      expect(content.nodes[0], same(first));
      expect(content.nodes[1], same(second));
      expect(content.nodes[2], same(repeated));
      expect(content.nodes[3], same(repeated));
      expect((content.nodes[0] as TextNode).text, isEmpty);
      expect(
        (content.nodes[1] as TextNode).text,
        '  合成文本\n**保持原样**  ',
      );
      expect(
        () => content.nodes.add(const TextNode('later')),
        throwsUnsupportedError,
      );
    });

    test('allows empty content', () {
      final content = RichContent(nodes: const <ContentNode>[]);

      expect(content.nodes, isEmpty);
    });

    test('ImageNode uses structural equality and hash semantics', () {
      final first = ImageNode(
        sourceId: 'source_001',
        localAssetId: 'asset_001',
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('synthetic alt'),
          InlineMathNode(r'x+1'),
        ]),
      );
      final equal = ImageNode(
        sourceId: 'source_001',
        localAssetId: 'asset_001',
        alternativeText: RichContent(nodes: const <ContentNode>[
          TextNode('synthetic alt'),
          InlineMathNode(r'x+1'),
        ]),
      );
      final different = ImageNode(
        sourceId: 'source_001',
        localAssetId: 'asset_002',
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(different, isNot(first));
    });

    test('TableStructure validates rectangular geometry and preserves spans',
        () {
      final structure = TableStructure(rows: <TableRow>[
        TableRow(cells: <TableCell>[
          TableCell(
            content: RichContent(nodes: const <ContentNode>[TextNode('a')]),
            rowSpan: 2,
          ),
          TableCell(
            content: RichContent(
              nodes: const <ContentNode>[InlineMathNode(r'b')],
            ),
            columnSpan: 2,
          ),
        ]),
        TableRow(cells: <TableCell>[
          TableCell(content: RichContent(nodes: const <ContentNode>[])),
          TableCell(
            content: RichContent(
              nodes: const <ContentNode>[BlockMathNode(r'c')],
            ),
          ),
        ]),
      ]);

      expect(structure.columnCount, 3);
      expect(structure.expandedCellCount, 6);
      expect(
          structure.expandedCells[0][0]!.content,
          RichContent(nodes: const [
            TextNode('a'),
          ]));
      expect(
          structure.expandedCells[0][1]!.content,
          RichContent(nodes: const [
            InlineMathNode(r'b'),
          ]));
      expect(structure.expandedCells[0][2], isNull);
      expect(structure.expandedCells[1][0], isNull);
      expect(structure.expandedCells[1][1]!.content.nodes, isEmpty);
      expect(
          structure.expandedCells[1][2]!.content,
          RichContent(nodes: const [
            BlockMathNode(r'c'),
          ]));

      final equal = TableStructure(rows: <TableRow>[
        TableRow(cells: <TableCell>[
          TableCell(
            content: RichContent(nodes: const <ContentNode>[TextNode('a')]),
            rowSpan: 2,
          ),
          TableCell(
            content: RichContent(
              nodes: const <ContentNode>[InlineMathNode(r'b')],
            ),
            columnSpan: 2,
          ),
        ]),
        TableRow(cells: <TableCell>[
          TableCell(content: RichContent(nodes: const <ContentNode>[])),
          TableCell(
            content: RichContent(
              nodes: const <ContentNode>[BlockMathNode(r'c')],
            ),
          ),
        ]),
      ]);
      expect(equal, structure);
      expect(equal.hashCode, structure.hashCode);
    });

    test('rejects invalid, overlapping, and non-rectangular tables', () {
      final empty = RichContent(nodes: const <ContentNode>[]);
      expect(
        () => TableCell(content: empty, rowSpan: 0),
        throwsFormatException,
      );
      expect(
        () => TableCell(content: empty, columnSpan: -1),
        throwsFormatException,
      );

      final nestedTable = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[TableCell(content: empty)]),
        ]),
      );
      expect(
        () => TableCell(
          content: RichContent(nodes: <ContentNode>[nestedTable]),
        ),
        throwsFormatException,
      );
      expect(
        () => TableCell(
          content: RichContent(nodes: <ContentNode>[
            RawFallbackNode(<Object?, Object?>{
              'type': 'future_diagram',
              'payload': <Object?, Object?>{'value': 1},
            }),
          ]),
        ),
        throwsFormatException,
      );

      expect(
        () => TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(content: empty),
            TableCell(content: empty),
          ]),
          TableRow(cells: <TableCell>[TableCell(content: empty)]),
        ]),
        throwsFormatException,
      );

      expect(
        () => TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(content: empty, rowSpan: 2),
            TableCell(content: empty),
            TableCell(content: empty, rowSpan: 2),
          ]),
          TableRow(cells: <TableCell>[
            TableCell(content: empty, columnSpan: 2),
          ]),
        ]),
        throwsFormatException,
      );
    });
  });

  group('RawFallbackNode', () {
    test('defensively deep-copies and freezes JSON data', () {
      final originalItems = <Object?>[1, true, null, 'x'];
      final originalNested = <Object?, Object?>{'items': originalItems};
      final original = <Object?, Object?>{
        'type': 'future_diagram',
        'id': 'diagram-1',
        'nested': originalNested,
      };

      final node = RawFallbackNode(original);
      original['type'] = 'changed';
      originalItems
        ..[0] = 99
        ..add('later');

      expect(node.rawJson['type'], 'future_diagram');
      final nested = node.rawJson['nested']! as Map<String, Object?>;
      final items = nested['items']! as List<Object?>;
      expect(items, <Object?>[1, true, null, 'x']);
      expect(
        () => node.rawJson['type'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => items.add('later'), throwsUnsupportedError);
    });

    test('rejects values that are not safe JSON', () {
      expect(
        () => RawFallbackNode(<Object?, Object?>{1: 'invalid-key'}),
        throwsFormatException,
      );
      expect(
        () => RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'value': Object(),
        }),
        throwsFormatException,
      );
      expect(
        () => RawFallbackNode(<Object?, Object?>{
          'type': 'future_diagram',
          'value': double.nan,
        }),
        throwsFormatException,
      );
    });

    test('rejects missing type and cyclic collections', () {
      expect(
        () => RawFallbackNode(<Object?, Object?>{'payload': 'synthetic'}),
        throwsFormatException,
      );
      expect(
        () => RawFallbackNode(<Object?, Object?>{'type': '  '}),
        throwsFormatException,
      );

      final cyclic = <Object?, Object?>{'type': 'future_diagram'};
      cyclic['self'] = cyclic;
      expect(() => RawFallbackNode(cyclic), throwsFormatException);
    });
  });
}
