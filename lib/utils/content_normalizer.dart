class ContentNormalizer {
  const ContentNormalizer._();

  static const Set<String> _delimiterChars = {'(', ')', '[', ']'};
  static const Set<String> _knownLatexCommands = {
    'begin',
    'end',
    'frac',
    'sqrt',
    'sum',
    'int',
    'lim',
    'left',
    'right',
    'mathrm',
    'mathbf',
    'mathbb',
    'mathcal',
    'text',
    'hat',
    'bar',
    'vec',
    'dot',
    'ddot',
    'overline',
    'underline',
    'xlongequal',
    'overset',
    'underset',
    'alpha',
    'beta',
    'gamma',
    'delta',
    'epsilon',
    'varepsilon',
    'theta',
    'lambda',
    'mu',
    'xi',
    'pi',
    'rho',
    'sigma',
    'phi',
    'omega',
    'Delta',
    'Sigma',
    'Omega',
  };

  static String normalizeForStorage(String input) {
    return _normalize(input, stripThinkBlocks: true);
  }

  static String normalizeForRender(String input) {
    return _normalize(input, stripThinkBlocks: true);
  }

  static List<String> findBareLatexCommands(String input) {
    final commands = <String>[];
    final text = normalizeForRender(input);
    var i = 0;
    while (i < text.length) {
      if (_startsWith(text, i, r'\(')) {
        final end = _findClosingDelimiter(text, i + 2, r'\)');
        i = end == -1 ? text.length : end + 2;
        continue;
      }
      if (_startsWith(text, i, r'\[')) {
        final end = _findClosingDelimiter(text, i + 2, r'\]');
        i = end == -1 ? text.length : end + 2;
        continue;
      }
      if (text.codeUnitAt(i) == 92 && i + 1 < text.length) {
        final start = i + 1;
        var end = start;
        while (end < text.length && _isAsciiLetter(text.codeUnitAt(end))) {
          end++;
        }
        if (end > start) {
          final command = text.substring(start, end);
          if (_knownLatexCommands.contains(command)) {
            commands.add(command);
          }
          i = end;
          continue;
        }
      }
      i++;
    }
    return commands;
  }

  static String _normalize(String input, {required bool stripThinkBlocks}) {
    var result = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (stripThinkBlocks) {
      result = _stripThinkBlocks(result);
    }
    result = _normalizeEscapedDelimiters(result);
    result = _convertDollarDelimiters(result);
    result = _extractBlanksFromMath(result);
    return result;
  }

  static String _stripThinkBlocks(String input) {
    var result = input;
    while (true) {
      final lower = result.toLowerCase();
      final start = lower.indexOf('<think>');
      if (start == -1) return result;
      final end = lower.indexOf('</think>', start + 7);
      if (end == -1) {
        return result.substring(0, start);
      }
      result = result.replaceRange(start, end + 8, '');
    }
  }

  static String _normalizeEscapedDelimiters(String input) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      if (input.codeUnitAt(i) != 92) {
        buffer.write(input[i]);
        i++;
        continue;
      }

      var count = 0;
      while (i + count < input.length && input.codeUnitAt(i + count) == 92) {
        count++;
      }

      final nextIndex = i + count;
      if (count >= 2 &&
          nextIndex < input.length &&
          _delimiterChars.contains(input[nextIndex])) {
        buffer.write('\\');
        buffer.write(input[nextIndex]);
        i = nextIndex + 1;
        continue;
      }

      buffer.write(List.filled(count, '\\').join());
      i += count;
    }
    return buffer.toString();
  }

  static String _convertDollarDelimiters(String input) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      if (_startsWith(input, i, r'\(')) {
        final end = _findClosingDelimiter(input, i + 2, r'\)');
        if (end == -1) {
          buffer.write(input.substring(i));
          break;
        }
        buffer.write(input.substring(i, end + 2));
        i = end + 2;
        continue;
      }

      if (_startsWith(input, i, r'\[')) {
        final end = _findClosingDelimiter(input, i + 2, r'\]');
        if (end == -1) {
          buffer.write(input.substring(i));
          break;
        }
        buffer.write(input.substring(i, end + 2));
        i = end + 2;
        continue;
      }

      if (_startsWith(input, i, r'$$') && !_isEscaped(input, i)) {
        final close = _findDollarClose(input, i + 2, block: true);
        if (close == -1) {
          buffer.write(r'$$');
          i += 2;
          continue;
        }
        buffer.write(r'\[');
        buffer.write(input.substring(i + 2, close));
        buffer.write(r'\]');
        i = close + 2;
        continue;
      }

      if (input[i] == r'$' && !_isEscaped(input, i)) {
        final close = _findDollarClose(input, i + 1, block: false);
        if (close == -1) {
          buffer.write(input[i]);
          i++;
          continue;
        }
        buffer.write(r'\(');
        buffer.write(input.substring(i + 1, close));
        buffer.write(r'\)');
        i = close + 1;
        continue;
      }

      buffer.write(input[i]);
      i++;
    }
    return buffer.toString();
  }

  static String _extractBlanksFromMath(String input) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < input.length) {
      if (_startsWith(input, i, r'\(')) {
        final end = _findClosingDelimiter(input, i + 2, r'\)');
        if (end == -1) {
          buffer.write(input.substring(i));
          break;
        }
        buffer.write(_splitBlanksOutOfMath(
          r'\(',
          input.substring(i + 2, end),
          r'\)',
        ));
        i = end + 2;
        continue;
      }

      if (_startsWith(input, i, r'\[')) {
        final end = _findClosingDelimiter(input, i + 2, r'\]');
        if (end == -1) {
          buffer.write(input.substring(i));
          break;
        }
        buffer.write(_splitBlanksOutOfMath(
          r'\[',
          input.substring(i + 2, end),
          r'\]',
        ));
        i = end + 2;
        continue;
      }

      buffer.write(input[i]);
      i++;
    }
    return buffer.toString();
  }

  static String _splitBlanksOutOfMath(
    String open,
    String tex,
    String close,
  ) {
    final pieces = <String>[];
    var segmentStart = 0;
    var i = 0;
    var foundBlank = false;
    while (i < tex.length) {
      if (tex[i] != '_') {
        i++;
        continue;
      }
      var end = i + 1;
      while (end < tex.length && tex[end] == '_') {
        end++;
      }
      if (end - i >= 3) {
        foundBlank = true;
        final before = tex.substring(segmentStart, i);
        if (before.isNotEmpty) {
          pieces.add('$open$before$close');
        }
        pieces.add(tex.substring(i, end));
        segmentStart = end;
      }
      i = end;
    }

    if (!foundBlank) {
      return '$open$tex$close';
    }

    final after = tex.substring(segmentStart);
    if (after.isNotEmpty) {
      pieces.add('$open$after$close');
    }
    return pieces.join();
  }

  static int _findDollarClose(
    String input,
    int start, {
    required bool block,
  }) {
    var i = start;
    while (i < input.length) {
      if (!block && (input[i] == '\n')) {
        return -1;
      }
      if (block && _startsWith(input, i, r'$$') && !_isEscaped(input, i)) {
        return i;
      }
      if (!block && input[i] == r'$' && !_isEscaped(input, i)) {
        return i;
      }
      i++;
    }
    return -1;
  }

  static int _findClosingDelimiter(String input, int start, String close) {
    var i = start;
    while (i <= input.length - close.length) {
      if (_startsWith(input, i, close)) {
        return i;
      }
      i++;
    }
    return -1;
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

  static bool _isEscaped(String input, int index) {
    var slashCount = 0;
    var i = index - 1;
    while (i >= 0 && input.codeUnitAt(i) == 92) {
      slashCount++;
      i--;
    }
    return slashCount.isOdd;
  }

  static bool _isAsciiLetter(int codeUnit) {
    return (codeUnit >= 65 && codeUnit <= 90) ||
        (codeUnit >= 97 && codeUnit <= 122);
  }
}
