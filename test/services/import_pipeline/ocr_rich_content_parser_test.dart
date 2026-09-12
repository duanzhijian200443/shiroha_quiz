import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_rich_content_parser.dart';

void main() {
  test('extraction placeholders cannot capture literal text or equal payloads',
      () {
    final map = OcrMathSourceMap();
    final content = map.parse('\uE0000\uE002 ' r'$x$\(x\)');
    final view = OcrMathExtractionView(content.nodes, map);
    final restored = view.restore(view.text(content.nodes)!);
    expect(restored, content.nodes);
    expect(identical(restored[1], content.nodes[1]), isTrue);
    expect(identical(restored[2], content.nodes[2]), isTrue);
    expect(map.rawMath(restored[1]), r'$x$');
    expect(map.rawMath(restored[2]), r'\(x\)');
  });
  test('escaped dollars count odd versus even backslashes', () {
    expect(OcrMathSourceMap().parse(r'\\$x$').nodes,
        [const TextNode(r'\\'), const InlineMathNode('x')]);
    expect(
        OcrMathSourceMap().parse(r'\\\$x$').nodes, [const TextNode(r'\\\$x$')]);
    expect(OcrMathSourceMap().parse(r'$x$ $$$$ suffix').nodes,
        [const InlineMathNode('x'), const TextNode(r' $$$$ suffix')]);
    expect(OcrMathSourceMap().parse(r'\(x\) $a$$b$').nodes,
        [const InlineMathNode('x'), const TextNode(r' $a$$b$')]);
  });

  test('mixed delimiters preserve exact payloads, text and original spans', () {
    final map = OcrMathSourceMap();
    final content = map.parse(r'设 $x_n$ 与 \( y \)，$$z$$ 和 \[w\]');
    expect(content.nodes, [
      const TextNode('设 '),
      const InlineMathNode('x_n'),
      const TextNode(' 与 '),
      const InlineMathNode(' y '),
      const TextNode('，'),
      const BlockMathNode('z'),
      const TextNode(' 和 '),
      const BlockMathNode('w')
    ]);
    expect(map.rawMath(content.nodes[1]), r'$x_n$');
  });
  test('literal and ambiguous suffixes remain byte-for-byte text', () {
    for (final text in [
      r'普通 ___ ![x](https://example.test) <div>x</div>',
      r'价格 $5 和 $10',
      r'\$5',
      r'$x',
      r'$$ $$',
      r'$a \(b\)$',
      r'\\(literal\\)',
      '\$a\nb\$'
    ]) {
      expect(OcrMathSourceMap().parse(text).nodes, [TextNode(text)]);
    }
    expect(OcrMathSourceMap().parse(r'$5$ then $bad').nodes,
        [const InlineMathNode('5'), const TextNode(r' then $bad')]);
  });
  test('formula role and instance identity do not conflate identical latex',
      () {
    final map = OcrMathSourceMap();
    expect(map.parse(r'\frac{1}{2}', formula: true).nodes,
        [const BlockMathNode(r'\frac{1}{2}')]);
    final nodes = map.parse(r'$x$\(x\)').nodes;
    expect(map.rawMath(nodes[0]), r'$x$');
    expect(map.rawMath(nodes[1]), r'\(x\)');
    expect(map.parse(r'\left(x', formula: true).nodes,
        [const TextNode(r'\left(x')]);
  });
  test('UTF16 source slices keep math whole and reject interior endpoints', () {
    final map = OcrMathSourceMap();
    final content = map.parse(r'😀 $x$ 中文');
    final parsed = map.parsed(content)!;
    expect(materializeQuestionRegionContent(content, parsed.slice(3, 6)),
        [const InlineMathNode('x')]);
    expect(() => parsed.slice(4, 6), throwsFormatException);
    expect(materializeQuestionRegionContent(content, parsed.slice(6, 9)),
        [const TextNode(' 中文')]);
  });
}
