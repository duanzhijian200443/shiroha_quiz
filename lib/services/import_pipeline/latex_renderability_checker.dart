final RegExp latexLeftControlWordPattern = RegExp(r'\\left(?![A-Za-z])');
final RegExp latexRightControlWordPattern = RegExp(r'\\right(?![A-Za-z])');

enum LatexRenderabilityIssue {
  unbalancedMathDelimiter('unbalanced_math_delimiter'),
  unbalancedLeftRight('unbalanced_left_right'),
  mismatchedEnvironment('mismatched_environment'),
  environmentOutsideMathContext('environment_outside_math_context'),
  incompleteEnvironmentArgument('incomplete_environment_argument');

  const LatexRenderabilityIssue(this.code);

  final String code;
}

class LatexRenderabilityResult {
  const LatexRenderabilityResult(this.issues);

  final List<LatexRenderabilityIssue> issues;

  bool get isRenderable => issues.isEmpty;
  String? get primaryIssueCode => issues.firstOrNull?.code;
}

/// Pure structural preflight shared by import auditing and UI rendering.
class LatexRenderabilityChecker {
  const LatexRenderabilityChecker();

  static const mathBlockEnvironments = <String>{
    'array',
    'matrix',
    'pmatrix',
    'bmatrix',
    'Bmatrix',
    'vmatrix',
    'Vmatrix',
    'cases',
    'aligned',
    'alignedat',
    'gathered',
    'split',
  };

  static final RegExp _structuralToken = RegExp(
    r'\\(begin|end)\{([^{}]+)\}|\\\(|\\\)|\\\[|\\\]|\$\$|\$',
  );

  LatexRenderabilityResult check(
    String text, {
    bool requireMathContext = true,
    bool assumeMathContext = false,
  }) {
    final issues = <LatexRenderabilityIssue>{};
    final mathStack = <String>[];
    final environmentStack = <_EnvironmentFrame>[];

    for (final match in _structuralToken.allMatches(text)) {
      final token = match.group(0)!;
      if (_shouldIgnoreDollarToken(text, match, mathStack)) {
        continue;
      }

      final operation = match.group(1);
      final environmentName = match.group(2);
      if (operation != null && environmentName != null) {
        if (operation == 'begin') {
          if (requireMathContext && !assumeMathContext && mathStack.isEmpty) {
            issues.add(
              LatexRenderabilityIssue.environmentOutsideMathContext,
            );
          }
          if (environmentName == 'array' &&
              !_hasCompleteArrayColumnSpec(text, match.end)) {
            issues.add(
              LatexRenderabilityIssue.incompleteEnvironmentArgument,
            );
          }
          environmentStack.add(
            _EnvironmentFrame(environmentName, mathStack.length),
          );
        } else if (environmentStack.isEmpty) {
          issues.add(LatexRenderabilityIssue.mismatchedEnvironment);
        } else {
          final opening = environmentStack.removeLast();
          if (opening.name != environmentName ||
              opening.mathDepth != mathStack.length) {
            issues.add(LatexRenderabilityIssue.mismatchedEnvironment);
          }
        }
        continue;
      }

      _updateMathStack(token, mathStack, issues);
    }

    if (mathStack.isNotEmpty) {
      issues.add(LatexRenderabilityIssue.unbalancedMathDelimiter);
    }
    if (environmentStack.isNotEmpty) {
      issues.add(LatexRenderabilityIssue.mismatchedEnvironment);
    }

    var leftDepth = 0;
    final leftRight = RegExp(r'\\(left|right)(?![A-Za-z])');
    for (final match in leftRight.allMatches(text)) {
      if (match.group(1) == 'left') {
        leftDepth++;
      } else if (leftDepth == 0) {
        issues.add(LatexRenderabilityIssue.unbalancedLeftRight);
      } else {
        leftDepth--;
      }
    }
    if (leftDepth != 0) {
      issues.add(LatexRenderabilityIssue.unbalancedLeftRight);
    }

    return LatexRenderabilityResult(List.unmodifiable(issues));
  }

  bool isInMathContextAt(String text, int offset) {
    final issues = <LatexRenderabilityIssue>{};
    final mathStack = <String>[];
    for (final match in _structuralToken.allMatches(text)) {
      if (match.start >= offset) break;
      if (match.group(1) != null) continue;
      final token = match.group(0)!;
      if (_shouldIgnoreDollarToken(text, match, mathStack)) {
        continue;
      }
      _updateMathStack(token, mathStack, issues);
    }
    return mathStack.isNotEmpty;
  }

  /// Returns the start offset of the explicit delimiter that closes the
  /// innermost math context containing [offset].
  int? findMathContextCloseOffset(String text, int offset) {
    final issues = <LatexRenderabilityIssue>{};
    final mathStack = <String>[];
    final matches = _structuralToken.allMatches(text);

    for (final match in matches) {
      if (match.start >= offset) break;
      if (match.group(1) != null) continue;
      final token = match.group(0)!;
      if (_shouldIgnoreDollarToken(text, match, mathStack)) continue;
      _updateMathStack(token, mathStack, issues);
    }
    if (issues.isNotEmpty || mathStack.isEmpty) return null;

    final containingDepth = mathStack.length;
    for (final match in _structuralToken.allMatches(text)) {
      if (match.start < offset || match.group(1) != null) continue;
      final token = match.group(0)!;
      if (_shouldIgnoreDollarToken(text, match, mathStack)) continue;
      _updateMathStack(token, mathStack, issues);
      if (issues.isNotEmpty) return null;
      if (mathStack.length < containingDepth) return match.start;
    }
    return null;
  }

  static bool _shouldIgnoreDollarToken(
    String text,
    RegExpMatch match,
    List<String> mathStack,
  ) {
    final token = match.group(0)!;
    if (!token.startsWith(r'$')) return false;
    if (_isEscaped(text, match.start)) return true;
    return token == r'$' &&
        (mathStack.isEmpty || mathStack.last != r'$') &&
        !_hasInlineDollarClose(text, match.end);
  }

  static void _updateMathStack(
    String token,
    List<String> stack,
    Set<LatexRenderabilityIssue> issues,
  ) {
    final expectedClose = switch (token) {
      r'\(' => r'\)',
      r'\[' => r'\]',
      r'$' => r'$',
      r'$$' => r'$$',
      _ => null,
    };
    if (expectedClose != null) {
      if ((token == r'$' || token == r'$$') &&
          stack.isNotEmpty &&
          stack.last == token) {
        stack.removeLast();
      } else {
        stack.add(expectedClose);
      }
      return;
    }

    if (token == r'\)' || token == r'\]') {
      if (stack.isEmpty || stack.removeLast() != token) {
        issues.add(LatexRenderabilityIssue.unbalancedMathDelimiter);
      }
    }
  }

  static bool _hasCompleteArrayColumnSpec(String text, int offset) {
    var index = offset;
    while (index < text.length && (text[index] == ' ' || text[index] == '\t')) {
      index++;
    }
    if (index >= text.length || text[index] != '{') return false;

    var depth = 0;
    for (var cursor = index; cursor < text.length; cursor++) {
      if (text[cursor] == '{' && !_isEscaped(text, cursor)) {
        depth++;
      } else if (text[cursor] == '}' && !_isEscaped(text, cursor)) {
        depth--;
        if (depth == 0) {
          return text.substring(index + 1, cursor).trim().isNotEmpty;
        }
      }
    }
    return false;
  }

  static bool _hasInlineDollarClose(String text, int offset) {
    for (var index = offset; index < text.length; index++) {
      if (text[index] == '\n') return false;
      if (text[index] == r'$' && !_isEscaped(text, index)) return true;
    }
    return false;
  }

  static bool _isEscaped(String text, int offset) {
    var slashCount = 0;
    var index = offset - 1;
    while (index >= 0 && text.codeUnitAt(index) == 92) {
      slashCount++;
      index--;
    }
    return slashCount.isOdd;
  }
}

class _EnvironmentFrame {
  const _EnvironmentFrame(this.name, this.mathDepth);

  final String name;
  final int mathDepth;
}
