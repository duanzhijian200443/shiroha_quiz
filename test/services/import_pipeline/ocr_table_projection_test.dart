import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_document_codec.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_rich_content_parser.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_table_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';

void main() {
  final sourceRef = SourceRef.document(sourceId: 'synthetic_source');

  test('projects a simple unit-span table through normalized geometry', () {
    final table = OcrTableProjector.parseHtmlTable(
      '<table><tr><td>A</td><th>B</th></tr></table>',
      sourceRef: sourceRef,
    );

    expect(table, isNotNull);
    expect(table!.isNormalized, isTrue);
    expect(table.structure!.columnCount, 2);
    expect(table.structure!.rows.single.cells, hasLength(2));
    expect(table.rows.single.map(_text), <String>['A', 'B']);
  });

  test('accepts quoted, single-quoted, unquoted, and mixed-case spans', () {
    final variants = <String>[
      '<td rowspan="2">A</td><td>B</td>',
      "<td rowspan='2'>A</td><td>B</td>",
      '<td ROWSPAN=2>A</td><td>B</td>',
      '<td colspan="1">A</td><td>B</td>',
      "<td COLSPAN='1'>A</td><td>B</td>",
      '<td colspan=1>A</td><td>B</td>',
    ];

    for (final cells in variants) {
      final hasRowSpan = cells.toLowerCase().contains('rowspan');
      final html = hasRowSpan
          ? '<table><tr>$cells</tr><tr><td>C</td></tr></table>'
          : '<table><tr>$cells</tr></table>';
      expect(
        OcrTableProjector.parseHtmlTable(html, sourceRef: sourceRef),
        isNotNull,
        reason: cells,
      );
    }
  });

  test('preserves combined spans and projects canonical expanded geometry', () {
    final table = OcrTableProjector.parseHtmlTable(
      '<table>'
      '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
      '<tr><td>C</td></tr>'
      '</table>',
      sourceRef: sourceRef,
    );

    expect(table, isNotNull);
    final structure = table!.structure!;
    expect(structure.rows.first.cells.first.rowSpan, 2);
    expect(structure.rows.first.cells.first.columnSpan, 2);
    expect(structure.columnCount, 3);
    expect(structure.expandedCells, hasLength(2));
    expect(OcrTableProjector.projectToPlainText(table), 'A |  | B\n |  | C');
  });

  test('persists only canonical content and geometry, never provider HTML', () {
    const html = '<table>'
        '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
        '<tr><td>C</td></tr>'
        '</table>';
    final table = OcrTableProjector.parseHtmlTable(
      html,
      sourceRef: SourceRef.document(sourceId: 'artifact_0001'),
    )!;
    final encoded = jsonEncode(
      const SourceDocumentCodec().encode(
        SourceDocument(
          sourceId: 'artifact_0001',
          parts: <SourcePart>[table],
        ),
      ),
    );

    expect(encoded, isNot(contains('<table')));
    expect(encoded, isNot(contains('rowspan=')));
    expect(encoded, contains('"rowSpan":2'));
    expect(encoded, contains('"columnSpan":2'));
  });

  test('rejects missing, empty, invalid, and duplicate span values', () {
    final invalid = <String>[
      'rowspan',
      'rowspan=""',
      'rowspan="0"',
      'rowspan="-1"',
      'rowspan="two"',
      'rowspan="2" ROWSPAN="3"',
      'colspan',
      'colspan=""',
      'colspan="0"',
      'colspan="-1"',
      'colspan="two"',
      'colspan="2" COLSPAN="3"',
    ];

    for (final attributes in invalid) {
      expect(
        OcrTableProjector.parseHtmlTable(
          '<table><tr><td $attributes>A</td></tr></table>',
          sourceRef: sourceRef,
        ),
        isNull,
        reason: attributes,
      );
    }
  });

  test('rejects out-of-bounds, holes, and over-limit geometry', () {
    final invalid = <String>[
      '<table><tr><td rowspan="2">A</td></tr></table>',
      '<table>'
          '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
          '<tr><td>C</td><td>D</td><td>E</td></tr>'
          '</table>',
      '<table><tr><td colspan="65">A</td></tr></table>',
      '<table><tr>${List<String>.filled(51, '<td>A</td>').join()}</tr></table>',
      '<table>${List<String>.filled(65, '<tr><td>A</td></tr>').join()}</table>',
    ];

    for (final html in invalid) {
      expect(
        OcrTableProjector.parseHtmlTable(html, sourceRef: sourceRef),
        isNull,
      );
    }
  });

  test('rejects nested, multiple, malformed, and unsafe table authority', () {
    final invalid = <String>[
      '<table><tr><td><table><tr><td>x</td></tr></table></td></tr></table>',
      '<table><tr><td>A</td></tr></table><table><tr><td>B</td></tr></table>',
      'prefix<table><tr><td>A</td></tr></table>',
      '<table><tr><td>A</th></tr></table>',
      '<table><tr><td><script>x</script></td></tr></table>',
      '<table><tr><td><img src="x"></td></tr></table>',
      '<table><tr><td><a href="x">x</a></td></tr></table>',
      '<table><tr><td onclick="x">x</td></tr></table>',
      '<table><tr><td><video>x</video></td></tr></table>',
    ];

    for (final html in invalid) {
      expect(
        OcrTableProjector.parseHtmlTable(html, sourceRef: sourceRef),
        isNull,
        reason: html,
      );
    }
  });

  test('retains bounded passive formatting cleanup and entity decode', () {
    final table = OcrTableProjector.parseHtmlTable(
      '<table><tr><td><strong>A</strong><br>&amp; B</td></tr></table>',
      sourceRef: sourceRef,
    );

    expect(table, isNotNull);
    expect(_text(table!.rows.single.single), 'A & B');
  });

  test('rejects oversized input before parsing', () {
    expect(
      OcrTableProjector.parseHtmlTable(
        '<table>${'x' * OcrTableProjector.maxInputLength}</table>',
        sourceRef: sourceRef,
      ),
      isNull,
    );
  });

  group('R2 Table Cell Math Structuralization', () {
    test('A. explicit inline math parses into TextNode and InlineMathNode', () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        r'<table><tr><td>概率为 $\frac{1}{p}$</td></tr></table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final cellContent = table.structure!.rows.single.cells.single.content;
      expect(cellContent.nodes, hasLength(2));
      expect(cellContent.nodes[0], isA<TextNode>());
      expect((cellContent.nodes[0] as TextNode).text, '概率为 ');
      expect(cellContent.nodes[1], isA<InlineMathNode>());
      expect((cellContent.nodes[1] as InlineMathNode).latex, r'\frac{1}{p}');
      expect(math.rawMath(cellContent.nodes[1]), r'$\frac{1}{p}$');
    });

    test('B. explicit block math parses into BlockMathNode', () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        r'<table><tr><td>$$x^2+y^2=1$$</td></tr></table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final cellContent = table.structure!.rows.single.cells.single.content;
      expect(cellContent.nodes, hasLength(1));
      expect(cellContent.nodes.single, isA<BlockMathNode>());
      expect((cellContent.nodes.single as BlockMathNode).latex, r'x^2+y^2=1');
      expect(math.rawMath(cellContent.nodes.single), r'$$x^2+y^2=1$$');
    });

    test('C. multiple math spans parse in correct order', () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        r'<table><tr><td>$x$ 与 $y$</td></tr></table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final cellContent = table.structure!.rows.single.cells.single.content;
      expect(cellContent.nodes, hasLength(3));
      expect(cellContent.nodes[0], isA<InlineMathNode>());
      expect((cellContent.nodes[0] as InlineMathNode).latex, 'x');
      expect(cellContent.nodes[1], isA<TextNode>());
      expect((cellContent.nodes[1] as TextNode).text, ' 与 ');
      expect(cellContent.nodes[2], isA<InlineMathNode>());
      expect((cellContent.nodes[2] as InlineMathNode).latex, 'y');
    });

    test('D. ordinary text remains TextNode', () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        '<table><tr><td>数学期望</td></tr></table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final cellContent = table.structure!.rows.single.cells.single.content;
      expect(cellContent.nodes, hasLength(1));
      expect(cellContent.nodes.single, isA<TextNode>());
      expect((cellContent.nodes.single as TextNode).text, '数学期望');
    });

    test('E. legacy parity projects raw math delimiter', () {
      final math = OcrMathSourceMap();
      const html =
          r'<table><tr><td>几何分布</td><td>$\frac{1}{p}$</td></tr></table>';
      final table = OcrTableProjector.parseHtmlTable(
        html,
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      // Without mathSourceMap, projectToPlainText strips delimiter
      expect(
        OcrTableProjector.projectToPlainText(table),
        r'几何分布 | \frac{1}{p}',
      );
      // With mathSourceMap, projectToPlainText restores original delimiter
      expect(
        OcrTableProjector.projectToPlainText(table, mathSourceMap: math),
        r'几何分布 | $\frac{1}{p}$',
      );

      // Verify QuestionDraftV2LegacyProjector compatibility projection
      final draft = QuestionDraftV2(
        questionId: 'test_q_1',
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(nodes: [
          TableNode(structure: table.structure!),
        ]),
        options: const [],
        sourceRefs: [sourceRef],
      );
      final region = QuestionRegion(
        questionNumber: 1,
        kindHint: QuestionRegionKindHint.shortAnswer,
        sourceRefs: [sourceRef],
        fragments: [
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: table,
          ),
        ],
      );
      final projected = const QuestionDraftV2LegacyProjector().project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
        mathSourceMap: math,
      );

      expect(projected.question['content'], contains(r'$\frac{1}{p}$'));
    });

    test('F. merged table preserves geometry while structuralizing math cell',
        () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        '<table>'
        r'<tr><td rowspan="2">$\mu$</td><td>$\sigma^2$</td></tr>'
        r'<tr><td>正态分布</td></tr>'
        '</table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final structure = table.structure!;
      expect(structure.rows.length, 2);
      expect(structure.columnCount, 2);
      expect(structure.rows.first.cells.first.rowSpan, 2);
      expect(structure.rows.first.cells.first.content.nodes.single,
          isA<InlineMathNode>());
      expect(structure.rows.first.cells[1].content.nodes.single,
          isA<InlineMathNode>());
      expect(structure.rows.last.cells.single.content.nodes.single,
          isA<TextNode>());
    });

    test(
        'I. whole-cell bare formula parses to BlockMathNode while negative cases stay TextNode',
        () {
      final math = OcrMathSourceMap();
      final table = OcrTableProjector.parseHtmlTable(
        '<table>'
        r'<tr><td>\lambda</td></tr>'
        r'<tr><td>P{X=k}=p^{k}(1-p)^{1-k},k=0,1</td></tr>'
        r'<tr><td>设随机变量服从正态分布</td></tr>'
        r'<tr><td>见 \varphi 的定义</td></tr>'
        r'<tr><td>A</td></tr>'
        r'<tr><td>1</td></tr>'
        '</table>',
        sourceRef: sourceRef,
        mathSourceMap: math,
      )!;

      final rows = table.structure!.rows;
      // 1. \lambda -> BlockMathNode
      expect(rows[0].cells.single.content.nodes.single, isA<BlockMathNode>());
      expect((rows[0].cells.single.content.nodes.single as BlockMathNode).latex,
          r'\lambda');

      // 2. P{X=k}=p^{k}(1-p)^{1-k},k=0,1 -> BlockMathNode
      expect(rows[1].cells.single.content.nodes.single, isA<BlockMathNode>());

      // 3. 设随机变量服从正态分布 -> TextNode (negative case: CJK)
      expect(rows[2].cells.single.content.nodes.single, isA<TextNode>());
      expect((rows[2].cells.single.content.nodes.single as TextNode).text,
          '设随机变量服从正态分布');

      // 4. 见 \varphi 的定义 -> TextNode (negative case: mixed text)
      expect(rows[3].cells.single.content.nodes.single, isA<TextNode>());
      expect((rows[3].cells.single.content.nodes.single as TextNode).text,
          r'见 \varphi 的定义');

      // 5. A -> TextNode (negative case: plain label)
      expect(rows[4].cells.single.content.nodes.single, isA<TextNode>());
      expect((rows[4].cells.single.content.nodes.single as TextNode).text, 'A');

      // 6. 1 -> TextNode (negative case: plain number)
      expect(rows[5].cells.single.content.nodes.single, isA<TextNode>());
      expect((rows[5].cells.single.content.nodes.single as TextNode).text, '1');
    });

    test(
        'backward compatibility without mathSourceMap leaves cells as TextNode',
        () {
      final table = OcrTableProjector.parseHtmlTable(
        r'<table><tr><td>$\frac{1}{p}$</td></tr></table>',
        sourceRef: sourceRef,
      )!;

      final cellContent = table.structure!.rows.single.cells.single.content;
      expect(cellContent.nodes.single, isA<TextNode>());
      expect((cellContent.nodes.single as TextNode).text, r'$\frac{1}{p}$');
    });
  });
}

String _text(RichContent content) {
  return content.nodes.whereType<TextNode>().map((node) => node.text).join();
}
