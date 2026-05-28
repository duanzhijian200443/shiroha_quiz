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


    // 0. 把公式内结尾的连续下划线移出公式，解决填空题下划线破坏 Markdown 加粗渲染的问题
    // 兼容大模型截断导致的闭合 $ 丢失的情况
    result = result.replaceAllMapped(RegExp(r'\$([^\$]+?)(_{2,}[^a-zA-Z\u4e00-\u9fa5$]*\$?)'), (match) {
        String mathPart = match.group(1)!;
        String underscorePart = match.group(2)!;
        if (underscorePart.endsWith(r'$')) {
            underscorePart = underscorePart.substring(0, underscorePart.length - 1);
        }
        return '\$$mathPart\$$underscorePart';
    });

    // 0.1 【核心反转义 — 白名单安全模式】
    //    问题根源：旧版贪婪正则 \\([a-zA-Z...]) 会把矩阵/方程组换行符 \\ 后面跟着的
    //    普通字母（如 \\y、\\AB）也一并吃掉，生成 \y、\AB 等 flutter_math_fork 不认识的
    //    非法命令，导致 ParseException 崩溃并渲染红色错误文本。
    //    修复方案：只对白名单中已知合法的 LaTeX 命令执行 \\ → \ 的降级，其余一律放行。
    const knownCmdsSet = {'frac', 'sum', 'int', 'oint', 'iint', 'iiint', 'prod', 'coprod', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'varpi', 'rho', 'varrho', 'sigma', 'varsigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega', 'infty', 'limits', 'left', 'right', 'begin', 'end', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'max', 'min', 'lim', 'sqrt', 'cdot', 'cdots', 'ldots', 'times', 'div', 'pm', 'mp', 'neq', 'leq', 'geq', 'approx', 'equiv', 'propto', 'in', 'notin', 'subset', 'supset', 'cup', 'cap', 'emptyset', 'forall', 'exists', 'nabla', 'partial', 'mathbf', 'mathrm', 'mathit', 'mathbb', 'mathcal', 'text', 'textbf', 'textit', 'underline', 'overline', 'hat', 'tilde', 'vec', 'dot', 'ddot', 'overbrace', 'underbrace', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array', 'boldsymbol', 'widehat', 'widetilde', 'operatorname', 'DeclareMathOperator', 'mid', 'nmid', 'to', 'gets', 'rightarrow', 'leftarrow', 'Rightarrow', 'Leftarrow', 'iff', 'implies', 'xrightarrow', 'xleftarrow', 'bigoplus', 'bigotimes', 'bigcup', 'bigcap', 'biguplus', 'bigwedge', 'bigvee', 'lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'binom', 'dbinom', 'tbinom', 'stackrel', 'overset', 'underset', 'pmod', 'because', 'therefore', 'ell', 'perp', 'parallel', 'angle', 'Im', 'Re', 'not', 'quad', 'qquad', 'sim', 'simeq', 'cong', 'geqslant', 'leqslant', 'ge', 'le', 'd'};
    // 步骤 A：仅对白名单命令执行 \\cmd → \cmd 降级。
    // 使用 [a-zA-Z]+ 配合 Set 查找，避免了 \b 遇到下划线（如 \\int_1）时边界匹配失败的问题。
    result = result.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (match) {
      final cmd = match.group(1)!;
      if (knownCmdsSet.contains(cmd)) {
        return r'\' + cmd;
      }
      return match.group(0)!;
    });
    // 步骤 B：针对特殊括号 \{ \} \[ \] \| 单独降级（这些不是换行符，可以安全处理）
    result = result.replaceAllMapped(RegExp(r'\\\\([{(}\[\]|])'), (match) {
      return r'\' + match.group(1)!;
    });
    
    // Fix LLM using \( \) or \[ \] outside of $
    result = result.replaceAllMapped(RegExp(r'\\\((.*?)\\\)'), (match) => '\$${match.group(1)}\$');
    result = result.replaceAllMapped(RegExp(r'\\\[(.*?)\\\]'), (match) => '\$\$${match.group(1)}\$\$');

    // 0.4 【解救代码块】大模型常常将 LaTeX 公式包在 markdown 代码块里（如 `$...$` 或 ```math ... ```）
    // 这种情况下，flutter_markdown 会优先把它解析为代码块，并使用红色等宽字体渲染，导致公式失效并截断。
    // 规则A：剥离单反引号包裹的公式（允许反引号和$之间有空格）：` $...$ ` -> $...$
    result = result.replaceAllMapped(RegExp(r'`\s*(\$+[^\$`]+?\$+)\s*`'), (match) => match.group(1)!);
    // 规则B：剥离多行代码块包裹的公式：```math \n ... \n ``` -> $$...$$
    result = result.replaceAllMapped(RegExp(r'```(?:math|latex|tex)?\s*([\s\S]+?)\s*```'), (match) {
        String inner = match.group(1)!.trim();
        // 如果它自己已经有 $$ 包裹了，就只脱去 ``` 外衣
        if (inner.startsWith(r'$') && inner.endsWith(r'$')) {
            return '\n\n$inner\n\n';
        }
        // 如果是纯公式，给它套上 $$
        return '\n\n\$\$$inner\$\$\n\n';
    });

    // 0.5 【核心解救图片】如果图片标签被旧版逻辑或大模型误包裹了 $，强行剥离它
    // 例如：$![](sandbox://...)$ 会被剥离成 ![](sandbox://...)
    result = result.replaceAllMapped(RegExp(r'\$+(!\[.*?\]\(.*?\))\$+'), (match) => match.group(1)!);

    // Auto-wrap unwrapped math segments
    result = result.replaceAllMapped(RegExp(r'([^\u4e00-\u9fa5，。、！？：；（）\n]+)'), (match) {
        String segment = match.group(1)!;
        // 绝对保护：如果片段包含图片 Markdown 标签 ![]()，跳过不处理
        if (segment.contains('![')) return segment;
        if (segment.contains(r'$')) return segment;
        // 排除路径中的下划线（如 sandbox://xxx/_page_1_Figure.jpeg），只计算非路径中的 _
        String segmentNoUrl = segment.replaceAll(RegExp(r'https?://\S+|sandbox://\S+'), '');
        bool hasMathUnderscore = segmentNoUrl.replaceAll(RegExp(r'_{2,}'), '').contains('_');
        
        // 只要片段内包含任何已知白名单命令，就断定它是漏掉的公式
        bool hasMathCmd = RegExp(r'\\([a-zA-Z]+)').allMatches(segment).any((m) => knownCmdsSet.contains(m.group(1)));

        if (segment.contains(r'\frac') || segment.contains(r'\partial') || 
            segment.contains(r'\lim') || segment.contains(r'\int') || 
            segment.contains(r'\sum') || segment.contains(r'\prod') || 
            segment.contains(r'^') || hasMathUnderscore || segment.contains(r'\begin') ||
            hasMathCmd) {
            if (segment.contains(r'\begin')) {
                return '\n\n\$\$$segment\$\$\n\n';
            }
            return '\$$segment\$';
        }
        return segment;
    });

    // 使用 (?![a-zA-Z]) 避免误将 \neq 等 LaTeX 关键字里的 \n 替换成换行符！
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    // 强制将不支持的 split 环境替换为 flutter_math_fork 支持的 aligned 环境
    result = result.replaceAll(r'\begin{split}', r'\begin{aligned}');
    result = result.replaceAll(r'\end{split}', r'\end{aligned}');

    // 1. 自动为单 $ 公式两端补充空格，打破中文无边界导致的正则失效（flutter_markdown_latex 强依赖边界）
    // 2. 强制将包含了 \begin 的单 $ 升级为双 $$ 块级公式
    // 3. 剥离普通单 $ 公式内部的非法换行符，防止 inline 语法解析跨行失败
    // 4. 智能闭合缺失的 \right 防止崩溃
    result = result.replaceAllMapped(RegExp(r'(?<!\$)\$([^\$]+?)\$(?!\$)'), (match) {
        String inner = match.group(1)!;
        inner = _autoCloseLeftRight(inner);
        // 防崩溃：强制把内嵌的中文字符包裹进 \text{}，避免 parser 崩溃报错变红
        inner = inner.replaceAllMapped(RegExp(r'(?<!\\text\{)([\u4e00-\u9fa5]+)'), (m) {
             return r'\text{' + m.group(1)! + r'}';
        });
        if (inner.contains(r'\begin')) {
            return '\n\n\$\$$inner\$\$\n\n';
        }
        inner = inner.replaceAll('\n', ' ');
        return ' \$${inner}\$ ';
    });
    
    // 深度清理大模型产生的 $$$...$$$ 或更多 $ 的套娃行为
    result = result.replaceAllMapped(RegExp(r'\$\$+([^\$]+?)\$\$+'), (match) {
        String inner = match.group(1)!.trim();
        inner = _autoCloseLeftRight(inner);
        // 防崩溃：强制把内嵌的中文字符包裹进 \text{}，避免 parser 崩溃报错变红
        inner = inner.replaceAllMapped(RegExp(r'(?<!\\text\{)([\u4e00-\u9fa5]+)'), (m) {
             return r'\text{' + m.group(1)! + r'}';
        });
        // 如果是短公式（不包含换行，也没有矩阵/方程组），强转为行内公式
        if (inner.length < 80 && !inner.contains('\n') && !inner.contains(r'\begin')) {
            return ' \$${inner}\$ ';
        }
        return '\n\n\$\$$inner\$\$\n\n';
    });
    
    return result;
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
