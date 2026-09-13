sealed class LatexMathSpanToken {
  const LatexMathSpanToken();
}

final class LatexTextSpanToken extends LatexMathSpanToken {
  const LatexTextSpanToken(this.text);

  final String text;
}

final class LatexInlineMathSpanToken extends LatexMathSpanToken {
  const LatexInlineMathSpanToken({required this.latex, required this.raw});

  final String latex;
  final String raw;
}

final class LatexBlockMathSpanToken extends LatexMathSpanToken {
  const LatexBlockMathSpanToken({required this.latex, required this.raw});

  final String latex;
  final String raw;
}

typedef LatexMathSpan = ({int start, int end, LatexMathSpanToken token});

/// Lossless scanner for the explicit math delimiters used by review repair.
///
/// This intentionally owns only text/math span alignment. It does not parse
/// Markdown images, blanks, or general rich content.
final class LatexMathSpanScanner {
  const LatexMathSpanScanner._();

  static List<LatexMathSpan> scan(String input) {
    final result = <LatexMathSpan>[];
    var textStart = 0;
    var index = 0;

    bool escaped(int at) {
      var count = 0;
      for (var cursor = at - 1;
          cursor >= 0 && input[cursor] == r'\';
          cursor--) {
        count++;
      }
      return count.isOdd;
    }

    String? delimiter(int at) {
      if (escaped(at)) return null;
      for (final value in <String>[
        r'$$',
        r'\(',
        r'\[',
        r'\)',
        r'\]',
        r'$',
      ]) {
        if (_startsWith(input, at, value)) return value;
      }
      return null;
    }

    while (index < input.length) {
      final open = delimiter(index);
      if (open == null) {
        index++;
        continue;
      }
      if (open == r'\)' || open == r'\]') break;
      final close = switch (open) {
        r'\(' => r'\)',
        r'\[' => r'\]',
        _ => open,
      };
      var end = index + open.length;
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
      final latex = input.substring(index + open.length, end);
      if (latex.trim().isEmpty) break;
      if (index > textStart) {
        result.add((
          start: textStart,
          end: index,
          token: LatexTextSpanToken(input.substring(textStart, index)),
        ));
      }
      final stop = end + close.length;
      final raw = input.substring(index, stop);
      result.add((
        start: index,
        end: stop,
        token: open == r'$$' || open == r'\['
            ? LatexBlockMathSpanToken(latex: latex, raw: raw)
            : LatexInlineMathSpanToken(latex: latex, raw: raw),
      ));
      index = stop;
      textStart = stop;
    }
    if (textStart < input.length) {
      result.add((
        start: textStart,
        end: input.length,
        token: LatexTextSpanToken(input.substring(textStart)),
      ));
    }
    return result;
  }

  static bool _startsWith(String input, int index, String needle) {
    if (index < 0 || index + needle.length > input.length) return false;
    for (var offset = 0; offset < needle.length; offset++) {
      if (input.codeUnitAt(index + offset) != needle.codeUnitAt(offset)) {
        return false;
      }
    }
    return true;
  }
}
