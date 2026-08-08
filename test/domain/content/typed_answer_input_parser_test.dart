// P5.1 typed manual answer input parser unit tests (pure Dart, no widgets,
// no database, no Provider/OCR/Replay/network). All inputs are synthetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/utils/typed_answer_input_parser.dart';

void main() {
  group('TypedAnswerInputParser', () {
    test('E: typed math input becomes InlineMathNode, never TextNode', () {
      final result = TypedAnswerInputParser.parse(r'$x^2+1$');
      expect(result, isA<TypedAnswerInputParsed>());
      final nodes = (result as TypedAnswerInputParsed).content.nodes;
      expect(nodes, hasLength(1));
      final node = nodes.single;
      expect(node, isA<InlineMathNode>());
      expect((node as InlineMathNode).latex, r'x^2+1');
      expect(node, isNot(isA<TextNode>()));
    });

    test('block dollar input becomes BlockMathNode', () {
      final result = TypedAnswerInputParser.parse(r'$$\int_0^1 x\,dx$$');
      expect(result, isA<TypedAnswerInputParsed>());
      final node = (result as TypedAnswerInputParsed).content.nodes.single;
      expect(node, isA<BlockMathNode>());
      expect((node as BlockMathNode).latex, r'\int_0^1 x\,dx');
    });

    test('already-wrapped delimiters keep their math node', () {
      final result = TypedAnswerInputParser.parse(r'\(y=2\)');
      expect(result, isA<TypedAnswerInputParsed>());
      final node = (result as TypedAnswerInputParsed).content.nodes.single;
      expect(node, isA<InlineMathNode>());
      expect((node as InlineMathNode).latex, 'y=2');
    });

    test('mixed text and math preserve node order', () {
      final result = TypedAnswerInputParser.parse(r'value is $x$ done');
      expect(result, isA<TypedAnswerInputParsed>());
      final nodes = (result as TypedAnswerInputParsed).content.nodes;
      expect(nodes, hasLength(3));
      expect((nodes[0] as TextNode).text, 'value is ');
      expect((nodes[1] as InlineMathNode).latex, 'x');
      expect((nodes[2] as TextNode).text, ' done');
    });

    test('plain text becomes an ordinary TextNode', () {
      final result = TypedAnswerInputParser.parse('plain answer');
      expect(result, isA<TypedAnswerInputParsed>());
      final node = (result as TypedAnswerInputParsed).content.nodes.single;
      expect(node, isA<TextNode>());
      expect((node as TextNode).text, 'plain answer');
    });

    test('escaped dollar decodes to a literal dollar TextNode', () {
      final result = TypedAnswerInputParser.parse(r'\$x\$');
      expect(result, isA<TypedAnswerInputParsed>());
      final node = (result as TypedAnswerInputParsed).content.nodes.single;
      expect(node, isA<TextNode>());
      expect((node as TextNode).text, r'$x$');
    });

    test('empty and whitespace-only input is an explicit empty result', () {
      for (final input in <String>['', '   ', '\t\n']) {
        expect(
          TypedAnswerInputParser.parse(input),
          isA<TypedAnswerInputEmpty>(),
          reason: 'input=$input',
        );
      }
    });

    test('manual <think> blocks are preserved literally, never stripped', () {
      const input = '答案 A <think>这是普通用户文字</think> 后续';
      final result = TypedAnswerInputParser.parse(input);
      expect(result, isA<TypedAnswerInputParsed>());
      final nodes = (result as TypedAnswerInputParsed).content.nodes;
      expect(nodes, hasLength(1));
      expect((nodes.single as TextNode).text, input);
    });

    test('unclosed <think> keeps the trailing user text, never truncates', () {
      const input = '答案 A <think>未闭合但仍是用户输入';
      final result = TypedAnswerInputParser.parse(input);
      expect(result, isA<TypedAnswerInputParsed>());
      final nodes = (result as TypedAnswerInputParsed).content.nodes;
      expect(nodes, hasLength(1));
      expect((nodes.single as TextNode).text, input);
    });

    test('whitespace-only think block is ordinary text, not empty input', () {
      const input = '<think> </think>';
      final result = TypedAnswerInputParser.parse(input);
      expect(result, isA<TypedAnswerInputParsed>());
      final nodes = (result as TypedAnswerInputParsed).content.nodes;
      expect(nodes, hasLength(1));
      expect((nodes.single as TextNode).text, input);
    });

    test('image tokens fail safely with fixed redacted text', () {
      final result = TypedAnswerInputParser.parse(
        'see ![diagram](https://example.invalid/d.png)',
      );
      expect(result, isA<TypedAnswerInputUnsupported>());
      expect(
        result.toString(),
        'The typed answer contains unsupported content.',
      );
      expect(result.toString(), isNot(contains('example.invalid')));
      expect(result.toString(), isNot(contains('diagram')));
    });

    test('blank tokens fail safely', () {
      expect(
        TypedAnswerInputParser.parse('fill ___ here'),
        isA<TypedAnswerInputUnsupported>(),
      );
    });

    test('parse-error tokens fail safely', () {
      expect(
        TypedAnswerInputParser.parse(r'\(unclosed'),
        isA<TypedAnswerInputUnsupported>(),
      );
    });

    test('parsed content never contains RawFallbackNode', () {
      for (final input in <String>[
        'plain',
        r'$x$',
        r'$$y$$',
        r'text \(a\) more \[b\] end',
      ]) {
        final result = TypedAnswerInputParser.parse(input);
        expect(result, isA<TypedAnswerInputParsed>(), reason: input);
        final nodes = (result as TypedAnswerInputParsed).content.nodes;
        expect(
          nodes.whereType<RawFallbackNode>(),
          isEmpty,
          reason: input,
        );
      }
    });
  });
}
