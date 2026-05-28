import 'dart:convert';

class AiDataSanitizer {
  // 1. 强力 JSON 净化与防幻觉解析
  static List<Map<String, dynamic>> cleanAndParseJson(String rawText) {
    if (rawText.trim().isEmpty) {
      throw Exception("大模型返回了空内容。可能是触发了风控拦截，或使用了不兼容的 API 格式。");
    }

    String cleanText = rawText;
    
    // 1. 彻底剥离 <think>...</think> 思考过程标签（支持多行）
    cleanText = cleanText.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');

    // 2. 强行锁定 JSON 数组边界，无视闲聊污染
    // 优先寻找形如 "[ {" 的数组开头，跳过 AI 闲聊中可能带有的 "[]" 或图片标签
    int startIndex = cleanText.indexOf(RegExp(r'\[\s*\{'));
    if (startIndex == -1) {
      startIndex = cleanText.indexOf('[');
    }
    int endIndex = cleanText.lastIndexOf(']');
    
    if (startIndex != -1 && endIndex != -1 && startIndex < endIndex) {
      cleanText = cleanText.substring(startIndex, endIndex + 1);
    } else {
      throw Exception("未能从 AI 回复中提取到有效的 JSON 数组。");
    }

    // 0. 提前拯救与 JSON 转义冲突的 LaTeX 关键字（比如 \begin, \frac 等，防止被解析为 \b, \f 等特殊控制符）
    const dangerousCmds = r'begin|beta|boldsymbol|bmatrix|bar|bf|mathbb|mathbf|mathcal|mathrm|mathit|'
                          r'frac|forall|'
                          r'nabla|notin|nu|neq|'
                          r'right|rho|rangle|rightarrow|Rightarrow|'
                          r'tan|theta|times|to|tilde|tau|text|triangle|textbf|textit';
    cleanText = cleanText.replaceAllMapped(RegExp(r'(?<!\\)\\(' + dangerousCmds + r')\b'), (match) {
      return '\\\\${match.group(1)}';
    });

    // 0.5 修复大模型经常漏掉转义的公式换行符（如矩阵里的 \\ 必须转成 \\\\ 才能在 JSON 中存活）
    // 修复：必须确保后面不是字母，否则会误伤正确转义的 \alpha (此时在 JSON 里是 \\alpha)
    cleanText = cleanText.replaceAllMapped(RegExp(r'(?<!\\)\\\\(?![a-zA-Z\\])'), (match) {
       return r'\\\\';
    });

    // 捕获剩余的孤立单反斜杠防崩溃
    cleanText = cleanText.replaceAllMapped(RegExp(r'(?<!\\)\\([^"\\/bfnrt])'), (match) {
      return '\\\\${match.group(1)}';
    });

    List<dynamic> decoded = [];
    try {
      decoded = jsonDecode(cleanText);
    } catch (e) {
      // 如果出现截断或尾部携带无法匹配的非 JSON 字符，尝试自动修复
      int lastBrace = cleanText.lastIndexOf('}');
      if (lastBrace != -1) {
        String repaired = cleanText.substring(0, lastBrace + 1) + ']';
        try {
          decoded = jsonDecode(repaired);
        } catch (e2) {
          throw Exception("JSON解析失败且无法修复: $e (自动修复也失败: $e2)\n内容片段: ${cleanText.length > 100 ? cleanText.substring(0, 100) : cleanText}...");
        }
      } else {
        throw Exception("未能解析 JSON，可能大模型输出完全没有成型的对象: $e\n内容片段: ${cleanText.length > 100 ? cleanText.substring(0, 100) : cleanText}...");
      }
    }

    final List<Map<String, dynamic>> finalQuestions = [];
    
    for (var item in decoded) {
      final q = item as Map<String, dynamic>;
      int currentType = q['type'] as int? ?? 0;
      
      if (currentType == 2 || currentType == 3) {
        q['options'] = []; // 填空/简答强行清空选项
      } else {
        final opts = q['options'] as List?;
        if (opts != null && opts.isNotEmpty && opts[0].toString().trim().isNotEmpty) {
          q['type'] = 0; // 有选项强行归为单选
        }
      }
      finalQuestions.add(q);
    }
    return finalQuestions;
  }

  // 2. LaTeX 公式防吞噬与防崩溃格式化
  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    String result = text;

    // 0.0 【核心修复：Unicode 符号转 LaTeX】
    result = result.replaceAll('∑', r'\sum ');
    result = result.replaceAll('∏', r'\prod ');
    result = result.replaceAll('∫', r'\int ');
    result = result.replaceAll('∮', r'\oint ');
    result = result.replaceAll('α', r'\alpha ');
    result = result.replaceAll('β', r'\beta ');
    result = result.replaceAll('γ', r'\gamma ');
    result = result.replaceAll('θ', r'\theta ');
    result = result.replaceAll('λ', r'\lambda ');
    result = result.replaceAll('μ', r'\mu ');
    result = result.replaceAll('π', r'\pi ');
    result = result.replaceAll('σ', r'\sigma ');
    result = result.replaceAll('ω', r'\omega ');
    result = result.replaceAll('Δ', r'\Delta ');
    result = result.replaceAll('Ω', r'\Omega ');
    result = result.replaceAll('∞', r'\infty ');
    result = result.replaceAll('≈', r'\approx ');
    result = result.replaceAll('≠', r'\neq ');
    result = result.replaceAll('≤', r'\leq ');
    result = result.replaceAll('≥', r'\geq ');
    result = result.replaceAll('×', r'\times ');
    result = result.replaceAll('÷', r'\div ');
    result = result.replaceAll('±', r'\pm ');
    result = result.replaceAll('∈', r'\in ');
    result = result.replaceAll('∉', r'\notin ');
    result = result.replaceAll('⊂', r'\subset ');
    result = result.replaceAll('⊆', r'\subseteq ');
    result = result.replaceAll('∪', r'\cup ');
    result = result.replaceAll('∩', r'\cap ');
    result = result.replaceAll('∅', r'\emptyset ');
    result = result.replaceAll('∀', r'\forall ');
    result = result.replaceAll('∃', r'\exists ');
    result = result.replaceAll('∵', r'\because ');
    result = result.replaceAll('∴', r'\therefore ');
    result = result.replaceAll('⊥', r'\perp ');
    result = result.replaceAll('∥', r'\parallel ');
    result = result.replaceAll('∠', r'\angle ');
    result = result.replaceAll('△', r'\triangle ');

    // 0. 把公式内结尾的连续下划线移出公式
    result = result.replaceAllMapped(RegExp(r'\$([^\$]+?)(_{2,}[^a-zA-Z\u4e00-\u9fa5$]*\$?)'), (match) {
        String mathPart = match.group(1)!;
        String underscorePart = match.group(2)!;
        if (underscorePart.endsWith(r'$')) {
            underscorePart = underscorePart.substring(0, underscorePart.length - 1);
        }
        return '\$$mathPart\$$underscorePart';
    });

    // 0.1 【核心反转义 — 白名单安全模式】
    const knownCmdsSet = {'frac', 'sum', 'int', 'oint', 'iint', 'iiint', 'prod', 'coprod', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'varpi', 'rho', 'varrho', 'sigma', 'varsigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega', 'infty', 'limits', 'left', 'right', 'begin', 'end', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'max', 'min', 'lim', 'sqrt', 'cdot', 'cdots', 'ldots', 'times', 'div', 'pm', 'mp', 'neq', 'leq', 'geq', 'approx', 'equiv', 'propto', 'in', 'notin', 'subset', 'supset', 'cup', 'cap', 'emptyset', 'forall', 'exists', 'nabla', 'partial', 'mathbf', 'mathrm', 'mathit', 'mathbb', 'mathcal', 'text', 'textbf', 'textit', 'underline', 'overline', 'hat', 'tilde', 'vec', 'dot', 'ddot', 'overbrace', 'underbrace', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array', 'boldsymbol', 'widehat', 'widetilde', 'operatorname', 'DeclareMathOperator', 'mid', 'nmid', 'to', 'gets', 'rightarrow', 'leftarrow', 'Rightarrow', 'Leftarrow', 'iff', 'implies', 'xrightarrow', 'xleftarrow', 'bigoplus', 'bigotimes', 'bigcup', 'bigcap', 'biguplus', 'bigwedge', 'bigvee', 'lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'binom', 'dbinom', 'tbinom', 'stackrel', 'overset', 'underset', 'pmod', 'because', 'therefore', 'ell', 'perp', 'parallel', 'angle', 'Im', 'Re', 'not', 'quad', 'qquad', 'sim', 'simeq', 'cong', 'geqslant', 'leqslant', 'ge', 'le', 'd'};
    result = result.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (match) {
      final cmd = match.group(1)!;
      if (knownCmdsSet.contains(cmd)) {
        return r'\' + cmd;
      }
      return match.group(0)!;
    });
    result = result.replaceAllMapped(RegExp(r'\\\\([{(}\[\]|])'), (match) {
      return r'\' + match.group(1)!;
    });
    
    // 解救代码块和图片
    result = result.replaceAllMapped(RegExp(r'`\s*(\$+[^\$`]+?\$+)\s*`'), (match) => match.group(1)!);
    
    // 核心修复：修复大模型错误的公式闭合，例如 $\frac$ {5}{8} 变成 $\frac{5}{8}$
    result = result.replaceAllMapped(RegExp(r'\$(\\[a-zA-Z]+)\$\s*(\{.*?\}(?:\s*\{.*?\})*)'), (match) {
      return '\$${match.group(1)}${match.group(2)}\$';
    });

    result = result.replaceAllMapped(RegExp(r'```(?:math|latex|tex)?\s*([\s\S]+?)\s*```'), (match) {
        String inner = match.group(1)!.trim();
        if (inner.startsWith(r'$') && inner.endsWith(r'$')) {
            return '\n\n$inner\n\n';
        }
        return '\n\n\$\$$inner\$\$\n\n';
    });
    result = result.replaceAllMapped(RegExp(r'\$+(!\[.*?\]\(.*?\))\$+'), (match) => match.group(1)!);

    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    result = result.replaceAll(r'\begin{split}', r'\begin{aligned}');
    result = result.replaceAll(r'\end{split}', r'\end{aligned}');

    // 替换 AI 常见的转义填空线 \_\_\_ 为正常的 ___
    result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
      return '_' * (match.group(0)!.length ~/ 2);
    });

    // ==========================================
    // TOKENIZER: 智能切分，保护现有公式环境
    // ==========================================
    final pattern = RegExp(r'(\$\$.*?\$\$)|(\\\[.*?\\\])|(\\\(.*?\\\))|(\$.*?\$)|(\\begin\{[a-zA-Z*]+\}.*?\\end\{[a-zA-Z*]+\})', dotAll: true);
    
    List<String> tokens = [];
    int lastEnd = 0;
    
    for (final match in pattern.allMatches(result)) {
      if (match.start > lastEnd) {
        tokens.add(result.substring(lastEnd, match.start));
      }
      tokens.add(match.group(0)!);
      lastEnd = match.end;
    }
    if (lastEnd < result.length) {
      tokens.add(result.substring(lastEnd));
    }

    // 数学符号特征正则 (包含纯数字与变量混合的情况，用于捕获散落公式)
    final mathFeature = RegExp(r'(?:[xyztXYZTabcABC]\s*=\s*[-0-9\.]+|[xyzt]\s*[-+*/=><]\s*[-0-9\.]+|[-0-9\.]+\s*[<>≤≥]\s*[-0-9\.]+|[xyz]\s*∈|\\[a-zA-Z]+|\^\{?[0-9a-zA-Z]\}?|_[0-9a-zA-Z]|\\[a-zA-Z]+\{[^}]+\})');
    
    // ==========================================
    // RECONSTRUCT
    // ==========================================
    StringBuffer sb = new StringBuffer();
    for (String token in tokens) {
      if (token.startsWith(r'\begin') || token.startsWith(r'$$') || 
          token.startsWith(r'\[') || token.startsWith(r'\(') || 
          token.startsWith(r'$')) {
        // 已经是公式环境，安全处理内部
        String inner = token;
        
        if (token.startsWith(r'$$')) {
          inner = token.substring(2, token.length - 2).trim();
          if (inner.endsWith(r'\')) inner = inner.substring(0, inner.length - 1).trim();
          inner = _autoCloseLeftRight(inner);
          sb.write('\n\\[${inner}\\]\n');
        } else if (token.startsWith(r'$')) {
          inner = token.substring(1, token.length - 1).trim();
          if (inner.endsWith(r'\')) inner = inner.substring(0, inner.length - 1).trim();
          inner = _autoCloseLeftRight(inner);
          inner = inner.replaceAll('\n', ' ');
          if (inner.contains(r'\begin')) {
            sb.write('\n\\[${inner}\\]\n');
          } else {
            sb.write('\\(${inner}\\)');
          }
        } else if (token.startsWith(r'\begin')) {
          sb.write('\n\\[\n${token}\n\\]\n');
        } else {
          sb.write(token);
        }
      } else {
        // 普通文本，探测是否需要包裹 \( \)
        String t = token;
        // 如果包含数学特征，包裹进 \( \) 
        // （为避免误伤，使用单词边界和更严格的替换规则）
        if (mathFeature.hasMatch(t)) {
            // 对散落的类似 y=... 的表达式进行单次安全包裹
            t = t.replaceAllMapped(RegExp(r'([xyztXYZTabcABC]\s*=\s*[-0-9\.a-zA-Z]+|[-0-9\.]+\s*[=><≤≥]\s*[-0-9\.a-zA-Z]+)'), (m) => '\\(${m.group(1)}\\)');
            // 对孤立的带反斜杠 LaTeX 关键字包裹
            t = t.replaceAllMapped(RegExp(r'(?<!\\|\w)(\\[a-zA-Z]+(?:_[^{}\s]+|\^{?[^{}\s]+}?)?)(?!\w)'), (m) => '\\(${m.group(1)}\\)');
        }
        sb.write(t);
      }
    }
    
    return sb.toString();
  }

  // 智能括号闭合修补，防止大模型截断导致的渲染器崩溃
  static String _autoCloseLeftRight(String mathText) {
    // 替换公式中的连续下划线（填空线的两下划线及以上），避免 LaTeX 解析器将其误认为 subscript 导致崩溃
    mathText = mathText.replaceAllMapped(RegExp(r'_{2,}'), (match) {
      return r'\_' * match.group(0)!.length;
    });

    int leftCount = r'\left'.allMatches(mathText).length;
    int rightCount = r'\right'.allMatches(mathText).length;
    if (leftCount > rightCount) {
      mathText += r'\right.' * (leftCount - rightCount);
    }
    return mathText;
  }
}

