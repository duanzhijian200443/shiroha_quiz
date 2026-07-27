final RegExp _leftControlWord = RegExp(r'\\left(?![A-Za-z])');
final RegExp _rightControlWord = RegExp(r'\\right(?![A-Za-z])');

/// Shared LaTeX structural sanity checks.
///
/// These checks verify delimiter balance and structural integrity
/// without requiring a real Flutter LaTeX rendering widget.
class LatexSanityChecker {
  const LatexSanityChecker();

  /// Returns true if the text contains unbalanced LaTeX delimiters.
  ///
  /// Checks:
  /// - \( / \) count match (inline math)
  /// - \[ / \] count match (display math)
  /// - \left / \right count match
  /// - \begin{...} / \end{...} nesting and names match
  bool hasDanglingDelimiters(String text) {
    final inlineOpen = RegExp(r'\\\(').allMatches(text).length;
    final inlineClose = RegExp(r'\\\)').allMatches(text).length;
    final blockOpen = RegExp(r'\\\[').allMatches(text).length;
    final blockClose = RegExp(r'\\\]').allMatches(text).length;
    if (inlineOpen != inlineClose || blockOpen != blockClose) return true;

    final leftCount = _leftControlWord.allMatches(text).length;
    final rightCount = _rightControlWord.allMatches(text).length;
    if (leftCount != rightCount) return true;

    final environments = <String>[];
    final environmentToken = RegExp(r'\\(begin|end)\{([^{}]+)\}');
    for (final match in environmentToken.allMatches(text)) {
      final operation = match.group(1);
      final name = match.group(2);
      if (name == null) return true;
      if (operation == 'begin') {
        environments.add(name);
      } else if (environments.isEmpty || environments.removeLast() != name) {
        return true;
      }
    }
    return environments.isNotEmpty;
  }
}

/// Applies only structure-preserving repairs whose missing counterpart is
/// unambiguous. Unknown or mismatched structures are left unchanged.
String repairLatexDeterministically(String text) {
  var repaired = _closeSingleTrailingDelimiter(text, r'\(', r'\)');
  repaired = _closeSingleTrailingDelimiter(repaired, r'\[', r'\]');
  repaired = _normalizeUnbalancedLeftRight(repaired);
  repaired = _closeTrailingEnvironments(repaired);
  return repaired;
}

String _closeSingleTrailingDelimiter(
  String text,
  String opening,
  String closing,
) {
  final openingCount = opening.allMatchesIn(text);
  final closingCount = closing.allMatchesIn(text);
  if (openingCount != closingCount + 1 ||
      text.lastIndexOf(opening) <= text.lastIndexOf(closing)) {
    return text;
  }

  final trailingWhitespace = RegExp(r'\s*$').firstMatch(text)!.group(0)!;
  final contentEnd = text.length - trailingWhitespace.length;
  return '${text.substring(0, contentEnd)}$closing$trailingWhitespace';
}

String _normalizeUnbalancedLeftRight(String text) {
  final leftCount = _leftControlWord.allMatches(text).length;
  final rightCount = _rightControlWord.allMatches(text).length;
  if (leftCount == rightCount) return text;
  if (rightCount > leftCount) return text;

  return text
      .replaceAll(RegExp(r'\\(?:left|right)(?![A-Za-z])\s*\.'), '')
      .replaceAll(_leftControlWord, '')
      .replaceAll(_rightControlWord, '');
}

String _closeTrailingEnvironments(String text) {
  final environments = <String>[];
  final environmentToken = RegExp(r'\\(begin|end)\{([^{}]+)\}');
  for (final match in environmentToken.allMatches(text)) {
    final operation = match.group(1);
    final name = match.group(2)!;
    if (operation == 'begin') {
      environments.add(name);
    } else if (environments.isEmpty || environments.removeLast() != name) {
      return text;
    }
  }
  if (environments.isEmpty) return text;

  final closingTokens =
      environments.reversed.map((environment) => '\\end{$environment}').join();
  final trailingWhitespace = RegExp(r'\s*$').firstMatch(text)!.group(0)!;
  final contentEnd = text.length - trailingWhitespace.length;
  final body = text.substring(0, contentEnd);
  final insertionOffset = body.endsWith(r'\)') || body.endsWith(r'\]')
      ? body.length - 2
      : body.length;
  return '${body.substring(0, insertionOffset)}'
      '$closingTokens${body.substring(insertionOffset)}$trailingWhitespace';
}

extension on String {
  int allMatchesIn(String text) {
    var count = 0;
    var offset = 0;
    while (true) {
      final match = text.indexOf(this, offset);
      if (match < 0) return count;
      count++;
      offset = match + length;
    }
  }
}
