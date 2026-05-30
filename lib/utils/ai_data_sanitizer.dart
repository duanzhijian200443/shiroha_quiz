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
    cleanText = cleanText.replaceAllMapped(RegExp(r'"(?:[^"\\]|\\.)*"'), (match) {
      return match.group(0)!.replaceAll('\n', '\\n');
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
        
        q.remove('sub_questions');
        
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

  // 2. 极简 LaTeX 公式格式化
  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    String result = text;

    result = result.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');
    result = result.replaceAll(r'\begin{split}', r'\begin{aligned}');
    result = result.replaceAll(r'\end{split}', r'\end{aligned}');

    // 3. 修复大模型过度转义的下划线填空线，例如 \_\_\_ -> ___
    result = result.replaceAllMapped(RegExp(r'(\\_){2,}'), (match) {
      return '_' * (match.group(0)!.length ~/ 2);
    });

    // 4. 修复填空题产生的包裹占位符 $____$
    result = result.replaceAllMapped(RegExp(r'\$(_+)\$'), (match) {
      return match.group(1)!;
    });

    // 只还原明确作为普通文本换行的 \\n，不要误伤合法转义
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAllMapped(RegExp(r'\\t(?![a-zA-Z])'), (m) => '\t');

    result = result.replaceAllMapped(
      RegExp(r'```(?:math|latex|tex)?\s*([\s\S]+?)\s*```', caseSensitive: false),
      (match) {
        final inner = match.group(1)!.trim();
        if (inner.startsWith(r'$') && inner.endsWith(r'$')) {
          return '\n\n$inner\n\n';
        }
        return '\n\n\$\$$inner\$\$\n\n';
      },
    );

    result = result.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$', dotAll: true),
      (m) => '\n\n\\[${m.group(1)!.trim()}\\]\n\n',
    );

    // 【核心定界符转换】$...$ → \(...\)（行内）
    // 移除对换行符的限制，允许公式跨行（替换 [^\$\n] 为 [^\$]）
    result = result.replaceAllMapped(
      RegExp(r'(?<!\$)\$(?!\$)([^\$]+?)\$(?!\$)'),
      (m) => '\\(${m.group(1)!}\\)',
    );

    if (!result.contains(r'\(') && !result.contains(r'\[') && !result.contains(r'$')) {
      if (result.contains(r'\frac') || result.contains(r'\sqrt') || result.contains(r'\sum')) {
        result = '\\($result\\)';
      }
    }

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
