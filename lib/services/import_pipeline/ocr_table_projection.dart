import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';
import 'latex_renderability_checker.dart';
import 'ocr_rich_content_parser.dart';

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
    OcrMathSourceMap? mathSourceMap,
  }) {
    if (html.length > maxInputLength) return null;
    final trimmed = html.trim();
    final tableHtml = _singleTableHtml(trimmed);
    if (tableHtml == null ||
        RegExp(
          r'<\s*(?:script|style|img|a|iframe|object|embed|audio|video|source|form|input|button|link|meta)\b',
          caseSensitive: false,
        ).hasMatch(tableHtml) ||
        RegExp(
          r'\b(?:src|href|on[a-z]+)\s*=',
          caseSensitive: false,
        ).hasMatch(tableHtml)) {
      return null;
    }

    final rowPattern = RegExp(
      r'<tr\b[^>]*>(.*?)</tr\s*>',
      caseSensitive: false,
      dotAll: true,
    );
    final rowMatches = rowPattern.allMatches(tableHtml).toList(growable: false);
    if (rowMatches.isEmpty || rowMatches.length > maxRowCount) return null;
    if (_tagCount(tableHtml, 'tr') != rowMatches.length * 2) return null;

    final structureRows = <TableRow>[];
    for (final rowMatch in rowMatches) {
      final rowHtml = rowMatch.group(1) ?? '';
      final cellPattern = RegExp(
        r'<(td|th)\b([^>]*)>(.*?)</\1\s*>',
        caseSensitive: false,
        dotAll: true,
      );
      final cellMatches =
          cellPattern.allMatches(rowHtml).toList(growable: false);
      if (cellMatches.isEmpty || cellMatches.length > maxColumnCount) {
        return null;
      }
      if (_tagCount(rowHtml, 'td') + _tagCount(rowHtml, 'th') !=
          cellMatches.length * 2) {
        return null;
      }

      final cells = <TableCell>[];
      for (final cellMatch in cellMatches) {
        final spans = _parseCellSpans(cellMatch.group(2) ?? '');
        if (!spans.valid) return null;
        final text = _sanitizeCellText(cellMatch.group(3) ?? '');
        final RichContent content;
        if (text.isEmpty) {
          content = RichContent(nodes: const <ContentNode>[]);
        } else if (mathSourceMap != null) {
          if (_hasExplicitMathDelimiters(text)) {
            content = mathSourceMap.parse(text);
          } else if (_isBareMathCandidate(text)) {
            content = mathSourceMap.parse(text, formula: true);
          } else {
            content = RichContent(nodes: <ContentNode>[TextNode(text)]);
          }
        } else {
          content = RichContent(nodes: <ContentNode>[TextNode(text)]);
        }
        cells.add(
          TableCell(
            content: content,
            rowSpan: spans.rowSpan,
            columnSpan: spans.columnSpan,
          ),
        );
      }
      structureRows.add(TableRow(cells: cells));
    }

    try {
      return SourceTablePart.normalized(
        sourceRef: sourceRef,
        structure: TableStructure(rows: structureRows),
      );
    } on FormatException {
      return null;
    }
  }

  static String projectToPlainText(
    SourceTablePart table, {
    OcrMathSourceMap? mathSourceMap,
  }) {
    final rows = <String>[];
    final structure = table.structure;
    if (structure != null) {
      for (final row in structure.expandedCells) {
        rows.add(
          row
              .map((cell) => cell == null
                  ? ''
                  : _projectCell(cell.content, mathSourceMap: mathSourceMap))
              .join(' | '),
        );
      }
    } else {
      for (final row in table.rows) {
        rows.add(
          row
              .map((cell) => _projectCell(cell, mathSourceMap: mathSourceMap))
              .join(' | '),
        );
      }
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

  static String? _singleTableHtml(String html) {
    final matches = RegExp(
      r'<\s*(/?)\s*table\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html).toList(growable: false);
    if (matches.length != 2 ||
        (matches.first.group(1) ?? '').isNotEmpty ||
        (matches.last.group(1) ?? '').isEmpty ||
        matches.first.start >= matches.last.start ||
        html.substring(0, matches.first.start).trim().isNotEmpty ||
        html.substring(matches.last.end).trim().isNotEmpty) {
      return null;
    }
    return html.substring(matches.first.start, matches.last.end);
  }

  static int _tagCount(String html, String tag) {
    return RegExp(
      '<\\s*/?\\s*$tag\\b',
      caseSensitive: false,
    ).allMatches(html).length;
  }

  static _ParsedTableCellSpans _parseCellSpans(String attributes) {
    var rowSpan = 1;
    var columnSpan = 1;
    var rowSpanSeen = false;
    var columnSpanSeen = false;
    var parsedSpanCount = 0;
    for (final match in _htmlAttributePattern.allMatches(attributes)) {
      final name = match.group(1)?.toLowerCase();
      if (name != 'rowspan' && name != 'colspan') continue;
      parsedSpanCount++;
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
    final mentionedSpanCount = RegExp(
      r'\b(?:rowspan|colspan)\b',
      caseSensitive: false,
    ).allMatches(attributes).length;
    if (parsedSpanCount != mentionedSpanCount) {
      return const _ParsedTableCellSpans.invalid();
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

  static String _projectCell(
    RichContent content, {
    OcrMathSourceMap? mathSourceMap,
  }) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(text);
        case InlineMathNode(:final latex):
          buffer.write(mathSourceMap?.rawMath(node) ?? latex);
        case BlockMathNode(:final latex):
          buffer.write(mathSourceMap?.rawMath(node) ?? latex);
        case ImageNode(:final alternativeText):
          buffer.write(
            alternativeText == null
                ? '[图片]'
                : _projectRich(alternativeText, mathSourceMap: mathSourceMap),
          );
        case TableNode():
        case RawFallbackNode():
          return '';
      }
    }
    return buffer.toString().trim();
  }

  static String _projectRich(
    RichContent content, {
    OcrMathSourceMap? mathSourceMap,
  }) {
    return content.nodes.map((node) {
      return switch (node) {
        TextNode(:final text) => text,
        InlineMathNode(:final latex) => mathSourceMap?.rawMath(node) ?? latex,
        BlockMathNode(:final latex) => mathSourceMap?.rawMath(node) ?? latex,
        ImageNode() => '[图片]',
        TableNode() => '[表格]',
        RawFallbackNode() => '',
      };
    }).join();
  }

  static bool _hasExplicitMathDelimiters(String text) {
    return text.contains(r'$') || text.contains(r'\(') || text.contains(r'\[');
  }

  static bool _isBareMathCandidate(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (RegExp(r'[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]')
        .hasMatch(trimmed)) {
      return false;
    }
    if (RegExp(
      r'\b(?:the|and|or|for|if|with|in|of|to|is|are|let|where|when|definition|note|table|row|column)\b',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return false;
    }
    final hasLatexCommand = RegExp(r'\\[a-zA-Z]+').hasMatch(trimmed);
    final hasMathStructure = (trimmed.contains('=') ||
            trimmed.contains(r'\leqslant') ||
            trimmed.contains(r'\geqslant')) &&
        (trimmed.contains('^') ||
            trimmed.contains('_') ||
            trimmed.contains('{'));
    if (!hasLatexCommand && !hasMathStructure) {
      return false;
    }
    const checker = LatexRenderabilityChecker();
    return checker.check(trimmed, assumeMathContext: true).isRenderable;
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
  r'''([A-Za-z][A-Za-z0-9:-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?''',
  caseSensitive: false,
);
