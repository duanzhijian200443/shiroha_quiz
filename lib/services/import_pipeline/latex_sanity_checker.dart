import 'latex_renderability_checker.dart';

/// Shared LaTeX structural sanity checks.
///
/// These checks verify delimiter balance and structural integrity
/// without requiring a real Flutter LaTeX rendering widget.
class LatexSanityChecker {
  const LatexSanityChecker();

  static const _renderabilityChecker = LatexRenderabilityChecker();

  /// Returns true if the text contains unbalanced LaTeX delimiters.
  ///
  /// Checks:
  /// - \( / \) count match (inline math)
  /// - \[ / \] count match (display math)
  /// - \left / \right count match
  /// - \begin{...} / \end{...} nesting and names match
  bool hasDanglingDelimiters(String text) {
    return !_renderabilityChecker
        .check(text, requireMathContext: false)
        .isRenderable;
  }

  LatexRenderabilityResult checkRenderability(
    String text, {
    bool assumeMathContext = false,
  }) {
    return _renderabilityChecker.check(
      text,
      assumeMathContext: assumeMathContext,
    );
  }
}

/// Applies only structure-preserving repairs whose missing counterpart is
/// unambiguous. Unknown or mismatched structures are left unchanged.
String repairLatexDeterministically(String text) {
  var repaired = _closeSingleTrailingDelimiter(text, r'\(', r'\)');
  repaired = _closeSingleTrailingDelimiter(repaired, r'\[', r'\]');
  repaired = _normalizeUnbalancedLeftRight(repaired);
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
  final leftCount = latexLeftControlWordPattern.allMatches(text).length;
  final rightCount = latexRightControlWordPattern.allMatches(text).length;
  if (leftCount == rightCount) return text;
  if (rightCount > leftCount) return text;

  return text
      .replaceAll(RegExp(r'\\(?:left|right)(?![A-Za-z])\s*\.'), '')
      .replaceAll(latexLeftControlWordPattern, '')
      .replaceAll(latexRightControlWordPattern, '');
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
