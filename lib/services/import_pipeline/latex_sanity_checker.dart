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
  bool hasDanglingDelimiters(String text) {
    final inlineOpen = RegExp(r'\\\(').allMatches(text).length;
    final inlineClose = RegExp(r'\\\)').allMatches(text).length;
    final blockOpen = RegExp(r'\\\[').allMatches(text).length;
    final blockClose = RegExp(r'\\\]').allMatches(text).length;
    if (inlineOpen != inlineClose || blockOpen != blockClose) return true;

    final leftCount = RegExp(r'\\left').allMatches(text).length;
    final rightCount = RegExp(r'\\right').allMatches(text).length;
    return leftCount != rightCount;
  }
}
