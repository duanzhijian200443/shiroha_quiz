import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';

/// Fixed, privacy-safe reasons why a provider table was not admitted to the
/// typed source model. The category never contains table markup.
enum OcrTableProjectionFailureCategory {
  inputTooLarge,
  embeddedMediaOrLink,
  noRows,
  invalidCells,
  mergedCells,
  tooManyRows,
  tooManyColumns,
  sourceTableInvalid,
}

String ocrTableProjectionFailureCategoryValue(
  OcrTableProjectionFailureCategory category,
) {
  return switch (category) {
    OcrTableProjectionFailureCategory.inputTooLarge => 'input_too_large',
    OcrTableProjectionFailureCategory.embeddedMediaOrLink =>
      'embedded_media_or_link',
    OcrTableProjectionFailureCategory.noRows => 'no_rows',
    OcrTableProjectionFailureCategory.invalidCells => 'invalid_cells',
    OcrTableProjectionFailureCategory.mergedCells => 'merged_cells',
    OcrTableProjectionFailureCategory.tooManyRows => 'too_many_rows',
    OcrTableProjectionFailureCategory.tooManyColumns => 'too_many_columns',
    OcrTableProjectionFailureCategory.sourceTableInvalid =>
      'source_table_invalid',
  };
}

final class OcrTableProjectionResult {
  const OcrTableProjectionResult({this.table, this.failureCategory});

  const OcrTableProjectionResult.success(SourceTablePart table)
      : this(table: table);

  const OcrTableProjectionResult.failure(
    OcrTableProjectionFailureCategory failureCategory,
  ) : this(failureCategory: failureCategory);

  final SourceTablePart? table;
  final OcrTableProjectionFailureCategory? failureCategory;
}

/// Deterministic, bounded adapter for the provider's HTML table block.
///
/// HTML is an input representation only. It is never stored in a
/// [SourceTablePart] or used as the canonical legacy projection. Unsupported
/// markup and malformed tables fail closed; valid merged-cell geometry is
/// admitted through the shared [TableStructure] authority.
final class OcrTableProjector {
  const OcrTableProjector._();

  static const int maxInputLength = 100000;
  static const int maxRowCount = 200;
  static const int maxColumnCount = 50;

  static SourceTablePart? parseHtmlTable(
    String html, {
    required SourceRef sourceRef,
  }) {
    return analyzeHtmlTable(html, sourceRef: sourceRef).table;
  }

  static OcrTableProjectionResult analyzeHtmlTable(
    String html, {
    required SourceRef sourceRef,
  }) {
    if (html.length > maxInputLength) {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.inputTooLarge,
      );
    }
    final trimmed = html.trim();
    if (!RegExp(r'<table\b', caseSensitive: false).hasMatch(trimmed) ||
        RegExp(
          r'<(?:script|style)\b',
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.sourceTableInvalid,
      );
    }
    if (RegExp(
      r'<\s*(?:img|a)\b|\b(?:src|href)\s*=',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.embeddedMediaOrLink,
      );
    }

    final rowMatches = RegExp(
      r'<tr\b[^>]*>(.*?)</tr\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(trimmed).toList(growable: false);
    if (rowMatches.isEmpty) {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.noRows,
      );
    }
    if (rowMatches.length > maxRowCount) {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.tooManyRows,
      );
    }

    final rows = <List<RichContent>>[];
    final structureRows = <TableRow>[];
    for (final rowMatch in rowMatches) {
      final rowHtml = rowMatch.group(1) ?? '';
      final cellMatches = RegExp(
        r'<(?:td|th)\b([^>]*)>(.*?)</(?:td|th)\s*>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(rowHtml).toList(growable: false);
      if (cellMatches.isEmpty) {
        return const OcrTableProjectionResult.failure(
          OcrTableProjectionFailureCategory.invalidCells,
        );
      }
      if (cellMatches.length > maxColumnCount) {
        return const OcrTableProjectionResult.failure(
          OcrTableProjectionFailureCategory.tooManyColumns,
        );
      }

      final row = <RichContent>[];
      final structureCells = <TableCell>[];
      for (final cellMatch in cellMatches) {
        final attributes = cellMatch.group(1) ?? '';
        final spans = _parseCellSpans(attributes);
        if (!spans.valid) {
          return const OcrTableProjectionResult.failure(
            OcrTableProjectionFailureCategory.mergedCells,
          );
        }
        final text = _sanitizeCellText(cellMatch.group(2) ?? '');
        row.add(
          text.isEmpty
              ? RichContent(nodes: const <ContentNode>[])
              : RichContent(nodes: <ContentNode>[TextNode(text)]),
        );
        structureCells.add(
          TableCell(
            content: row.last,
            rowSpan: spans.rowSpan,
            columnSpan: spans.columnSpan,
          ),
        );
      }
      rows.add(row);
      structureRows.add(TableRow(cells: structureCells));
    }

    try {
      final structure = TableStructure(rows: structureRows);
      return OcrTableProjectionResult.success(
        SourceTablePart.normalized(
          sourceRef: sourceRef,
          structure: structure,
        ),
      );
    } on FormatException {
      return const OcrTableProjectionResult.failure(
        OcrTableProjectionFailureCategory.sourceTableInvalid,
      );
    }
  }

  static String projectToPlainText(SourceTablePart table) {
    final rows = <String>[];
    for (final row in table.rows) {
      rows.add(row.map(_projectCell).join(' | '));
    }
    return rows.join('\n');
  }

  static String? projectHtmlToPlainText(String html) {
    final table = parseHtmlTable(
      html,
      sourceRef: SourceRef.document(sourceId: 'ocr_table_projection'),
    );
    return table == null ? null : projectToPlainText(table);
  }

  static String _sanitizeCellText(String raw) {
    var text = raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'</?(?:p|div)\b[^>]*>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    text = _decodeHtmlEntities(text);
    return text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
  }

  static _ParsedTableCellSpans _parseCellSpans(String attributes) {
    var rowSpan = 1;
    var columnSpan = 1;
    var rowSpanSeen = false;
    var columnSpanSeen = false;
    for (final match in _htmlAttributePattern.allMatches(attributes)) {
      final name = match.group(1)?.toLowerCase();
      if (name != 'rowspan' && name != 'colspan') continue;

      final value = match.group(2) ?? match.group(3) ?? match.group(4);
      final parsed = value == null ? null : int.tryParse(value.trim());
      if (parsed == null || parsed < 1) {
        return const _ParsedTableCellSpans.invalid();
      }
      if (name == 'rowspan') {
        if (rowSpanSeen) return const _ParsedTableCellSpans.invalid();
        rowSpanSeen = true;
        rowSpan = parsed;
      } else {
        if (columnSpanSeen) return const _ParsedTableCellSpans.invalid();
        columnSpanSeen = true;
        columnSpan = parsed;
      }
    }
    return _ParsedTableCellSpans(
      rowSpan: rowSpan,
      columnSpan: columnSpan,
    );
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '');
      return code != null && code > 0 && code <= 0x10ffff
          ? String.fromCharCode(code)
          : match.group(0) ?? '';
    }).replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '', radix: 16);
      return code != null && code > 0 && code <= 0x10ffff
          ? String.fromCharCode(code)
          : match.group(0) ?? '';
    });
  }

  static String _projectCell(RichContent content) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(text);
        case InlineMathNode(:final latex):
          buffer.write(latex);
        case BlockMathNode(:final latex):
          buffer.write(latex);
        case ImageNode(:final alternativeText):
          buffer.write(
            alternativeText == null ? '[图片]' : _projectRich(alternativeText),
          );
        case TableNode():
        case RawFallbackNode():
          return '';
      }
    }
    return buffer.toString().trim();
  }

  static String _projectRich(RichContent content) {
    return content.nodes.map((node) {
      return switch (node) {
        TextNode(:final text) => text,
        InlineMathNode(:final latex) => latex,
        BlockMathNode(:final latex) => latex,
        ImageNode() => '[图片]',
        TableNode() => '[表格]',
        RawFallbackNode() => '',
      };
    }).join();
  }
}

final class _ParsedTableCellSpans {
  const _ParsedTableCellSpans({
    required this.rowSpan,
    required this.columnSpan,
  }) : valid = true;

  const _ParsedTableCellSpans.invalid()
      : valid = false,
        rowSpan = 1,
        columnSpan = 1;

  final bool valid;
  final int rowSpan;
  final int columnSpan;
}

final _htmlAttributePattern = RegExp(
  r"""([A-Za-z][A-Za-z0-9:-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?""",
  caseSensitive: false,
);
