/// LaTeX 导入修复层
///
/// 仅在 Vision 解析后、进入暂存页前使用。
/// 不改动 renderer，不影响历史渲染规则与现有测试合同。
class LatexImportRepairService {
  const LatexImportRepairService._();
  static const LatexImportRepairService instance = LatexImportRepairService._();

  // 裸 LaTeX 命令特征正则：以 \cmd 开头且未被 $, \(, \[ 包裹
  static final _bareLatexPattern = RegExp(
    r'(?<![\\$\(])'
    r'(\\(?:frac|sqrt|int|sum|prod|lim|log|ln|sin|cos|tan|cot|sec|csc'
    r'|theta|alpha|beta|gamma|delta|epsilon|zeta|eta|mu|nu|xi|pi|rho'
    r'|sigma|tau|phi|chi|psi|omega|Omega|Gamma|Delta|Lambda|Sigma|Phi|Psi'
    r'|partial|nabla|infty|pm|mp|times|div|cdot|leq|geq|neq|approx|equiv'
    r'|forall|exists|in|notin|subset|supset|cup|cap|emptyset|mathbb|mathbf'
    r'|mathcal|mathrm|text|overline|underline|hat|tilde|vec|bar|dot|ddot'
    r'|left|right|begin|end|matrix|pmatrix|bmatrix|vmatrix|cases'
    r'|underbrace|overbrace|xleftarrow|xrightarrow|stackrel|overset'
    r'|boldsymbol|operatorname|limits|displaystyle)(?![a-zA-Z]))',
    caseSensitive: true,
  );

  /// 修复单段文本中的裸 LaTeX 为 `\( ... \)` 内联公式
  String repairInline(String text) {
    if (text.isEmpty) return text;

    // 按 token 扫描：如果当前位置已在 $, \(, \[ 内则跳过
    final buffer = StringBuffer();
    int i = 0;
    final len = text.length;

    while (i < len) {
      // 已有定界符：跳过整个定界块
      if (_startsDelimiter(text, i)) {
        final end = _findDelimiterEnd(text, i);
        buffer.write(text.substring(i, end));
        i = end;
        continue;
      }

      // 检测到裸 LaTeX 命令开始
      final match = _bareLatexPattern.matchAsPrefix(text, i);
      if (match != null) {
        // 找到一整个 LaTeX 表达式的结束位置（贪婪扫描到首个空行或非 LaTeX 字符结束）
        final exprEnd = _findLatexExprEnd(text, i);
        buffer.write(r'\(');
        buffer.write(text.substring(i, exprEnd));
        buffer.write(r'\)');
        i = exprEnd;
        continue;
      }

      buffer.write(text[i]);
      i++;
    }

    return buffer.toString();
  }

  /// 修复一道题目 Map 中所有相关字段的裸 LaTeX
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
          .map((o) => o is String ? repairInline(o) : o)
          .toList();
    }

    return result;
  }

  /// 批量修复题目列表
  List<Map<String, dynamic>> repairAll(List<Map<String, dynamic>> questions) {
    return questions.map(repairQuestion).toList();
  }

  // ─── 内部辅助 ────────────────────────────────────────────────────

  bool _startsDelimiter(String text, int i) {
    if (i >= text.length) return false;
    final ch = text[i];
    if (ch == r'$') return true;
    if (ch == r'\' && i + 1 < text.length) {
      final next = text[i + 1];
      if (next == '(' || next == '[') return true;
    }
    return false;
  }

  int _findDelimiterEnd(String text, int start) {
    final ch = text[start];
    if (ch == r'$') {
      // 找配对 $（跳过 $$）
      final isDouble = start + 1 < text.length && text[start + 1] == r'$';
      final close = isDouble ? r'$$' : r'$';
      final searchFrom = start + (isDouble ? 2 : 1);
      final idx = text.indexOf(close, searchFrom);
      return idx == -1 ? text.length : idx + close.length;
    }
    // \( ... \) or \[ ... \]
    final closeChar = text[start + 1] == '(' ? ')' : ']';
    int depth = 0;
    int i = start + 2;
    while (i < text.length) {
      if (text[i] == r'\' && i + 1 < text.length) {
        if (text[i + 1] == closeChar) {
          if (depth == 0) return i + 2;
          depth--;
        } else if (text[i + 1] == '(' || text[i + 1] == '[') {
          depth++;
        }
        i += 2;
      } else {
        i++;
      }
    }
    return text.length;
  }

  int _findLatexExprEnd(String text, int start) {
    // 贪婪模式：扫描直到遇到以下情况之一停止
    // 1. 遇到中文、汉字、句号、换行 + 换行（双换行 = 段落边界）
    // 2. 遇到普通英文句子（非 LaTeX）
    int i = start;
    final len = text.length;
    int braceDepth = 0;

    while (i < len) {
      final ch = text[i];

      if (ch == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (ch == '}') {
        braceDepth--;
        i++;
        if (braceDepth < 0) {
          braceDepth = 0;
          break; // 花括号已不平衡，在此截断
        }
        continue;
      }

      // 双换行 = 段落边界，停止
      if (ch == '\n' && i + 1 < len && text[i + 1] == '\n') break;

      // 中文字符，说明进入了自然语言区，停止
      final code = ch.codeUnitAt(0);
      if (code >= 0x4E00 && code <= 0x9FFF) break;

      // 在 depth==0 时遇到空格后紧接普通字母，可能是公式结束
      if (braceDepth == 0 && ch == ' ' && i + 1 < len) {
        final nextCode = text[i + 1].codeUnitAt(0);
        // 下一个字符是大写字母、中文等，或者不是纯数学符号，考虑在空格前截断
        if (nextCode >= 0x4E00 && nextCode <= 0x9FFF) {
          break; // 空格后是中文，空格不包括在内
        }
        if (nextCode >= 0x41 && nextCode <= 0x5A && text[i + 1] != r'\') {
          break;
        }
      }

      i++;
    }

    // 后退剔除末尾多余空格
    while (i > start && text[i - 1] == ' ') {
      i--;
    }

    return i;
  }
}
