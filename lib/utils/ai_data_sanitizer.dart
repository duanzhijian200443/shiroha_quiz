import 'dart:convert';

class AiDataSanitizer {
  // 1. 强力 JSON 净化与防幻觉解析
  static List<Map<String, dynamic>> cleanAndParseJson(String rawText) {
    if (rawText.trim().isEmpty) {
      throw Exception("大模型返回了空内容。可能是触发了风控拦截，或使用了不兼容的 API 格式。");
    }

    String cleanText = rawText;
    
    // 1. 优先提取 ```json ... ``` 代码块中的纯净内容
    final codeBlockMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false).firstMatch(cleanText);
    
    if (codeBlockMatch != null) {
      cleanText = codeBlockMatch.group(1)!.trim();
    } else {
      // 2. 如果模型没有加代码块，采用降级策略：精确匹配 JSON 结构特征，绝不盲猜首个花括号
      // 寻找 {" 或 [{ 或 [ { 的起始位置
      int objStart = cleanText.indexOf(RegExp(r'\{\s*"'));
      int arrStart = cleanText.indexOf(RegExp(r'\[\s*\{'));
      
      int startIdx = -1;
      if (objStart != -1 && arrStart != -1) {
        startIdx = objStart < arrStart ? objStart : arrStart;
      } else if (objStart != -1) {
        startIdx = objStart;
      } else if (arrStart != -1) {
        startIdx = arrStart;
      }

      if (startIdx != -1) {
        cleanText = cleanText.substring(startIdx);
        // 寻找最后一个闭合符号
        int lastBrace = cleanText.lastIndexOf('}');
        int lastBracket = cleanText.lastIndexOf(']');
        int endIdx = lastBrace > lastBracket ? lastBrace : lastBracket;
        
        if (endIdx != -1) {
          cleanText = cleanText.substring(0, endIdx + 1);
        } else {
          throw Exception("JSON 括号未闭合。");
        }
      } else {
        throw Exception("未能从 AI 回复中提取到有效的 JSON 代码块或对象结构。");
      }
    }

    // 处理非法的物理换行符（将其替换为 JSON 合法的转义换行）
    // 注意：只替换 JSON 字符串值内部的换行符，绝对不能破坏括号、逗号等结构外部的物理换行！
    cleanText = cleanText.replaceAll('\r', '');
    cleanText = cleanText.replaceAllMapped(RegExp(r'"(?:[^"\\]|\\.)*"', dotAll: true), (match) {
      String str = match.group(0)!;
      str = str.replaceAll('\n', '\\n');
      
      // 核心防御：修复大模型未转义的 LaTeX 反斜杠（如 \mu, \frac 等引发的 JSON 解析崩溃）
      // 保留 \", \\, \uXXXX (合法 unicode 转义), \/
      // 注意：\u 后面必须是4位十六进制才是合法 JSON unicode 转义，否则(如 \underline, \upsilon)会崩溃
      str = str.replaceAllMapped(RegExp(r'\\(["/\\]|u[0-9a-fA-F]{4})|\\'), (m) {
        // group(1) 存在 → 这是合法转义序列，原样保留
        if (m.group(1) != null) return m.group(0)!;
        // 无 group(1) → 孤立反斜杠（如 \frac, \underline），双重转义
        return '\\\\';
      });
      
      return str;
    });



    dynamic decoded;
    try {
      decoded = jsonDecode(cleanText);
    } catch (e) {
      // 修复由于强制替换 \n 导致的括号外非法字符，尝试通过截断修复
      try {
        int lastBracket = cleanText.lastIndexOf(']');
        int lastBrace = cleanText.lastIndexOf('}');
        int lastValid = lastBracket > lastBrace ? lastBracket : lastBrace;
        if (lastValid != -1) {
          String repaired = cleanText.substring(0, lastValid + 1);
          decoded = jsonDecode(repaired);
        } else {
          rethrow;
        }
      } catch (e2) {
        throw Exception("JSON解析失败且无法修复: $e (自动修复也失败: $e2)\n内容片段: ${cleanText.length > 100 ? cleanText.substring(0, 100) : cleanText}...");
      }
    }

    decoded = _restoreBslash(decoded);

    List<dynamic> questionsList = [];
    
    if (decoded is Map<String, dynamic>) {
      // 优先提取 questions 数组
      if (decoded.containsKey('questions') && decoded['questions'] is List) {
        questionsList = decoded['questions'];
      } else if (decoded.containsKey('anchors') && decoded['anchors'] is List) {
        questionsList = decoded['anchors'];
      } else {
        // 如果是单个对象也装入数组
        questionsList = [decoded];
      }
    } else if (decoded is List) {
      questionsList = decoded;
    }

    final List<Map<String, dynamic>> finalQuestions = [];
    
    for (var item in questionsList) {
      if (item is! Map<String, dynamic>) continue;
      final q = item;
      int currentType = q['type'] as int? ?? 0;
      
        if (q['content'] == null || q['content'].toString().trim().isEmpty) {
          if (q['standard_answer'] != null && q['standard_answer'].toString().trim().isNotEmpty) {
            q['content'] = "[纯答案提取]\n${q['standard_answer']}";
          } else if (q['explanation'] != null && q['explanation'].toString().trim().isNotEmpty) {
            q['content'] = "[解析提取]\n${q['explanation']}";
          } else {
            q['content'] = "无题干";
          }
        }
        
        if (q['content'] != null) q['content'] = cleanLatexBeforeDB(q['content'].toString());
        if (q['standard_answer'] != null) q['standard_answer'] = cleanLatexBeforeDB(q['standard_answer'].toString());
        if (q['explanation'] != null) q['explanation'] = cleanLatexBeforeDB(q['explanation'].toString());
        
        q.remove('sub_questions');

        // 双重防线：自动检测并剥离题干中残留的 A,B,C,D 选项
        final contentStr = q['content']?.toString() ?? '';
        final optionRegex = RegExp(
          r'[\s\n]*(?:\(|（)?\s*A\s*(?:\)|）|\.|、|\s)\s*([\s\S]+?)'
          r'(?:\(|（)?\s*B\s*(?:\)|）|\.|、|\s)\s*([\s\S]+?)'
          r'(?:\(|（)?\s*C\s*(?:\)|）|\.|、|\s)\s*([\s\S]+?)'
          r'(?:\(|（)?\s*D\s*(?:\)|）|\.|、|\s)\s*([\s\S]*)$',
          caseSensitive: false,
        );
        final optionMatch = optionRegex.firstMatch(contentStr);
        if (optionMatch != null) {
          final optA = optionMatch.group(1)!.trim();
          final optB = optionMatch.group(2)!.trim();
          final optC = optionMatch.group(3)!.trim();
          final optD = optionMatch.group(4)!.trim();
          
          q['content'] = contentStr.substring(0, optionMatch.start).trim();
          
          final existingOpts = q['options'] as List?;
          if (existingOpts == null || existingOpts.isEmpty || existingOpts.every((o) => o.toString().trim().isEmpty)) {
            q['options'] = [
              "A. ${cleanLatexBeforeDB(optA)}",
              "B. ${cleanLatexBeforeDB(optB)}",
              "C. ${cleanLatexBeforeDB(optC)}",
              "D. ${cleanLatexBeforeDB(optD)}"
            ];
          }
          if (currentType == 3) {
            currentType = 0;
            q['type'] = 0;
          }
        }
        
        if (currentType == 2 || currentType == 3) {
          q['options'] = []; // 填空/简答强行清空选项
        } else {
          final opts = q['options'] as List?;
          if (opts != null && opts.isNotEmpty && opts.any((o) => o.toString().trim().isNotEmpty)) {
            q['type'] = currentType == 1 ? 1 : 0; // 有选项保持多选或归为单选
          } else {
            // 被识别成了选择题，但没有提取出选项，则直接强制降级为简答题
            q['type'] = 3;
            q['options'] = [];
          }
        }
        finalQuestions.add(q);
    }
    return finalQuestions;
  }

static String cleanLatexBeforeDB(String text) {
    if (text.isEmpty) return text;
    String result = normalizeDelimiters(text);

    // 规则一（修正版）：允许矩阵前有系数，含 matrix 基础环境。两端加换行符确保 Markdown 块级识别
    result = result.replaceAllMapped(
      RegExp(
        r'\$(?!\$)([^$]*\\begin\{(?:pmatrix|bmatrix|cases|vmatrix|matrix)'
        r'[^$]*\\end\{(?:pmatrix|bmatrix|cases|vmatrix|matrix)\}[^$]*)\$(?!\$)'
      ),
      (m) => '\n\$\$${m.group(1)}\$\$\n',
    );

    // 规则二（修正版）：只降级矩阵间的短运算符，不做全局 $$$ 替换
    result = result.replaceAllMapped(
      RegExp(r'\$\$([+\-=,，\s]{1,6}[\w\d_\^]{0,4})\$\$'),
      (m) => '\$${m.group(1)}\$',
    );

    // 规则三：把紧贴在 $$ 前面的系数变量吸收进数学块内
    result = result.replaceAllMapped(
      RegExp(
        r'([a-zA-Z_]\w*)\s*\$\$(\\begin\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)}'
        r'[\s\S]*?\\end\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)\})\$\$'
      ),
      (m) => '\n\$\$${m.group(1)}${m.group(2)}\$\$\n',
    );

    return result;
  }

  // 2. 极简 LaTeX 公式格式化
  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    String result = text;
    
    result = result.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');

    // 只还原明确作为普通文本换行的 \n，不要误伤合法转义
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    // 修复大模型过度转义的下划线填空线，例如 \_\_\_ -> ___
    result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
      return '_' * (match.group(0)!.length ~/ 2);
    });

    // 🛡️ 白名单模式兜底包裹：把高置信度裸露指令自动包裹进 $...$
    result = _autoWrapBareLatex(result);

    // 新增：清理冲突产生的三连美元符，以 r'$$' 规范化，规避 Dart 字符替换 Bug
    result = result.replaceAll(RegExp(r'\$\$\$'), r'$$');

    return result;
  }

  /// 🔧 将裸 LaTeX 命令（未被 \$..\$ 或 \$\$..\$\$ 包裹的 \cmd{} 形式）自动包裹进 \$..\$。
  /// 安全机制：
  ///   - 已包裹的 \$..\$、\$\$..\$\$、\(...\)、\[...\] 先被占位替换，不会被重复处理
  ///   - \{ \} 等转义符号不触发包裹（不是真正的数学命令）
  ///   - 纯中文段落不会被吸入
  static String _autoWrapBareLatex(String text) {
    if (text.isEmpty || !text.contains(r'\')) return text;

    final List<String> saved = [];
    String s = text;

    // Phase 1: 保护已经包裹好的块，防止被二次处理
    s = s.replaceAllMapped(RegExp(r'\$\$[\s\S]*?\$\$'), (m) {
      saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
    });
    s = s.replaceAllMapped(RegExp(r'\$(?!\$)[\s\S]*?\$'), (m) {
      saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
    });
    s = s.replaceAllMapped(RegExp(r'\\\([\s\S]*?\\\)'), (m) {
      saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
    });
    s = s.replaceAllMapped(RegExp(r'\\\[[\s\S]*?\\\]'), (m) {
      saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
    });

    // Phase 2: 白名单模式包裹高置信度裸露指令
    // 仅针对: \frac, \sqrt, \sum, \int, \lim, \prod, \oint
    final RegExp whitelistRegExp = RegExp(r'\\(frac|sqrt|sum|int|lim|prod|oint)');
    int offset = 0;
    while (true) {
      final match = whitelistRegExp.firstMatch(s.substring(offset));
      if (match == null) break;

      int start = offset + match.start;
      int end = offset + match.end;
      
      // 向前扫描平衡大括号
      int bracesCount = 0;
      bool hasOpened = false;
      int i = end;
      for (; i < s.length; i++) {
        if (s[i] == '{') {
          bracesCount++;
          hasOpened = true;
        } else if (s[i] == '}') {
          bracesCount--;
        } else if (s[i] == '\\') {
          // 跳过转义字符
          i++;
        } else if (!hasOpened && RegExp(r'[a-zA-Z0-9]').hasMatch(s[i])) {
           // 如果还没有遇到左括号，且遇到了字母数字，可能类似于 \frac12，我们保守处理不贪婪
           if (i - end >= 2) break;
        } else if (!hasOpened && RegExp(r'[\s\^_]').hasMatch(s[i])) {
           // 允许空格或上下标
        } else if (!hasOpened) {
           break;
        }
        
        if (hasOpened && bracesCount == 0) {
          // 如果这之后紧接着又是括号，说明可能有多个参数，比如 \frac{}{}
          if (i + 1 < s.length && s[i+1] == '{') {
            continue;
          }
          i++; // include the closing brace
          break;
        }
      }

      if (hasOpened && bracesCount != 0) {
        // 不平衡，放弃处理
        offset = start + 1;
        continue;
      }

      String wrappedTarget = s.substring(start, i);
      
      // 避免重复保护
      if (wrappedTarget.contains('⁕')) {
        offset = i;
        continue;
      }

      saved.add('\$' + wrappedTarget + '\$');
      String placeholder = '⁕${saved.length - 1}⁕';
      
      s = s.substring(0, start) + placeholder + s.substring(i);
      offset = start + placeholder.length;
    }

    // Phase 3: 恢复占位符
    for (int i = saved.length - 1; i >= 0; i--) {
      s = s.replaceFirst('⁕$i⁕', saved[i]);
    }
    
    return s;
  }

  /// 🔧 判断给定的字符串是否看起来是一个合法的 LaTeX 数学公式。
  static bool isLikelyMathFormula(String tex) {
    final cleanTex = tex.trim();
    if (!cleanTex.contains(r'\')) return false;

    // 常见数学公式特征关键字
    const mathKeywords = [
      r'\frac', r'\sum', r'\int', r'\lim', r'\sqrt', r'\partial', r'\infty',
      r'\oint', r'\iint', r'\iiint', r'\left', r'\right', r'\begin', r'\end',
      r'\cdot', r'\mathrm', r'\mathbf', r'\text', r'\xlongequal', r'\hat',
      r'\alpha', r'\beta', r'\gamma', r'\delta', r'\theta', r'\lambda', r'\pi',
      r'\sigma', r'\omega', r'\mu', r'\phi', r'\psi', r'\xi', r'\eta',
      r'\Sigma', r'\Delta', r'\Omega', r'\Gamma', r'\Phi', r'\Psi', r'\Theta',
    ];

    for (final keyword in mathKeywords) {
      if (cleanTex.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  static dynamic _restoreBslash(dynamic node) {
    if (node is String) {
      return node.replaceAll('BSLASH', '\\');
    } else if (node is List) {
      return node.map((e) => _restoreBslash(e)).toList();
    } else if (node is Map<String, dynamic>) {
      final Map<String, dynamic> newMap = {};
      node.forEach((key, value) {
        newMap[key] = _restoreBslash(value);
      });
      return newMap;
    }
    return node;
  }
}
