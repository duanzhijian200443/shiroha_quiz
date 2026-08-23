import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';

/// Deterministic, bounded adapter for the provider's HTML table block.
///
/// HTML is an input representation only. It is never stored in a
/// [SourceTablePart] or used as the canonical legacy projection. Unsupported
/// markup, merged-cell geometry, and malformed tables fail closed.
final class OcrTableProjector {
  const OcrTableProjector._();

  static const int maxInputLength = 100000;
  static const int maxRowCount = 200;
  static const int maxColumnCount = 50;

  static SourceTablePart? parseHtmlTable(
    String html, {
    required SourceRef sourceRef,
  }) {
    if (html.length > maxInputLength) return null;
    final trimmed = html.trim();
    if (!RegExp(r'<table\b', caseSensitive: false).hasMatch(trimmed) ||
        RegExp(
          r'<(?:script|style)\b',
          caseSensitive: false,
        ).hasMatch(trimmed) ||
        RegExp(
          r'<\s*(?:img|a)\b|\b(?:src|href)\s*=',
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return null;
    }

    final rowMatches = RegExp(
      r'<tr\b[^>]*>(.*?)</tr\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(trimmed).toList(growable: false);
    if (rowMatches.isEmpty || rowMatches.length > maxRowCount) return null;

    final rows = <List<RichContent>>[];
    for (final rowMatch in rowMatches) {
      final rowHtml = rowMatch.group(1) ?? '';
      final cellMatches = RegExp(
        r'<(?:td|th)\b([^>]*)>(.*?)</(?:td|th)\s*>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(rowHtml).toList(growable: false);
      if (cellMatches.isEmpty || cellMatches.length > maxColumnCount) {
        return null;
      }

      final row = <RichContent>[];
      for (final cellMatch in cellMatches) {
        final attributes = cellMatch.group(1) ?? '';
        if (RegExp(
          r'\b(?:rowspan|colspan)\s*=',
          caseSensitive: false,
        ).hasMatch(attributes)) {
          return null;
        }
        final text = _sanitizeCellText(cellMatch.group(2) ?? '');
        row.add(
          text.isEmpty
              ? RichContent(nodes: const <ContentNode>[])
              : RichContent(nodes: <ContentNode>[TextNode(text)]),
        );
      }
      rows.add(row);
    }

    try {
      return SourceTablePart(sourceRef: sourceRef, rows: rows);
    } on FormatException {
      return null;
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
