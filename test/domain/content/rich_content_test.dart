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
