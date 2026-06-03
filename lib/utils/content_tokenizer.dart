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

  static int _findClosingDelimiter(String input, int start, String close) {
    var i = start;
    while (i <= input.length - close.length) {
      if (_startsWith(input, i, close)) return i;
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
