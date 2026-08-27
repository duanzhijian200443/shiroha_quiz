import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_table_projection.dart';

void main() {
  final sourceRef = SourceRef.document(sourceId: 'synthetic_source');

  test('projects a simple table through normalized geometry', () {
    final result = OcrTableProjector.analyzeHtmlTable(
      '<table><tr><td>A</td><th>B</th></tr></table>',
      sourceRef: sourceRef,
    );

    expect(result.failureCategory, isNull);
    final table = result.table;
    expect(table, isNotNull);
    expect(table!.isNormalized, isTrue);
    expect(table.structure!.rows, hasLength(1));
    expect(table.structure!.columnCount, 2);
    expect(table.structure!.rows.single.cells, hasLength(2));
    expect(table.rows.single.map(_text), <String>['A', 'B']);
  });

  test('accepts quoted, unquoted, and case-insensitive span attributes', () {
    final variants = <String>[
      '<td rowspan="2">A</td><td>B</td>',
      "<td rowspan='2'>A</td><td>B</td>",
      '<td ROWSPAN=2>A</td><td>B</td>',
      '<td colspan="2">A</td>',
    ];

    for (final cells in variants) {
      final html = cells.contains('colspan')
          ? '<table><tr>$cells</tr></table>'
          : '<table><tr>$cells</tr><tr><td>C</td></tr></table>';
      final result = OcrTableProjector.analyzeHtmlTable(
        html,
        sourceRef: sourceRef,
      );

      expect(result.table, isNotNull, reason: cells);
      expect(result.table!.structure, isNotNull, reason: cells);
    }
  });

  test('preserves combined row and column spans', () {
    final result = OcrTableProjector.analyzeHtmlTable(
      '<table>'
      '<tr><td rowspan="2" colspan="2">A</td><td>B</td></tr>'
      '<tr><td>C</td></tr>'
      '</table>',
      sourceRef: sourceRef,
    );

    expect(result.table, isNotNull);
    final structure = result.table!.structure!;
    expect(structure.rows.first.cells.first.rowSpan, 2);
    expect(structure.rows.first.cells.first.columnSpan, 2);
    expect(structure.columnCount, 3);
    expect(structure.expandedCells, hasLength(2));
    expect(structure.expandedCells.first, hasLength(3));
  });

  test('rejects malformed or duplicated span attributes', () {
    final invalidValues = <String>[
      'rowspan=""',
      'rowspan',
      'rowspan="0"',
      'rowspan="-1"',
      'rowspan="two"',
      'rowspan="2" ROWSPAN="3"',
      'colspan=""',
      'colspan="0"',
      'colspan="-1"',
      'colspan="two"',
      'colspan="2" COLSPAN="3"',
    ];

    for (final attributes in invalidValues) {
      final result = OcrTableProjector.analyzeHtmlTable(
        '<table><tr><td $attributes>A</td></tr></table>',
        sourceRef: sourceRef,
      );

      expect(result.table, isNull, reason: attributes);
      expect(
        result.failureCategory,
        OcrTableProjectionFailureCategory.mergedCells,
        reason: attributes,
      );
    }
  });

  test('rejects span geometry that exceeds the table bounds', () {
    final result = OcrTableProjector.analyzeHtmlTable(
      '<table><tr><td rowspan="2">A</td></tr></table>',
      sourceRef: sourceRef,
    );

    expect(result.table, isNull);
    expect(
      result.failureCategory,
      OcrTableProjectionFailureCategory.sourceTableInvalid,
    );
  });
}

String _text(RichContent content) {
  final node = content.nodes.single;
  return (node as TextNode).text;
}
