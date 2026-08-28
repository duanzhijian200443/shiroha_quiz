import '../../core/observability/app_logger.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';

enum _OcrTableProjectionSubtype {
  inputTooLarge,
  tableMissing,
  unsafeMarkup,
  rowsMissing,
  rowLimit,
  cellsMissing,
  columnLimit,
  mergedCellGeometry,
  sourceTableInvalid,
}

String _ocrTableProjectionSubtypeValue(_OcrTableProjectionSubtype subtype) {
  return switch (subtype) {
    _OcrTableProjectionSubtype.inputTooLarge => 'input_too_large',
    _OcrTableProjectionSubtype.tableMissing => 'table_missing',
    _OcrTableProjectionSubtype.unsafeMarkup => 'unsafe_markup',
    _OcrTableProjectionSubtype.rowsMissing => 'rows_missing',
    _OcrTableProjectionSubtype.rowLimit => 'row_limit',
    _OcrTableProjectionSubtype.cellsMissing => 'cells_missing',
    _OcrTableProjectionSubtype.columnLimit => 'column_limit',
    _OcrTableProjectionSubtype.mergedCellGeometry => 'merged_cell_geometry',
    _OcrTableProjectionSubtype.sourceTableInvalid => 'source_table_invalid',
  };
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
    return _parseHtmlTable(
      html,
      sourceRef: sourceRef,
      emitTelemetry: true,
    );
  }

  static SourceTablePart? _parseHtmlTable(
    String html, {
    required SourceRef sourceRef,
    required bool emitTelemetry,
  }) {
    SourceTablePart? reject(_OcrTableProjectionSubtype subtype) {
      if (emitTelemetry) {
        try {
          AppLogger.info(
            'OCR table projection rejected',
            module: 'Ocr',
            data: <String, Object?>{
              'stage': 'table_projection',
              'status': 'rejected',
              'tableProjectionSubtype':
                  _ocrTableProjectionSubtypeValue(subtype),
              'count': 1,
            },
          );
        } on Object {
          // Telemetry must never affect the original projection result.
        }
      }
      return null;
    }

    if (html.length > maxInputLength) {
      return reject(_OcrTableProjectionSubtype.inputTooLarge);
    }
    final trimmed = html.trim();
    if (!RegExp(r'<table\b', caseSensitive: false).hasMatch(trimmed)) {
      return reject(_OcrTableProjectionSubtype.tableMissing);
    }
    if (RegExp(
          r'<(?:script|style)\b',
          caseSensitive: false,
        ).hasMatch(trimmed) ||
        RegExp(
          r'<\s*(?:img|a)\b|\b(?:src|href)\s*=',
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return reject(_OcrTableProjectionSubtype.unsafeMarkup);
    }

    final rowMatches = RegExp(
      r'<tr\b[^>]*>(.*?)</tr\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(trimmed).toList(growable: false);
    if (rowMatches.isEmpty) {
      return reject(_OcrTableProjectionSubtype.rowsMissing);
    }
    if (rowMatches.length > maxRowCount) {
      return reject(_OcrTableProjectionSubtype.rowLimit);
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
        return reject(_OcrTableProjectionSubtype.cellsMissing);
      }
      if (cellMatches.length > maxColumnCount) {
        return reject(_OcrTableProjectionSubtype.columnLimit);
      }

      final row = <RichContent>[];
      for (final cellMatch in cellMatches) {
        final attributes = cellMatch.group(1) ?? '';
        if (RegExp(
          r'\b(?:rowspan|colspan)\s*=',
          caseSensitive: false,
        ).hasMatch(attributes)) {
          return reject(_OcrTableProjectionSubtype.mergedCellGeometry);
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
      return reject(_OcrTableProjectionSubtype.sourceTableInvalid);
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
    final table = _parseHtmlTable(
      html,
      sourceRef: SourceRef.document(sourceId: 'ocr_table_projection'),
      emitTelemetry: false,
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
