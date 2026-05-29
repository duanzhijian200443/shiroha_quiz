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
        String repaired = '${cleanText.substring(0, lastBrace + 1)}]';
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

  // 2. 极简 LaTeX 公式格式化（剔除所有复杂脆弱的正则，交还渲染权）
  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    String result = text;

    // 1. 彻底剥离 <think>...</think> 思考过程标签（以防万一泄露到正文）
    result = result.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');

    // 2. 统一将 \begin{split} 替换为 \begin{aligned}，因为 flutter_math_fork 不支持 split
    result = result.replaceAll(r'\begin{split}', r'\begin{aligned}');
    result = result.replaceAll(r'\end{split}', r'\end{aligned}');

    // 3. 修复大模型过度转义的下划线填空线，例如 \_\_\_ -> ___
    result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
      return '_' * (match.group(0)!.length ~/ 2);
    });

    // 4. 将孤立的填空占位符 $____ 标准化为 ____，防止 $ 被解析为未闭合的 LaTeX 定界符
    result = result.replaceAllMapped(RegExp(r'(?<![\\\$])\$(_+)(?!\$)'), (match) {
      return match.group(1)!;
    });
    
    // 5. 如果有 $____$ 这种包裹的，也直接剥离掉 $，变成 ____
    result = result.replaceAllMapped(RegExp(r'\$(_+)\$'), (match) {
      return match.group(1)!;
    });

    // 6. 修复多余的文本转义（\n -> newline）
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    // 7. 【关键恢复】将 ```math/latex/tex 代码块转成 $$ 块级公式
    //    大模型有时会把公式包在 ```math ... ``` 里，必须在渲染前转换回来
    result = result.replaceAllMapped(
      RegExp(r'```(?:math|latex|tex)?\s*([\s\S]+?)\s*```', caseSensitive: false),
      (match) {
        final inner = match.group(1)!.trim();
        // 如果内部已经有 $ 包裹，直接展开
        if (inner.startsWith(r'$') && inner.endsWith(r'$')) {
          return '\n\n$inner\n\n';
        }
        return '\n\n\$\$$inner\$\$\n\n';
      },
    );

    // 8. 【核心定界符转换】$$ → \[...\]（块级）
    //    必须在 $ → \( 之前处理，避免 $$ 被误识别为两个 $
    result = result.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$', dotAll: true),
      (m) => '\n\n\\[${m.group(1)!.trim()}\\]\n\n',
    );

    // 9. 【核心定界符转换】$...$ → \(...\)（行内）
    //    只转换定界符，LaTeX 内容原封不动，是原 200 行 TOKENIZER 的安全精华
    result = result.replaceAllMapped(
      RegExp(r'(?<!\$)\$(?!\$)([^\$\n]+?)\$(?!\$)'),
      (m) => '\\(${m.group(1)!}\\)',
    );

    return result;
  }
}
