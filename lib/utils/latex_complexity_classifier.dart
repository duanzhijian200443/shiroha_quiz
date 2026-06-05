class LatexComplexityClassifier {
  const LatexComplexityClassifier._();

  static final RegExp _blockCommands = RegExp(
    r'\\(?:begin|end|matrix|pmatrix|bmatrix|vmatrix|cases|aligned|array)\b',
  );

  static final RegExp _largeOperators = RegExp(
    r'\\(?:iint|iiint|oint|int|sum|prod|lim)\b',
  );

  static bool shouldRenderAsBlock(String tex) {
    final trimmed = tex.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.length > 80) return true;
    if (_blockCommands.hasMatch(trimmed)) return true;
    if (trimmed.contains(r'\\') && trimmed.length > 32) return true;
    if (_largeOperators.allMatches(trimmed).length >= 2) return true;
    return false;
  }
}
