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
        buffer.write(text.substring(i, end));
        i = end;
        continue;
      }

      if (i > 0 && text.codeUnitAt(i - 1) == 92) {
        buffer.write(text[i]);
        i++;
        continue;
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

  bool _startsWith(String input, int index, String needle) {
    if (index < 0 || index + needle.length > input.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (input.codeUnitAt(index + i) != needle.codeUnitAt(i)) return false;
    }
    return true;
  }
}
