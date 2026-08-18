import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';

/// Pure, deterministic utility for parsing GLM-OCR HTML tables into
/// [SourceTablePart] and projecting them losslessly to safe plain text.
///
/// Ensures no raw HTML (`<table>`, `<tr>`, `<td>`, `<th>`) enters [RichContent]
/// or legacy projection maps, prevents script/style execution, decodes common
/// HTML entities, and enforces bounding limits.
final class OcrTableProjector {
  const OcrTableProjector._();

  static const int maxInputLength = 100000;
  static const int maxRowCount = 200;
  static const int maxColumnCount = 50;

  /// Parses a GLM-OCR HTML table into a validated [SourceTablePart].
  ///
  /// Returns `null` if the input is not a well-formed table, exceeds safety
  /// limits, or contains zero valid cells.
  static SourceTablePart? parseHtmlTable(
    String html, {
    required SourceRef sourceRef,
  }) {
    if (html.length > maxInputLength) return null;

    final trimmed = html.trim();
    if (!trimmed.contains(RegExp(r'<table\b', caseSensitive: false))) {
      return null;
    }

    final rowRegex = RegExp(
      r'<tr\b[^>]*>(.*?)<\/tr>',
      caseSensitive: false,
      dotAll: true,
    );
    final cellRegex = RegExp(
      r'<(?:td|th)\b[^>]*>(.*?)<\/(?:td|th)>',
      caseSensitive: false,
      dotAll: true,
    );

    final rowMatches = rowRegex.allMatches(trimmed).toList();
    if (rowMatches.isEmpty || rowMatches.length > maxRowCount) {
      return null;
    }

    final parsedRows = <List<RichContent>>[];
    for (final rowMatch in rowMatches) {
      final rowHtml = rowMatch.group(1) ?? '';
      final cellMatches = cellRegex.allMatches(rowHtml).toList();
      if (cellMatches.isEmpty) continue;
      if (cellMatches.length > maxColumnCount) return null;

      final parsedRow = <RichContent>[];
      for (final cellMatch in cellMatches) {
        final rawCellContent = cellMatch.group(1) ?? '';
        final cleanText = _sanitizeCellText(rawCellContent);
        parsedRow.add(_cellToRichContent(cleanText));
      }
      if (parsedRow.isNotEmpty) {
        parsedRows.add(parsedRow);
      }
    }

    if (parsedRows.isEmpty) return null;

    try {
      return SourceTablePart(
        sourceRef: sourceRef,
        rows: parsedRows,
      );
    } catch (_) {
      return null;
    }
  }

  /// Projects a [SourceTablePart] to deterministic, safe plain text.
  ///
  /// Rows are joined by newlines, and cells within each row are joined by `' | '`.
  /// Guaranteed to be free of any HTML tags.
  static String projectToPlainText(SourceTablePart table) {
    final buffer = StringBuffer();
    for (var rowIndex = 0; rowIndex < table.rows.length; rowIndex++) {
      if (rowIndex > 0) buffer.writeln();
      final row = table.rows[rowIndex];
      for (var colIndex = 0; colIndex < row.length; colIndex++) {
        if (colIndex > 0) buffer.write(' | ');
        final cell = row[colIndex];
        buffer.write(_extractCellText(cell));
      }
    }
    return buffer.toString();
  }

  /// Convenience method to parse an HTML table and project it directly to plain text.
  ///
  /// Returns `null` if the HTML table is invalid or cannot be parsed.
  static String? projectHtmlToPlainText(String html) {
    final parsed = parseHtmlTable(
      html,
      sourceRef: SourceRef.document(sourceId: 'synthetic_table'),
    );
    if (parsed == null) return null;
    return projectToPlainText(parsed);
  }

  static String _sanitizeCellText(String raw) {
    // 1. Replace <br>, <br/>, <p>, </p>, <div>, </div> with space/newline
    var text = raw
        .replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'<\/?(?:p|div)\b[^>]*>', caseSensitive: false), ' ');

    // 2. Strip any remaining nested tags (e.g. <span>, <b>, <i>, etc.)
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // 3. Decode HTML entities
    text = _decodeHtmlEntities(text);

    // 4. Collapse consecutive whitespace within lines while preserving meaningful text
    return text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
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
        .replaceAll(r'&ldquo;', '“')
        .replaceAll(r'&rdquo;', '”')
        .replaceAll(r'&lsquo;', '‘')
        .replaceAll(r'&rsquo;', '’')
        .replaceAll(r'&mdash;', '—')
        .replaceAll(r'&ndash;', '–')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '');
      if (code != null && code > 0 && code <= 0x10FFFF) {
        return String.fromCharCode(code);
      }
      return match.group(0) ?? '';
    }).replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
      final code = int.tryParse(match.group(1) ?? '', radix: 16);
      if (code != null && code > 0 && code <= 0x10FFFF) {
        return String.fromCharCode(code);
      }
      return match.group(0) ?? '';
    });
  }

  static RichContent _cellToRichContent(String text) {
    if (text.isEmpty) {
      return RichContent(nodes: const <ContentNode>[]);
    }
    return RichContent(nodes: <ContentNode>[TextNode(text)]);
  }

  static String _extractCellText(RichContent content) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(text);
        case InlineMathNode(:final latex):
          buffer.write(latex);
        case BlockMathNode(:final latex):
          buffer.write(latex);
        case ImageNode(:final altText):
          buffer.write(altText ?? '[图片]');
        case RawFallbackNode():
          break;
      }
    }
    return buffer.toString().trim();
  }
}
