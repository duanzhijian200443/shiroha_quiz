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
      // 保留 \", \\, \u, \/，其他一律强制转义为双斜杠
      str = str.replaceAllMapped(RegExp(r'\\\\|\\([^"u/])'), (m) {
        if (m.group(0) == '\\\\') return '\\\\';
        return '\\\\${m.group(1)}';
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
            q['content'] = "[纯答案提取]\n" + q['standard_answer'].toString();
          } else if (q['explanation'] != null && q['explanation'].toString().trim().isNotEmpty) {
            q['content'] = "[解析提取]\n" + q['explanation'].toString();
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

  static String normalizeDelimiters(String text) {
    if (text.isEmpty) return text;
    // \(...\) → $...$
    String result = text.replaceAllMapped(
      RegExp(r'\\\((.+?)\\\)', dotAll: true),
      (m) => '\$${m.group(1)}\$',
    );
    // \[...\] → $$...$$
    result = result.replaceAllMapped(
      RegExp(r'\\\[(.+?)\\\]', dotAll: true),
      (m) => '\$\$${m.group(1)}\$\$',
    );
    return result;
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
    String result = normalizeDelimiters(text);
    
    result = result.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');

    // 只还原明确作为普通文本换行的 \\n，不要误伤合法转义
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    // 修复大模型过度转义的下划线填空线，例如 \_\_\_ -> ___
    result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
      return '_' * (match.group(0)!.length ~/ 2);
    });

    // 终极替换原则：只做一件事，把明确在 $ 内的块级环境升级为 $$
    result = result.replaceAllMapped(
      RegExp(r'\$(?!\$)([^$]*\\begin\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)'
             r'[\s\S]*?\\end\{(?:pmatrix|bmatrix|matrix|cases|vmatrix)\}[^$]*)\$(?!\$)'),
      (m) => '\$\$${m.group(1)}\$\$',
    );
    // 在 $$ 前后加换行，确保 markdown 解析器识别为块级
    result = result.replaceAll(RegExp(r'(?<!\n)\$\$'), '\n\$\$');
    result = result.replaceAll(RegExp(r'\$\$(?!\n)'), '\$\$\n');

    return result;
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
