// P5 reviewer-findings closure: pure-Dart lossless typed editor codec tests.
// No widgets, no database, no Provider/OCR/Replay/network. All inputs are
// synthetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/typed_answer_editor_codec.dart';

RichContent _content(List<ContentNode> nodes) {
  return RichContent(nodes: nodes);
}

bool _sameNode(ContentNode left, ContentNode right) {
  if (left.runtimeType != right.runtimeType) return false;
  return switch (left) {
    TextNode(:final text) => text == (right as TextNode).text,
    InlineMathNode(:final latex) => latex == (right as InlineMathNode).latex,
    BlockMathNode(:final latex) => latex == (right as BlockMathNode).latex,
    ImageNode() || TableNode() => false,
    RawFallbackNode() => false, // never part of a lossless round-trip
  };
}

void _expectRoundTrip(RichContent input) {
  final encoded = TypedAnswerEditorCodec.encode(input);
  expect(encoded, isA<TypedAnswerEditorText>());
  final text = (encoded as TypedAnswerEditorText).text;
  final decoded = TypedAnswerEditorCodec.decode(text);
  expect(decoded, isA<TypedAnswerEditorContent>(), reason: 'decode($text)');
  final actual = (decoded as TypedAnswerEditorContent).content;
  expect(actual.nodes.length, input.nodes.length);
  for (var index = 0; index < input.nodes.length; index++) {
    expect(
      _sameNode(actual.nodes[index], input.nodes[index]),
      isTrue,
      reason: 'node $index did not round-trip',
    );
  }
}

void main() {
  group('TypedAnswerEditorCodec encode/decode round-trip', () {
    test('plain TextNode survives unchanged', () {
      _expectRoundTrip(_content(const <ContentNode>[TextNode('plain text')]));
    });

    test('literal dollar text stays a TextNode, never re-parsed as math', () {
      _expectRoundTrip(_content(const <ContentNode>[TextNode(r'$x$')]));
      final encoded = TypedAnswerEditorCodec.encode(
        _content(const <ContentNode>[TextNode(r'$x$')]),
      ) as TypedAnswerEditorText;
      expect(encoded.text, r'\$x\$');
    });

    test('literal inline-delimiter text stays a TextNode', () {
      _expectRoundTrip(_content(const <ContentNode>[TextNode(r'\(x\)')]));
    });

    test('literal block-delimiter text stays a TextNode', () {
      _expectRoundTrip(_content(const <ContentNode>[TextNode(r'\[x\]')]));
    });

    test('InlineMathNode survives unchanged', () {
      _expectRoundTrip(_content(const <ContentNode>[InlineMathNode('x')]));
    });

    test('BlockMathNode survives unchanged', () {
      _expectRoundTrip(
        _content(const <ContentNode>[BlockMathNode(r'y = \int_0^1 x\,dx')]),
      );
    });

    test('BlockMathNode with escaped delimiter-like LaTeX survives unchanged',
        () {
      _expectRoundTrip(
        _content(const <ContentNode>[
          BlockMathNode(r'\begin{array}{l}a\\[2mm]b\end{array}'),
        ]),
      );
    });

    test('escaped closing-like delimiters inside math survive unchanged', () {
      _expectRoundTrip(
        _content(const <ContentNode>[
          BlockMathNode(r'a\\]b'),
          InlineMathNode(r'a\\)b'),
        ]),
      );
    });

    test('text plus inline math mix survives unchanged', () {
      _expectRoundTrip(
        _content(const <ContentNode>[
          TextNode('value '),
          InlineMathNode('x+1'),
          TextNode(' done'),
        ]),
      );
    });

    test('text plus block math mix survives unchanged', () {
      _expectRoundTrip(
        _content(const <ContentNode>[
          TextNode('before '),
          BlockMathNode('y=2'),
          TextNode(' after'),
        ]),
      );
    });

    test('explicit empty RichContent stays empty content, never null', () {
      final encoded = TypedAnswerEditorCodec.encode(
        _content(const <ContentNode>[]),
      );
      expect(encoded, isA<TypedAnswerEditorText>());
      expect((encoded as TypedAnswerEditorText).text, '');
      final decoded = TypedAnswerEditorCodec.decode('');
      expect(decoded, isA<TypedAnswerEditorContent>());
      final content = (decoded as TypedAnswerEditorContent).content;
      expect(content.nodes, isEmpty);
    });
  });

  group('TypedAnswerEditorCodec decode manual input', () {
    test('dollar input becomes InlineMathNode', () {
      final decoded = TypedAnswerEditorCodec.decode(r'$x^2+1$');
      expect(decoded, isA<TypedAnswerEditorContent>());
      final nodes = (decoded as TypedAnswerEditorContent).content.nodes;
      expect(nodes, hasLength(1));
      expect(nodes.single, isA<InlineMathNode>());
      expect((nodes.single as InlineMathNode).latex, 'x^2+1');
    });

    test('block dollar input becomes BlockMathNode', () {
      final decoded = TypedAnswerEditorCodec.decode(r'$$\int_0^1 x\,dx$$');
      expect(decoded, isA<TypedAnswerEditorContent>());
      final nodes = (decoded as TypedAnswerEditorContent).content.nodes;
      expect(nodes.single, isA<BlockMathNode>());
    });

    test('delimiter-wrapped math becomes math nodes', () {
      final decoded = TypedAnswerEditorCodec.decode(r'\(y=2\) \[z=3\]');
      expect(decoded, isA<TypedAnswerEditorContent>());
      final nodes = (decoded as TypedAnswerEditorContent).content.nodes;
      expect(nodes, hasLength(3));
      expect(nodes[0], isA<InlineMathNode>());
      expect((nodes[1] as TextNode).text, ' ');
      expect(nodes[2], isA<BlockMathNode>());
    });

    test('think blocks are ordinary text, never stripped or truncated', () {
      const closed = '答案 A <think>这是普通用户文字</think> 后续';
      const unclosed = '答案 A <think>未闭合但仍是用户输入';
      for (final input in <String>[closed, unclosed]) {
        final decoded = TypedAnswerEditorCodec.decode(input);
        expect(decoded, isA<TypedAnswerEditorContent>(), reason: input);
        final nodes = (decoded as TypedAnswerEditorContent).content.nodes;
        expect(nodes, hasLength(1), reason: input);
        expect((nodes.single as TextNode).text, input, reason: input);
      }
    });

    test('markdown image input is an explicit unsupported failure', () {
      final decoded = TypedAnswerEditorCodec.decode(
          '![img](https://example.invalid/x.png)');
      expect(decoded, isA<TypedAnswerEditorUnsupported>());
      expect(
        decoded.toString(),
        'The typed answer contains unsupported content.',
      );
    });

    test('blank runs are an explicit unsupported failure', () {
      expect(
        TypedAnswerEditorCodec.decode('fill ___ here'),
        isA<TypedAnswerEditorUnsupported>(),
      );
    });

    test('unclosed delimiter is an explicit unsupported failure', () {
      expect(
        TypedAnswerEditorCodec.decode(r'\(unclosed'),
        isA<TypedAnswerEditorUnsupported>(),
      );
    });

    test('decode never produces RawFallbackNode', () {
      for (final input in <String>[
        'plain',
        r'$x$',
        r'$$y$$',
        r'text \(a\) more \[b\] end',
        r'literal \$x\$ and \\(x\\)',
      ]) {
        final decoded = TypedAnswerEditorCodec.decode(input);
        if (decoded case TypedAnswerEditorContent(:final content)) {
          expect(content.nodes.whereType<RawFallbackNode>(), isEmpty,
              reason: input);
        }
      }
    });
  });

  group('TypedAnswerEditorCodec encode unsupported nodes', () {
    test('RawFallbackNode cannot be flattened into editable text', () {
      final encoded = TypedAnswerEditorCodec.encode(
        _content(<ContentNode>[
          const TextNode('before '),
          RawFallbackNode(<Object?, Object?>{
            'type': 'future_diagram',
            'payload': <Object?, Object?>{'shape': 'synthetic'},
          }),
        ]),
      );
      expect(encoded, isA<TypedAnswerEditorUnsupported>());
    });
  });
}
