import 'content_node.dart';
import 'rich_content.dart';
import 'rich_content_limits.dart';

/// Safe, bounded text-only compatibility projection for typed content.
///
/// This projection intentionally drops unsupported fallback payloads and
/// never exposes image identity or table metadata.
final class RichContentTextProjection {
  const RichContentTextProjection();

  String project(RichContent content) {
    final buffer = StringBuffer();
    _appendContent(content, buffer);
    return buffer.toString();
  }

  void _appendContent(RichContent content, StringBuffer buffer) {
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          _append(text, buffer);
        case InlineMathNode(:final latex):
          _append(latex, buffer);
        case BlockMathNode(:final latex):
          _append(latex, buffer);
        case ImageNode(:final alternativeText):
          final alt = alternativeText == null ? '' : project(alternativeText);
          _append(alt.trim().isEmpty ? '[图片]' : alt, buffer);
        case TableNode(:final structure):
          for (var rowIndex = 0;
              rowIndex < structure.expandedCells.length;
              rowIndex++) {
            if (rowIndex != 0) _append('\n', buffer);
            final row = structure.expandedCells[rowIndex];
            for (var columnIndex = 0; columnIndex < row.length; columnIndex++) {
              if (columnIndex != 0) _append(' | ', buffer);
              final cell = row[columnIndex];
              if (cell != null) _appendContent(cell.content, buffer);
            }
          }
        case RawFallbackNode():
          break;
      }
    }
  }

  void _append(String value, StringBuffer buffer) {
    buffer.write(value);
    if (buffer.toString().runes.length >
        RichContentLimits.maxProjectionScalars) {
      throw const FormatException('RichContent projection limit exceeded.');
    }
  }
}
