sealed class ContentToken {
  const ContentToken();
}

class TextToken extends ContentToken {
  final String text;

  const TextToken(this.text);
}

class InlineMathToken extends ContentToken {
  final String tex;
  final String raw;

  const InlineMathToken({required this.tex, required this.raw});
}

class BlockMathToken extends ContentToken {
  final String tex;
  final String raw;

  const BlockMathToken({required this.tex, required this.raw});
}

class BlankToken extends ContentToken {
  final int length;

  const BlankToken(this.length);
}

class ImageToken extends ContentToken {
  final Uri uri;
  final String? alt;
  final String raw;

  const ImageToken({required this.uri, required this.raw, this.alt});
}

class ParseErrorToken extends ContentToken {
  final String raw;
  final String reason;

  const ParseErrorToken({required this.raw, required this.reason});
}

class ContentTokenizer {
  const ContentTokenizer._();

  /// Lossless OCR math scan. Unlike [tokenize], this does not recognize images
  /// or blanks and does not require normalization of the input.
  static List<({int start, int end, ContentToken token})> tokenizeMathSpans(
      String input) {
    final result = <({int start, int end, ContentToken token})>[];
    var textStart = 0;
    var i = 0;
    bool escaped(int at) {
      var count = 0;
      for (var j = at - 1; j >= 0 && input[j] == r'\'; j--) {
        count++;
      }
      return count.isOdd;
    }

    String? delimiter(int at) {
      if (escaped(at)) return null;
      for (final value in [r'$$', r'\(', r'\[', r'\)', r'\]', r'$']) {
        if (_startsWith(input, at, value)) return value;
      }
      return null;
    }

    while (i < input.length) {
      final open = delimiter(i);
      if (open == null) {
        i++;
        continue;
      }
      if (open == r'\)' || open == r'\]') break;
      final close = switch (open) {
        r'\(' => r'\)',
        r'\[' => r'\]',
        _ => open,
      };
      var end = i + open.length;
      var found = false;
      while (end < input.length) {
        if (open == r'$' && (input[end] == '\n' || input[end] == '\r')) {
          break;
        }
        final next = delimiter(end);
        if (next != null) {
          if (next == close &&
              !(open == r'$' &&
                  end + 1 < input.length &&
                  RegExp(r'[0-9]').hasMatch(input[end + 1]))) {
            found = true;
          }
          break;
        }
        end++;
      }
      if (!found) break;
      final latex = input.substring(i + open.length, end);
      if (latex.trim().isEmpty) break;
      if (i > textStart) {
        result.add((
          start: textStart,
          end: i,
          token: TextToken(input.substring(textStart, i))
        ));
      }
      final stop = end + close.length;
      final raw = input.substring(i, stop);
      result.add((
        start: i,
        end: stop,
        token: open == r'$$' || open == r'\['
            ? BlockMathToken(tex: latex, raw: raw)
            : InlineMathToken(tex: latex, raw: raw)
      ));
      i = stop;
      textStart = stop;
    }
    if (textStart < input.length) {
      result.add((
        start: textStart,
        end: input.length,
        token: TextToken(input.substring(textStart))
      ));
    }
    return result;
  }

  static List<ContentToken> tokenize(String input) {
    if (input.isEmpty) return const <ContentToken>[];

    final tokens = <ContentToken>[];
    final textBuffer = StringBuffer();

    void flushText() {
      if (textBuffer.isEmpty) return;
      tokens.add(TextToken(textBuffer.toString()));
      textBuffer.clear();
    }

    var i = 0;
    while (i < input.length) {
      if (_startsWith(input, i, r'\(')) {
        final end = _findClosingDelimiter(input, i + 2, r'\)');
        flushText();
        if (end == -1) {
          tokens.add(ParseErrorToken(
            raw: input.substring(i),
            reason: r'Missing closing delimiter \)',
          ));
          break;
        }
        tokens.add(InlineMathToken(
          tex: input.substring(i + 2, end),
          raw: input.substring(i, end + 2),
        ));
        i = end + 2;
        continue;
      }

      if (_startsWith(input, i, r'\[')) {
        final end = _findClosingDelimiter(input, i + 2, r'\]');
        flushText();
        if (end == -1) {
          tokens.add(ParseErrorToken(
            raw: input.substring(i),
            reason: r'Missing closing delimiter \]',
          ));
          break;
        }
        tokens.add(BlockMathToken(
          tex: input.substring(i + 2, end),
          raw: input.substring(i, end + 2),
        ));
        i = end + 2;
        continue;
      }

      final image = _tryParseMarkdownImage(input, i);
      if (image != null) {
        flushText();
        tokens.add(image.token);
        i = image.end;
        continue;
      }

      if (input[i] == '_') {
        final end = _countRun(input, i, '_');
        final length = end - i;
        if (length >= 3) {
          flushText();
          tokens.add(BlankToken(length));
          i = end;
          continue;
        }
      }

      textBuffer.write(input[i]);
      i++;
    }

    flushText();
    return _mergeAdjacentText(tokens);
  }

  static List<ContentToken> _mergeAdjacentText(List<ContentToken> tokens) {
    final merged = <ContentToken>[];
    final textBuffer = StringBuffer();

    void flush() {
      if (textBuffer.isEmpty) return;
      merged.add(TextToken(textBuffer.toString()));
      textBuffer.clear();
    }

    for (final token in tokens) {
      if (token is TextToken) {
        textBuffer.write(token.text);
      } else {
        flush();
        merged.add(token);
      }
    }
    flush();
    return merged;
  }

  static _ImageParseResult? _tryParseMarkdownImage(String input, int start) {
    if (!_startsWith(input, start, '![')) return null;

    final altEnd = input.indexOf(']', start + 2);
    if (altEnd == -1 ||
        altEnd + 1 >= input.length ||
        input[altEnd + 1] != '(') {
      return null;
    }

    final urlEnd = input.indexOf(')', altEnd + 2);
    if (urlEnd == -1) return null;

    final raw = input.substring(start, urlEnd + 1);
    final urlText = input.substring(altEnd + 2, urlEnd).trim();
    if (urlText.isEmpty) return null;

    final uri = Uri.tryParse(urlText);
    if (uri == null || !uri.hasScheme) return null;

    return _ImageParseResult(
      token: ImageToken(
        uri: uri,
        raw: raw,
        alt: input.substring(start + 2, altEnd),
      ),
      end: urlEnd + 1,
    );
  }

  /// Finds the position of [close] in [input] starting at [start], accounting
  /// for nested opening delimiters so that `\(\( … \)\)` is handled correctly.
  ///
  /// For `\)` the matching opener is `\(`; for `\]` the matching opener is
  /// `\[`. Any other [close] string uses a simple linear scan (no depth).
  static int _findClosingDelimiter(String input, int start, String close) {
    final String? open;
    if (close == r'\)') {
      open = r'\(';
    } else if (close == r'\]') {
      open = r'\[';
    } else {
      open = null;
    }

    var depth = 0;
    var i = start;
    while (i <= input.length - close.length) {
      if (_startsWith(input, i, close)) {
        if (depth == 0) return i;
        depth--;
        i += close.length;
        continue;
      }

      if (open != null && _startsWith(input, i, open)) {
        depth++;
        i += open.length;
        continue;
      }

      i++;
    }
    return -1;
  }

  static int _countRun(String input, int start, String char) {
    var i = start;
    while (i < input.length && input[i] == char) {
      i++;
    }
    return i;
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

class _ImageParseResult {
  final ImageToken token;
  final int end;

  const _ImageParseResult({required this.token, required this.end});
}
