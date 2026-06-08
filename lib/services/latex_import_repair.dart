import '../utils/latex_complexity_classifier.dart';
import '../utils/content_normalizer.dart';

/// Import-only LaTeX repair.
///
/// This service normalizes AI/Vision drafts before they enter the staging UI.
/// It deliberately does not change the global renderer contract: old bare
/// LaTeX remains plain text unless the import pipeline opts into this repair.
class LatexImportRepairService {
  const LatexImportRepairService._();

  static const LatexImportRepairService instance = LatexImportRepairService._();

  static final RegExp _bareLatexPattern = RegExp(
    r'\\(?:frac|sqrt|int|iint|iiint|oint|sum|prod|lim|log|ln|sin|cos|tan|cot'
    r'|sec|csc|theta|alpha|beta|gamma|delta|epsilon|zeta|eta|mu|nu|xi|pi'
    r'|rho|sigma|tau|phi|chi|psi|omega|Omega|Gamma|Delta|Lambda|Sigma|Phi'
    r'|Psi|partial|nabla|infty|pm|mp|times|div|cdot|leq|geq|neq|approx'
    r'|equiv|forall|exists|in|notin|subset|supset|cup|cap|emptyset|mathbb'
    r'|mathbf|mathcal|mathrm|text|overline|underline|hat|tilde|vec|bar|dot'
    r'|ddot|left|right|begin|end|matrix|pmatrix|bmatrix|vmatrix|cases'
    r'|aligned|array|underbrace|overbrace|xleftarrow|xrightarrow|stackrel'
    r'|overset|boldsymbol|operatorname|limits|displaystyle)(?![a-zA-Z])',
  );

  String repairInline(String text) {
    if (text.isEmpty) return text;

    text = ContentNormalizer.normalizeForStorage(text);

    final buffer = StringBuffer();
    var i = 0;

    while (i < text.length) {
      if (_startsDelimiter(text, i)) {
        final end = _findDelimiterEnd(text, i);
        if (end == -1) {
          // Unclosed — skip only the opening delimiter, don't break.
          // The remaining text must still be scanned for bare LaTeX.
          i += _delimiterOpenLength(text, i);
          continue;
        }
        buffer.write(_repairDelimitedSegment(text, i, end));
        i = end;
        continue;
      }

      if (i > 0 && text.codeUnitAt(i - 1) == 92) {
        buffer.write(text[i]);
        i++;
        continue;
      }

      // Escaped math set block: \{(x,y) | ... \sqrt{...}\}
      if (_startsWith(text, i, r'\{')) {
        final setEnd = _findEscapedSetEnd(text, i + 2);
        if (setEnd != -1) {
          final expr = text.substring(i, setEnd);
          if (_isMathSetSegment(expr) && _isSafeLatexSegment(expr)) {
            final asBlock = LatexComplexityClassifier.shouldRenderAsBlock(expr);
            buffer
              ..write(asBlock ? r'\[' : r'\(')
              ..write(expr)
              ..write(asBlock ? r'\]' : r'\)');
            i = setEnd;
            continue;
          }
        }
      }

      // Bare math set block: {(x,y) | ... \sqrt{...}}
      if (text[i] == '{' && !_isEscapedAt(text, i)) {
        final setEnd = _findBareSetEnd(text, i);
        if (setEnd != -1) {
          final expr = text.substring(i, setEnd);
          if (_isMathSetSegment(expr) && _isSafeLatexSegment(expr)) {
            final repairedExpr = _escapeOuterBareSetBraces(expr);
            final asBlock =
                LatexComplexityClassifier.shouldRenderAsBlock(repairedExpr);
            buffer
              ..write(asBlock ? r'\[' : r'\(')
              ..write(repairedExpr)
              ..write(asBlock ? r'\]' : r'\)');
            i = setEnd;
            continue;
          }
        }
      }

      // Unicode integral fragment: ∮_L(...) → \oint_L(...)
      if (_isUnicodeIntegralStart(text, i)) {
        final exprEnd = _findUnicodeIntegralExprEnd(text, i);
        if (exprEnd > i) {
          final expr = text.substring(i, exprEnd).trimRight();
          if (_isConcreteUnicodeIntegralExpr(expr)) {
            final repairedExpr = _normalizeUnicodeIntegralExpr(expr);
            if (_isSafeLatexSegment(repairedExpr)) {
              final asBlock =
                  LatexComplexityClassifier.shouldRenderAsBlock(repairedExpr);
              buffer
                ..write(asBlock ? r'\[' : r'\(')
                ..write(repairedExpr)
                ..write(asBlock ? r'\]' : r'\)');
              i = exprEnd;
              continue;
            }
          }
        }
      }

      // Bare equation: y=e^{-\int...} — scan from variable=, not from \int
      final equationEnd = _findBareEquationEnd(text, i);
      if (equationEnd > i) {
        final expr = text.substring(i, equationEnd).trimRight();
        if (_isSafeBareEquation(expr)) {
          final asBlock = LatexComplexityClassifier.shouldRenderAsBlock(expr);
          buffer
            ..write(asBlock ? r'\[' : r'\(')
            ..write(expr)
            ..write(asBlock ? r'\]' : r'\)');
          i = equationEnd;
          continue;
        }
      }

      final match = _bareLatexPattern.matchAsPrefix(text, i);
      if (match == null) {
        buffer.write(text[i]);
        i++;
        continue;
      }

      final exprEnd = _findLatexExprEnd(text, i);
      if (exprEnd <= i) {
        buffer.write(text[i]);
        i++;
        continue;
      }

      final expr = text.substring(i, exprEnd).trimRight();
      if (!_isSafeLatexSegment(expr)) {
        buffer.write(expr);
        i = exprEnd;
        continue;
      }

      final asBlock = LatexComplexityClassifier.shouldRenderAsBlock(expr);
      buffer
        ..write(asBlock ? r'\[' : r'\(')
        ..write(expr)
        ..write(asBlock ? r'\]' : r'\)');
      i = exprEnd;
    }

    return buffer.toString();
  }

  Map<String, dynamic> repairQuestion(Map<String, dynamic> q) {
    final result = Map<String, dynamic>.from(q);

    if (result['content'] is String) {
      result['content'] = repairInline(result['content'] as String);
    }
    if (result['standard_answer'] is String) {
      result['standard_answer'] =
          repairInline(result['standard_answer'] as String);
    }
    if (result['explanation'] is String) {
      result['explanation'] = repairInline(result['explanation'] as String);
    }
    if (result['options'] is List) {
      result['options'] = (result['options'] as List)
          .map((option) => option is String ? repairInline(option) : option)
          .toList();
    }

    return result;
  }

  List<Map<String, dynamic>> repairAll(List<Map<String, dynamic>> questions) {
    return questions.map(repairQuestion).toList();
  }

  bool _startsDelimiter(String text, int i) {
    if (i >= text.length) return false;
    if (text[i] == r'$') return true;
    if (text[i] == r'\' && i + 1 < text.length) {
      return text[i + 1] == '(' || text[i + 1] == '[';
    }
    return false;
  }

  int _findDelimiterEnd(String text, int start) {
    if (text[start] == r'$') {
      final isDouble = start + 1 < text.length && text[start + 1] == r'$';
      final close = isDouble ? r'$$' : r'$';
      final searchFrom = start + (isDouble ? 2 : 1);
      final idx = text.indexOf(close, searchFrom);
      return idx == -1 ? -1 : idx + close.length;
    }

    final close = text[start + 1] == '(' ? r'\)' : r'\]';
    final idx = _findClosingDelimiter(text, start + 2, close);
    return idx == -1 ? -1 : idx + close.length;
  }

  int _findLatexExprEnd(String text, int start) {
    var i = start;
    var braceDepth = 0;

    while (i < text.length) {
      final ch = text[i];

      if (ch == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (ch == '}') {
        braceDepth--;
        i++;
        if (braceDepth < 0) break;
        continue;
      }

      if (braceDepth == 0) {
        if (_isNaturalLanguageBoundary(ch)) break;
        if (ch == '\n') break;
        if (ch == ' ' && i + 1 < text.length) {
          final next = text.codeUnitAt(i + 1);
          if (_isCjk(next) || _isUpperAscii(next)) break;
        }
      }

      i++;
    }

    while (i > start && text[i - 1] == ' ') {
      i--;
    }
    return i;
  }

  bool _isSafeLatexSegment(String expr) {
    if (expr.isEmpty) return false;
    if (!_hasBalancedBraces(expr)) return false;
    if (!_hasBalancedEnvironments(expr)) return false;
    return true;
  }

  bool _hasBalancedBraces(String expr) {
    var depth = 0;
    for (var i = 0; i < expr.length; i++) {
      if (expr[i] == '{') depth++;
      if (expr[i] == '}') depth--;
      if (depth < 0) return false;
    }
    return depth == 0;
  }

  bool _hasBalancedEnvironments(String expr) {
    final stack = <String>[];
    final envPattern = RegExp(r'\\(begin|end)\{([^{}]+)\}');
    for (final match in envPattern.allMatches(expr)) {
      final kind = match.group(1)!;
      final name = match.group(2)!;
      if (kind == 'begin') {
        stack.add(name);
        continue;
      }
      if (stack.isEmpty || stack.removeLast() != name) {
        return false;
      }
    }
    return stack.isEmpty;
  }

  int _findClosingDelimiter(String input, int start, String close) {
    final open = close == r'\)' ? r'\(' : r'\[';
    var depth = 0;
    var i = start;
    while (i <= input.length - close.length) {
      if (_startsWith(input, i, close)) {
        if (depth == 0) return i;
        depth--;
        i += close.length;
        continue;
      }
      if (_startsWith(input, i, open)) {
        depth++;
        i += open.length;
        continue;
      }
      i++;
    }
    return -1;
  }

  bool _isNaturalLanguageBoundary(String ch) {
    return ch == '，' || ch == '。' || ch == '；' || ch == '：' || ch == '、';
  }

  bool _isCjk(int codeUnit) => codeUnit >= 0x4E00 && codeUnit <= 0x9FFF;

  bool _isUpperAscii(int codeUnit) => codeUnit >= 0x41 && codeUnit <= 0x5A;

  int _delimiterOpenLength(String text, int start) {
    if (text[start] == r'$') {
      return start + 1 < text.length && text[start + 1] == r'$' ? 2 : 1;
    }
    return 2; // \( 或 \[
  }

  String _repairDelimitedSegment(String text, int start, int end) {
    if (text[start] == r'$') {
      final isDouble = start + 1 < text.length && text[start + 1] == r'$';
      final open = isDouble ? r'$$' : r'$';
      final contentStart = start + open.length;
      final contentEnd = end - open.length;
      if (contentEnd < contentStart) return text.substring(start, end);
      final content = text.substring(contentStart, contentEnd);
      final cleaned = _trimOddTrailingBackslash(content);
      return '$open$cleaned$open';
    }

    final open = text[start + 1] == '(' ? r'\(' : r'\[';
    final close = text[start + 1] == '(' ? r'\)' : r'\]';
    final contentStart = start + 2;
    final contentEnd = end - 2;
    if (contentEnd < contentStart) return text.substring(start, end);
    final content = text.substring(contentStart, contentEnd);
    final cleaned = _trimOddTrailingBackslash(content);
    return '$open$cleaned$close';
  }

  String _trimOddTrailingBackslash(String input) {
    var end = input.length;
    while (end > 0 && input.codeUnitAt(end - 1) <= 32) {
      end--;
    }
    var slashCount = 0;
    var i = end - 1;
    while (i >= 0 && input.codeUnitAt(i) == 92) {
      slashCount++;
      i--;
    }
    if (slashCount.isOdd) {
      return input.substring(0, end - 1) + input.substring(end);
    }
    return input;
  }

  int _findEscapedSetEnd(String text, int start) {
    var i = start;
    while (i < text.length - 1) {
      if (_startsWith(text, i, r'\}')) {
        return i + 2;
      }
      i++;
    }
    return -1;
  }

  bool _isMathSetSegment(String expr) {
    final isEscapedSet = expr.startsWith(r'\{') && expr.endsWith(r'\}');
    final isBareSet = expr.startsWith('{') && expr.endsWith('}');

    if (!isEscapedSet && !isBareSet) {
      return false;
    }

    final inner = isEscapedSet
        ? expr.substring(2, expr.length - 2)
        : expr.substring(1, expr.length - 1);

    if (inner.trim().isEmpty) return false;

    // Plain Chinese text inside braces is not math (e.g. {注意事项})
    if (RegExp(r'[一-鿿]').hasMatch(inner)) {
      return false;
    }

    final hasSetShape = inner.contains('|') ||
        inner.contains(r'\mid') ||
        RegExp(r'\([^)]*[,，][^)]*\)').hasMatch(inner);

    if (!hasSetShape) {
      return false;
    }

    final mathSignals = <RegExp>[
      RegExp(
          r'\\(?:frac|sqrt|sin|cos|tan|theta|pi|leq|geq|neq|in|notin|mid)\b'),
      RegExp(r'[_^]'),
      RegExp(r'[≤≥∈∉]'),
      RegExp(r'[=<>]'),
      RegExp(r'\b(?:le|ge)\b'),
    ];

    return mathSignals.any((pattern) => pattern.hasMatch(inner));
  }

  bool _isEscapedAt(String text, int index) {
    var slashCount = 0;
    var i = index - 1;
    while (i >= 0 && text.codeUnitAt(i) == 92) {
      slashCount++;
      i--;
    }
    return slashCount.isOdd;
  }

  int _findBareSetEnd(String text, int start) {
    if (start >= text.length || text[start] != '{') return -1;

    var depth = 0;
    var i = start;

    while (i < text.length) {
      final ch = text[i];

      if (ch == r'\') {
        i += i + 1 < text.length ? 2 : 1;
        continue;
      }

      if (ch == '\n') return -1;

      if (ch == '{') {
        depth++;
        i++;
        continue;
      }

      if (ch == '}') {
        depth--;
        i++;
        if (depth == 0) return i;
        if (depth < 0) return -1;
        continue;
      }

      i++;
    }

    return -1;
  }

  String _escapeOuterBareSetBraces(String expr) {
    if (expr.length < 2 || !expr.startsWith('{') || !expr.endsWith('}')) {
      return expr;
    }
    return r'\{' + expr.substring(1, expr.length - 1) + r'\}';
  }

  bool _isUnicodeIntegralStart(String text, int index) {
    if (index < 0 || index >= text.length) return false;
    final ch = text[index];
    return ch == '∫' || ch == '∬' || ch == '∭' || ch == '∮';
  }

  int _findUnicodeIntegralExprEnd(String text, int start) {
    var i = start;
    var braceDepth = 0;
    var parenDepth = 0;

    while (i < text.length) {
      final ch = text[i];

      if (ch == r'\') {
        i += i + 1 < text.length ? 2 : 1;
        continue;
      }

      if (ch == '{') {
        braceDepth++;
        i++;
        continue;
      }

      if (ch == '}') {
        braceDepth--;
        i++;
        if (braceDepth < 0) break;
        continue;
      }

      if (ch == '(' || ch == '（') {
        parenDepth++;
        i++;
        continue;
      }

      if (ch == ')' || ch == '）') {
        if (parenDepth > 0) parenDepth--;
        i++;
        continue;
      }

      if (braceDepth == 0 && parenDepth == 0) {
        if (_isNaturalLanguageBoundary(ch)) break;
        if (ch == '\n') break;
        if (ch == ' ' && i + 1 < text.length) {
          final next = text.codeUnitAt(i + 1);
          if (_isCjk(next)) break;
        }
      }

      i++;
    }

    while (i > start && text[i - 1] == ' ') {
      i--;
    }

    return i;
  }

  bool _isConcreteUnicodeIntegralExpr(String expr) {
    final value = expr.trim();
    if (value.isEmpty) return false;

    if (!RegExp(r'^[∫-∮]').hasMatch(value)) return false;

    // Bare symbol with no formula body → skip
    if (RegExp(r'^[∫-∮](?:_[A-Za-z0-9]+)?$').hasMatch(value)) {
      return false;
    }

    final hasFormulaBody = value.contains('(') ||
        value.contains(r'\') ||
        value.contains('+') ||
        value.contains('-') ||
        value.contains('=') ||
        value.contains('d');

    return hasFormulaBody;
  }

  String _normalizeUnicodeIntegralExpr(String expr) {
    if (expr.startsWith('∮')) return r'\oint' + expr.substring(1);
    if (expr.startsWith('∭')) return r'\iiint' + expr.substring(1);
    if (expr.startsWith('∬')) return r'\iint' + expr.substring(1);
    if (expr.startsWith('∫')) return r'\int' + expr.substring(1);
    return expr;
  }

  // ── bare equation: y=e^{-\int...} ──

  int _findBareEquationEnd(String text, int start) {
    if (!_looksLikeBareEquationStart(text, start)) return -1;

    var i = start;
    var braceDepth = 0;
    var parenDepth = 0;

    while (i < text.length) {
      final ch = text[i];

      if (ch == r'\') {
        i += i + 1 < text.length ? 2 : 1;
        continue;
      }

      if (ch == '{') {
        braceDepth++;
        i++;
        continue;
      }

      if (ch == '}') {
        braceDepth--;
        i++;
        if (braceDepth < 0) break;
        continue;
      }

      if (ch == '(' || ch == '（') {
        parenDepth++;
        i++;
        continue;
      }

      if (ch == ')' || ch == '）') {
        if (parenDepth > 0) parenDepth--;
        i++;
        continue;
      }

      if (braceDepth == 0 && parenDepth == 0) {
        if (_isNaturalLanguageBoundary(ch)) break;
        if (ch == '\n') break;
        if (ch == ' ' && i + 1 < text.length) {
          final next = text.codeUnitAt(i + 1);
          if (_isCjk(next) || _isUpperAscii(next)) break;
        }
      }

      i++;
    }

    while (i > start && text[i - 1] == ' ') {
      i--;
    }

    return i;
  }

  bool _looksLikeBareEquationStart(String text, int start) {
    if (start < 0 || start >= text.length) return false;

    // Previous char must not be letter/digit/underscore (guards against
    // matching 'e=' inside 'mode=fast').
    if (start > 0) {
      final prev = text.codeUnitAt(start - 1);
      if (_isAsciiLetter(prev) || _isAsciiDigit(prev) || prev == 0x5F) {
        return false;
      }
    }

    var i = start;

    // Single ASCII or Greek variable name: x=  y=  A=  ρ=
    if (i < text.length && _isAsciiLetter(text.codeUnitAt(i))) {
      i++;
    } else if (i < text.length && _isGreekVariableChar(text[i])) {
      i++;
    } else {
      return false;
    }

    // Optional subscript: x_n=  y_1=  y_{k+1}=
    if (i < text.length && text[i] == '_') {
      i++;
      if (i >= text.length) return false;

      if (text[i] == '{') {
        final close = text.indexOf('}', i + 1);
        if (close == -1) return false;
        i = close + 1;
      } else {
        final code = text.codeUnitAt(i);
        if (!_isAsciiLetter(code) && !_isAsciiDigit(code)) return false;
        i++;
      }
    }

    return i < text.length && text[i] == '=';
  }

  bool _isSafeBareEquation(String expr) {
    final value = expr.trim();
    if (value.isEmpty) return false;
    if (!value.contains('=')) return false;

    // Must not contain Chinese (guards against y=结果变量).
    if (RegExp(r'[一-鿿]').hasMatch(value)) return false;

    // Must contain both a LaTeX command AND a math power/group.
    final hasLatex = RegExp(
      r'\\(?:frac|sqrt|int|iint|iiint|oint|sum|prod|lim'
      r'|sin|cos|tan|ln|log|theta|pi)\b',
    ).hasMatch(value);
    final hasPowerOrGroup = value.contains('^') || value.contains('{');

    if (!hasLatex || !hasPowerOrGroup) return false;

    return _isSafeLatexSegment(value);
  }

  bool _isAsciiLetter(int code) =>
      (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

  bool _isAsciiDigit(int code) => code >= 0x30 && code <= 0x39;

  bool _isGreekVariableChar(String ch) {
    return ch == 'ρ' ||
        ch == 'θ' ||
        ch == 'α' ||
        ch == 'β' ||
        ch == 'γ' ||
        ch == 'λ' ||
        ch == 'μ' ||
        ch == 'σ';
  }

  bool _startsWith(String input, int index, String needle) {
    if (index < 0 || index + needle.length > input.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (input.codeUnitAt(index + i) != needle.codeUnitAt(i)) return false;
    }
    return true;
  }
}
