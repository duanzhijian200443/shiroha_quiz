import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_document_codec.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_table_projection.dart';

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
}

String _text(RichContent content) {
  return content.nodes.whereType<TextNode>().map((node) => node.text).join();
}
