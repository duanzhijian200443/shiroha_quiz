import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_table_projection.dart';

void main() {
  group('OcrTableProjector', () {
    final testRef = SourceRef.at(
      sourceId: 'test_doc.pdf',
      point: SourcePoint.block(pageNumber: 1, blockId: 'b1', readingOrder: 0),
    );

    test(
        'parses simple HTML table into SourceTablePart and projects to pipe text',
        () {
      const html = '''
<table border="1">
  <tr>
    <td>分布</td>
    <td>E(X)</td>
    <td>D(X)</td>
  </tr>
  <tr>
    <td>B(n,p)</td>
    <td>np</td>
    <td>np(1-p)</td>
  </tr>
</table>
''';
      final table = OcrTableProjector.parseHtmlTable(html, sourceRef: testRef);
      expect(table, isNotNull);
      expect(table!.rows.length, equals(2));
      expect(table.rows[0].length, equals(3));
      expect((table.rows[0][0].nodes.single as TextNode).text, equals('分布'));
      expect((table.rows[0][1].nodes.single as TextNode).text, equals('E(X)'));
      expect((table.rows[0][2].nodes.single as TextNode).text, equals('D(X)'));
      expect(
          (table.rows[1][0].nodes.single as TextNode).text, equals('B(n,p)'));
      expect((table.rows[1][1].nodes.single as TextNode).text, equals('np'));
      expect(
          (table.rows[1][2].nodes.single as TextNode).text, equals('np(1-p)'));

      final text = OcrTableProjector.projectToPlainText(table);
      expect(text, equals('分布 | E(X) | D(X)\nB(n,p) | np | np(1-p)'));
      expect(text.contains('<table'), isFalse);
      expect(text.contains('<tr'), isFalse);
      expect(text.contains('<td'), isFalse);
    });

    test('handles table with th tags, attributes, and decoded entities', () {
      const html = '''
<table class="grid" cellpadding="0">
  <tr>
    <th rowspan="2">指标 &amp; 参数</th>
    <th>条件 &lt; 0</th>
    <th>条件 &gt; 0</th>
  </tr>
  <tr>
    <td>&ldquo;特殊值&rdquo;</td>
    <td>&#39;有效&#39;</td>
  </tr>
</table>
''';
      final table = OcrTableProjector.parseHtmlTable(html, sourceRef: testRef);
      expect(table, isNotNull);
      expect(table!.rows.length, equals(2));
      final text = OcrTableProjector.projectToPlainText(table);
      expect(text, equals('指标 & 参数 | 条件 < 0 | 条件 > 0\n“特殊值” | \'有效\''));
    });

    test('handles math expressions inside table cells cleanly', () {
      const html = '''
<table border="1">
  <tr><td>(0-1)分布</td><td>P{X=k}=p^{k}(1-p)^{1-k},k=0,1</td><td>p</td><td>p(1-p)</td></tr>
  <tr><td>泊松分布</td><td>P{X=k}=\\frac{\\lambda^{k}}{k!}e^{-\\lambda}</td><td>\\lambda</td><td>\\lambda</td></tr>
</table>
''';
      final table = OcrTableProjector.parseHtmlTable(html, sourceRef: testRef);
      expect(table, isNotNull);
      final text = OcrTableProjector.projectToPlainText(table!);
      expect(
        text,
        equals(
          '(0-1)分布 | P{X=k}=p^{k}(1-p)^{1-k},k=0,1 | p | p(1-p)\n'
          '泊松分布 | P{X=k}=\\frac{\\lambda^{k}}{k!}e^{-\\lambda} | \\lambda | \\lambda',
        ),
      );
    });

    test('returns null for non-table strings or malformed empty tables', () {
      expect(
        OcrTableProjector.parseHtmlTable('Just regular text',
            sourceRef: testRef),
        isNull,
      );
      expect(
        OcrTableProjector.parseHtmlTable('<table></table>', sourceRef: testRef),
        isNull,
      );
      expect(
        OcrTableProjector.parseHtmlTable('<table><tr></tr></table>',
            sourceRef: testRef),
        isNull,
      );
    });

    test('projectHtmlToPlainText convenience helper matches parse + project',
        () {
      const html =
          '<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>';
      expect(OcrTableProjector.projectHtmlToPlainText(html),
          equals('A | B\nC | D'));
    });
  });
}
