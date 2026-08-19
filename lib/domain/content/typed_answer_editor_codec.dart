import 'content_node.dart';
import 'rich_content.dart';

/// Result of one typed editor codec operation. The codec is the pure
/// typed-editor boundary between a `RichContent` answer and the editable
/// text field; it never touches the V1 compatibility projection or the
/// persistence mapper.
sealed class TypedAnswerEditorCodecResult {
  const TypedAnswerEditorCodecResult();
}

/// Lossless editable text form produced by [TypedAnswerEditorCodec.encode].
final class TypedAnswerEditorText extends TypedAnswerEditorCodecResult {
  const TypedAnswerEditorText(this.text);

  final String text;
}

/// Structural content produced by [TypedAnswerEditorCodec.decode]. The
/// content may be explicitly empty (`RichContent` with zero nodes), which is
/// distinct from a null answer.
final class TypedAnswerEditorContent extends TypedAnswerEditorCodecResult {
  const TypedAnswerEditorContent(this.content);

  final RichContent content;
}

/// Safe failure for content that cannot enter the current text editor
/// without loss (raw fallback nodes, images, blank runs, parse errors). The
/// message is fixed and redacted; unsupported content is never flattened
/// into a display string and never silently dropped.
final class TypedAnswerEditorUnsupported extends TypedAnswerEditorCodecResult {
  const TypedAnswerEditorUnsupported();

  static const String _message =
      'The typed answer contains unsupported content.';

  @override
  String toString() => _message;
}

/// Pure-Dart lossless typed editor boundary.
///
/// [encode] converts supported `RichContent` nodes into an editable text
/// form that escapes every math-significant sequence inside `TextNode`
/// text (`\` -> `\\`, `$` -> `\$`) so literal user text such as `$x$`,
/// `\(x\)` or `\[x\]` survives a save without semantic change. [decode]
/// parses the editable text back into structural nodes: unescaped `$...$`,
/// `$$...$$`, `\(...\)` and `\[...\]` become math nodes, `\\` and `\$` are
/// literal escapes, and ordinary text (including `<think>` blocks) becomes
/// plain `TextNode` content. The codec never re-parses persisted text nodes
/// at render time and never produces `RawFallbackNode`.
///
/// Round-trip guarantee for supported content: `decode(encode(x)) == x`.
final class TypedAnswerEditorCodec {
  const TypedAnswerEditorCodec._();

  static TypedAnswerEditorCodecResult encode(RichContent content) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(_escapeText(text));
        case InlineMathNode(:final latex):
          buffer.write(r'\(');
          buffer.write(latex);
          buffer.write(r'\)');
        case BlockMathNode(:final latex):
          buffer.write(r'\[');
          buffer.write(latex);
          buffer.write(r'\]');
        case ImageNode():
          return const TypedAnswerEditorUnsupported();
        case RawFallbackNode():
          return const TypedAnswerEditorUnsupported();
      }
    }
    return TypedAnswerEditorText(buffer.toString());
  }

  static TypedAnswerEditorCodecResult decode(String input) {
    final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final nodes = <ContentNode>[];
    final textBuffer = StringBuffer();
    var index = 0;

    void flushText() {
      if (textBuffer.isEmpty) return;
      nodes.add(TextNode(textBuffer.toString()));
      textBuffer.clear();
    }

    while (index < normalized.length) {
      if (_startsWith(normalized, index, r'\\')) {
        textBuffer.write(r'\');
        index += 2;
        continue;
      }
      if (_startsWith(normalized, index, r'\$')) {
        textBuffer.write(r'$');
        index += 2;
        continue;
      }
      if (_startsWith(normalized, index, r'$$')) {
        final close = _findDollarClose(normalized, index + 2, block: true);
        if (close == -1) {
          textBuffer.write(r'$$');
          index += 2;
          continue;
        }
        flushText();
        nodes.add(BlockMathNode(normalized.substring(index + 2, close)));
        index = close + 2;
        continue;
      }
      if (normalized[index] == r'$') {
        final close = _findDollarClose(normalized, index + 1, block: false);
        if (close == -1) {
          textBuffer.write(r'$');
          index++;
          continue;
        }
        flushText();
        nodes.add(InlineMathNode(normalized.substring(index + 1, close)));
        index = close + 1;
        continue;
      }
      if (_startsWith(normalized, index, r'\(')) {
        final end = _findClosingDelimiter(normalized, index + 2, r'\)');
        if (end == -1) return const TypedAnswerEditorUnsupported();
        flushText();
        nodes.add(InlineMathNode(normalized.substring(index + 2, end)));
        index = end + 2;
        continue;
      }
      if (_startsWith(normalized, index, r'\[')) {
        final end = _findClosingDelimiter(normalized, index + 2, r'\]');
        if (end == -1) return const TypedAnswerEditorUnsupported();
        flushText();
        nodes.add(BlockMathNode(normalized.substring(index + 2, end)));
        index = end + 2;
        continue;
      }
      if (_isImageStart(normalized, index)) {
        return const TypedAnswerEditorUnsupported();
      }
      if (normalized[index] == '_') {
        var end = index;
        while (end < normalized.length && normalized[end] == '_') {
          end++;
        }
        if (end - index >= 3) {
          return const TypedAnswerEditorUnsupported();
        }
      }
      textBuffer.write(normalized[index]);
      index++;
    }

    flushText();
    return TypedAnswerEditorContent(RichContent(nodes: nodes));
  }

  /// Escapes math-significant syntax inside plain text so the editable form
  /// can round-trip losslessly. Backslashes are escaped first so `\(` and
  /// `\[` in text never become math delimiters on decode.
  static String _escapeText(String text) {
    final buffer = StringBuffer();
    for (final char in text.split('')) {
      switch (char) {
        case r'\':
          buffer.write(r'\\');
        case r'$':
          buffer.write(r'\$');
        default:
          buffer.write(char);
      }
    }
    return buffer.toString();
  }

  /// Finds the closing unescaped `$` (inline) or `$$` (block). Escaped
  /// sequences (`\\`, `\$`) never close a math span; an inline span cannot
  /// cross a newline.
  static int _findDollarClose(
    String input,
    int start, {
    required bool block,
  }) {
    var index = start;
    while (index < input.length) {
      if (_startsWith(input, index, r'\\') ||
          _startsWith(input, index, r'\$')) {
        index += 2;
        continue;
      }
      if (!block && input[index] == '\n') return -1;
      if (block && _startsWith(input, index, r'$$')) return index;
      if (!block && input[index] == r'$') return index;
      index++;
    }
    return -1;
  }

  /// Finds the matching closing delimiter with the same nesting rule as the
  /// renderer tokenizer: a nested opening delimiter inside math keeps the
  /// depth positive, and an unmatched closing delimiter outside math is
  /// ordinary text. Delimiter-like LaTeX whose backslash is itself escaped
  /// (for example `\\[2mm]` inside a block formula) is literal math content
  /// and never opens or closes a span.
  static int _findClosingDelimiter(String input, int start, String close) {
    final open = close == r'\)' ? r'\(' : r'\[';
    var depth = 0;
    var index = start;
    while (index <= input.length - close.length) {
      if (_startsWith(input, index, close)) {
        if (!_isEscapedBackslash(input, index)) {
          if (depth == 0) return index;
          depth--;
        }
        index += close.length;
        continue;
      }
      if (_startsWith(input, index, open)) {
        if (!_isEscapedBackslash(input, index)) {
          depth++;
        }
        index += open.length;
        continue;
      }
      index++;
    }
    return -1;
  }

  /// True when the backslash at [index] is itself escaped by a preceding
  /// backslash run of odd length (for example the second backslash in
  /// `\\[`). Such a delimiter-like sequence is literal LaTeX content.
  static bool _isEscapedBackslash(String input, int index) {
    var count = 0;
    var i = index - 1;
    while (i >= 0 && input[i] == r'\') {
      count++;
      i--;
    }
    return count.isOdd;
  }

  /// A complete markdown image (`![alt](scheme:...)`) is unsupported in
  /// typed answers; it is never flattened into text.
  static bool _isImageStart(String input, int start) {
    if (!_startsWith(input, start, '![')) return false;
    final altEnd = input.indexOf(']', start + 2);
    if (altEnd == -1 ||
        altEnd + 1 >= input.length ||
        input[altEnd + 1] != '(') {
      return false;
    }
    final urlEnd = input.indexOf(')', altEnd + 2);
    if (urlEnd == -1) return false;
    final urlText = input.substring(altEnd + 2, urlEnd).trim();
    if (urlText.isEmpty) return false;
    final uri = Uri.tryParse(urlText);
    return uri != null && uri.hasScheme;
  }

  static bool _startsWith(String input, int index, String needle) {
    if (index < 0 || index + needle.length > input.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (input.codeUnitAt(index + i) != needle.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }
}
