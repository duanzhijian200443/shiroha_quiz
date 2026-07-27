import 'latex_renderability_checker.dart';

class LatexBlockEnvironmentNormalizationResult {
  const LatexBlockEnvironmentNormalizationResult({
    required this.text,
    required this.changed,
    required this.renderability,
  });

  final String text;
  final bool changed;
  final LatexRenderabilityResult renderability;
}

/// Wraps only complete, allow-listed block math environments whose smallest
/// formula boundary is structurally unambiguous.
class LatexBlockEnvironmentNormalizer {
  const LatexBlockEnvironmentNormalizer({
    this.checker = const LatexRenderabilityChecker(),
  });

  final LatexRenderabilityChecker checker;

  static final RegExp _environmentToken = RegExp(r'\\(begin|end)\{([^{}]+)\}');

  LatexBlockEnvironmentNormalizationResult normalize(String text) {
    final structural = checker.check(text, requireMathContext: false);
    if (!structural.isRenderable) {
      return LatexBlockEnvironmentNormalizationResult(
        text: text,
        changed: false,
        renderability: checker.check(text),
      );
    }

    final replacements = <_Replacement>[];
    final matches = _environmentToken.allMatches(text).toList(growable: false);
    for (var index = 0; index < matches.length; index++) {
      final opening = matches[index];
      if (opening.group(1) != 'begin') continue;
      final environment = opening.group(2)!;
      if (checker.isInMathContextAt(text, opening.start)) continue;
      if (!LatexRenderabilityChecker.mathBlockEnvironments
          .contains(environment)) {
        return _unchanged(text);
      }

      final closingIndex = _matchingEnvironmentIndex(matches, index);
      if (closingIndex == null) return _unchanged(text);
      final closing = matches[closingIndex];
      if (!_containsOnlyAllowedEnvironments(matches, index, closingIndex)) {
        return _unchanged(text);
      }

      final prefixStart = _safePrefixStart(text, opening.start);
      if (!_hasSafeBoundary(text, prefixStart)) return _unchanged(text);
      final fragment = text.substring(prefixStart, closing.end);
      if (_containsMathDelimiter(fragment)) return _unchanged(text);

      replacements.add(
        _Replacement(
          prefixStart,
          closing.end,
          '${r'\['}$fragment${r'\]'}',
        ),
      );
      index = closingIndex;
    }

    if (replacements.isEmpty) {
      return LatexBlockEnvironmentNormalizationResult(
        text: text,
        changed: false,
        renderability: checker.check(text),
      );
    }

    var normalized = text;
    for (final replacement in replacements.reversed) {
      normalized = normalized.replaceRange(
        replacement.start,
        replacement.end,
        replacement.value,
      );
    }
    final renderability = checker.check(normalized);
    if (!renderability.isRenderable) return _unchanged(text);
    return LatexBlockEnvironmentNormalizationResult(
      text: normalized,
      changed: normalized != text,
      renderability: renderability,
    );
  }

  LatexBlockEnvironmentNormalizationResult _unchanged(String text) {
    return LatexBlockEnvironmentNormalizationResult(
      text: text,
      changed: false,
      renderability: checker.check(text),
    );
  }

  int? _matchingEnvironmentIndex(
    List<RegExpMatch> matches,
    int openingIndex,
  ) {
    final stack = <String>[];
    for (var index = openingIndex; index < matches.length; index++) {
      final match = matches[index];
      final operation = match.group(1)!;
      final environment = match.group(2)!;
      if (operation == 'begin') {
        stack.add(environment);
      } else if (stack.isEmpty || stack.removeLast() != environment) {
        return null;
      }
      if (stack.isEmpty) return index;
    }
    return null;
  }

  bool _containsOnlyAllowedEnvironments(
    List<RegExpMatch> matches,
    int openingIndex,
    int closingIndex,
  ) {
    for (var index = openingIndex; index <= closingIndex; index++) {
      if (!LatexRenderabilityChecker.mathBlockEnvironments
          .contains(matches[index].group(2))) {
        return false;
      }
    }
    return true;
  }

  int _safePrefixStart(String text, int beginOffset) {
    var tokenEnd = beginOffset;
    while (tokenEnd > 0 &&
        (text[tokenEnd - 1] == ' ' || text[tokenEnd - 1] == '\t')) {
      tokenEnd--;
    }

    var cursor = tokenEnd;
    while (cursor > 0) {
      final previous = text[cursor - 1];
      if (_safeMathSymbols.contains(previous) ||
          _isAsciiDigit(previous.codeUnitAt(0))) {
        cursor--;
        if (cursor > 0 && text[cursor - 1] == r'\') cursor--;
        continue;
      }
      if (_isAsciiLetter(previous.codeUnitAt(0))) {
        var wordStart = cursor - 1;
        while (
            wordStart > 0 && _isAsciiLetter(text.codeUnitAt(wordStart - 1))) {
          wordStart--;
        }
        if (wordStart > 0 && text[wordStart - 1] == r'\') {
          cursor = wordStart - 1;
          continue;
        }
      }
      break;
    }
    return cursor == tokenEnd ? beginOffset : cursor;
  }

  bool _hasSafeBoundary(String text, int fragmentStart) {
    if (fragmentStart == 0) return true;
    final previous = text[fragmentStart - 1];
    if (previous == ' ' || previous == '\t' || previous == '\n') return true;
    return _safeNaturalLanguageBoundaries.contains(previous);
  }

  bool _containsMathDelimiter(String text) {
    return text.contains(r'\(') ||
        text.contains(r'\)') ||
        text.contains(r'\[') ||
        text.contains(r'\]') ||
        text.contains(r'$$') ||
        RegExp(r'(?<!\\)\$').hasMatch(text);
  }

  static const _safeMathSymbols = <String>{
    '{',
    '}',
    '[',
    ']',
    '(',
    ')',
    '+',
    '-',
    '*',
    '/',
    '=',
    '<',
    '>',
    '|',
    '.',
    ',',
    ':',
    ';',
  };

  static const _safeNaturalLanguageBoundaries = <String>{
    '，',
    '。',
    '；',
    '：',
    '！',
    '？',
    ',',
    '.',
    ';',
    ':',
    '!',
    '?',
  };

  bool _isAsciiLetter(int codeUnit) {
    return (codeUnit >= 65 && codeUnit <= 90) ||
        (codeUnit >= 97 && codeUnit <= 122);
  }

  bool _isAsciiDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;
}

class _Replacement {
  const _Replacement(this.start, this.end, this.value);

  final int start;
  final int end;
  final String value;
}
