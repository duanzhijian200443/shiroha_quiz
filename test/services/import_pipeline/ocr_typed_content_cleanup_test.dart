import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_content_cleanup.dart';

void main() {
  test('split wrappers preserve image, math and table identity and spacing',
      () {
    final image = ImageNode(sourceId: 'source', localAssetId: 'image');
    const math = InlineMathNode(r'\frac{1}{p}');
    final table = TableNode(
        structure: TableStructure(rows: [
      TableRow(cells: [
        TableCell(content: RichContent(nodes: [const TextNode('ordinary')]))
      ]),
    ]));
    final cleaned = cleanupOcrTypedHtml(RichContent(nodes: [
      const TextNode('before\n<div align="center">'),
      image,
      const TextNode('</div>\nafter '),
      math,
      const TextNode('\n<div align="center">'),
      table,
      const TextNode('</div>'),
    ]));
    expect(cleaned.nodes.whereType<ImageNode>().single, same(image));
    expect(cleaned.nodes.whereType<InlineMathNode>().single, same(math));
    expect(cleaned.nodes.whereType<TableNode>().single, same(table));
    expect(cleaned.nodes.whereType<TextNode>().map((n) => n.text).join(),
        'before\n\n\nafter \n');
    expect(cleanupOcrTypedHtml(cleaned), same(cleaned));
  });

  test('unknown or unsafe markup cannot remove structural content', () {
    final image = ImageNode(sourceId: 'source', localAssetId: 'image');
    for (final tag in ['script', 'custom']) {
      final original =
          RichContent(nodes: [TextNode('<$tag>'), image, TextNode('</$tag>')]);
      expect(cleanupOcrTypedHtml(original), same(original));
    }
  });

  test('an interrupted tag cannot consume an opaque image', () {
    final original = RichContent(nodes: [
      const TextNode('<div title="'),
      ImageNode(sourceId: 'source', localAssetId: 'image'),
      const TextNode('">safe</div>'),
    ]);
    expect(cleanupOcrTypedHtml(original), same(original));
  });
}
