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
      for (final cellMatch in cellMatches) {
        final attributes = cellMatch.group(1) ?? '';
        if (RegExp(
          r'\b(?:rowspan|colspan)\s*=',
          caseSensitive: false,
        ).hasMatch(attributes)) {
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
      }
      rows.add(row);
    }

    try {
      return OcrTableProjectionResult.success(
        SourceTablePart(sourceRef: sourceRef, rows: rows),
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
