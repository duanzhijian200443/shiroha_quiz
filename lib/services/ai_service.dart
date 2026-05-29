import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../core/database/database_helper.dart';
import '../utils/ai_data_sanitizer.dart';

class AiService {
  static final AiService instance = AiService._();
  AiService._();

  // 核心修复：智能 URL 路由构建器，完美兼容 v1 和 v4 协议
  String _buildChatUrl(String baseUrl, bool isZhipu) {
    if (isZhipu) {
      return baseUrl.endsWith('/v4') ? "$baseUrl/chat/completions" : "$baseUrl/v4/chat/completions";
    }
    return baseUrl.endsWith('/v1') ? "$baseUrl/chat/completions" : "$baseUrl/v1/chat/completions";
  }

  // 核心容错：提取内容，自动兼容含有 reasoning_content 的深度思考模型（如老版 DeepSeek R1）
  String _extractContent(String responseBody) {
    try {
      final message = jsonDecode(responseBody)['choices'][0]['message'];
      String content = (message['content'] ?? "").toString();
      if (content.trim().isEmpty && message['reasoning_content'] != null) {
        content = message['reasoning_content'].toString();
      }
      return content;
    } catch (_) {
      return "";
    }
  }

  Future<String> judgeAnswer(String question, String standardAnswer, String userAnswer) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) return "【系统提示】未激活文本 AI 引擎";

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) return "【系统提示】引擎配置不完整";

    final prompt = '''
    你是一个严谨的考研助教。
    【题目】$question
    【标准答案/得分点】$standardAnswer
    【学生的回答】$userAnswer
    请对比标准答案，对学生回答打分(0-100分)，简明指出答对和遗漏的点。直接输出评价。
    ''';

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}]})).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          return jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "解析失败";
        }
        return "【请求失败】Gemini 错误: ${res.statusCode}";
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.3})).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final extracted = _extractContent(res.body);
          return extracted.isNotEmpty ? extracted : "解析失败";
        }
        return "【请求失败】API 错误: ${res.statusCode}";
      }
    } catch (e) {
      return "【网络异常】$e";
    }
  }

  Future<List<Map<String, dynamic>>> generateQuestions(String topic, {int count = 1, int type = 0}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    String typeReq = type == 0 ? "全部为【单选题】，必须提供 4 个选项。" : (type == 2 ? "全部为【填空题】，用 '___' 表示填空处。" : (type == 3 ? "全部为【简答题】。" : "混合生成【单选、填空、简答】。"));

    String exampleJson = type == 0 
        ? '[{"type": 0, "content": "题干", "options": ["A.", "B."], "standard_answer": "A", "explanation": "解析"}]'
        : (type == 2 
            ? '[{"type": 2, "content": "题干(用___表示填空)", "options": [], "standard_answer": "答案", "explanation": "解析"}]'
            : (type == 3 
                ? '[{"type": 3, "content": "简答题干", "options": [], "standard_answer": "标准答案", "explanation": "解析"}]'
                : '[{"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A", "explanation": "解析"}]'));

    final prompt = '''
    你是一个命题专家。请根据知识点：“$topic”，生成 $count 道题。
    题型要求：$typeReq
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    $exampleJson
    【致命警告：JSON转义】遇到 LaTeX 公式，所有反斜杠必须双重转义！例如 \\pi。
    ''';

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": temp, "maxOutputTokens": 8192}})).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final Map<String, dynamic> reqBody = {"model": model, "messages": [{"role": "user", "content": prompt}]};
        if (effort.isNotEmpty) {
          reqBody["reasoning_effort"] = effort;
        } else {
          reqBody["temperature"] = temp;
        }
        reqBody["max_tokens"] = 8192;
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode(reqBody)).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      }
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("生成失败: $e");
    }
  }

  Future<List<Map<String, dynamic>>> generateExamPaper({required String topic, required int singleCount, required int fillCount, required int shortCount, String? customPrompt}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    String prompt = '''
    你是一个命题专家。请根据知识点：“$topic”，生成 ${singleCount + fillCount + shortCount} 道题的测试卷。
    1. 【单选题】$singleCount 道。(type: 0)
    2. 【填空题】$fillCount 道。题干用 '___' 表示。(type: 2)
    3. 【简答题】$shortCount 道。(type: 3)
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    [
      {"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A", "explanation": "解析"},
      {"type": 2, "content": "填空题干(用___)", "options": [], "standard_answer": "填空答案", "explanation": "解析"},
      {"type": 3, "content": "简答题干", "options": [], "standard_answer": "简答答案", "explanation": "解析"}
    ]
    【致命警告：JSON转义】遇到 LaTeX 公式，所有反斜杠必须双重转义！例如 \\pi。
    ''';
    // LaTeX constraint injected into prompt after base definition
    prompt += '\n    【LaTeX子集约束-渲染引擎限制必须遵守】\n'
        '    允许: \\\\frac \\\\sqrt \\\\sum \\\\int \\\\prod \\\\lim 及希腊字母 \\\\alpha~\\\\omega\n'
        '    允许: \\\\leq \\\\geq \\\\neq \\\\approx \\\\in \\\\subset \\\\cup \\\\cap \\\\vec \\\\sin \\\\cos \\\\tan \\\\log \\\\ln \\\\pm \\\\cdot \\\\times \\\\div\n'
        '    填空占位符必须用普通文本___绝不加dollar包裹，严禁放在dollar内部\n'
        '    严禁: \\\\begin{cases} \\\\begin{matrix} \\\\mathbb \\\\mathcal \\\\mathfrak \\\\def \\\\newcommand\n'
        '    严禁: 超过3层嵌套的\\\\frac或\\\\sqrt\n';
    if (customPrompt != null && customPrompt.isNotEmpty) prompt += "\n\n【特殊要求】\n$customPrompt";

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": temp, "maxOutputTokens": 8192}})).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final Map<String, dynamic> reqBody = {"model": model, "messages": [{"role": "user", "content": prompt}]};
        if (effort.isNotEmpty) {
          reqBody["reasoning_effort"] = effort;
        } else {
          reqBody["temperature"] = temp;
        }
        reqBody["max_tokens"] = 8192;
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode(reqBody)).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      }
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("生成试卷失败: $e");
    }
  }

  // 核心抽离：单块文本解析（处理几千字的小块，保证永不超时和截断）
  Future<List<Map<String, dynamic>>> _parseSingleChunkToQuestions(String rawText, Map<String, dynamic> profile) async {
    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';

    final prompt = '''
    你是一个顶级的教育数据清洗专家。请将以下文本解析为结构化的题库 JSON 数组。如果没有检测到任何有效题目，直接返回空数组 []。

    【核心题型字典与 JSON 格式】
    请务必根据题目特征，自动将其分类为以下三种题型之一，并严格使用对应的 JSON 格式：
    1. 选择题 (type: 0)：只要题目带有 A, B, C, D 等选项，即为选择题。
       格式: {"type": 0, "content": "题干", "options": ["A. xxx", "B. xxx", "C. xxx", "D. xxx"], "standard_answer": "A", "explanation": "解析"}
    2. 填空题 (type: 2)：题干中有下划线、括号留空，或明确要求填空的。
       格式: {"type": 2, "content": "题干", "options": [], "standard_answer": "填空内容", "explanation": "解析"}
    3. 解答/计算/证明题 (type: 3)：没有选项，要求计算、求解或证明的。
       格式: {"type": 3, "content": "题干", "options": [], "standard_answer": "最终结果或略", "explanation": "详细解答过程"}

    【⚠️ 大题防撕裂最高法则（绝对红线）】
    遇到包含 (I)、(II)、(III) 或 (1)、(2) 等多个小问的综合性大题时，**绝对禁止将其拆分为多道独立的题**！
    你必须将它作为【一道完整的大题(type: 3)】，把所有小问合并写进 `content` 中，并将所有小问的解答合并写进 `explanation` 中。

    【✂️ 题干与解析精准剥离法则（核心指令）】
    在扫描图片或文本时，务必将“题目本身（题干）”与附带的“题目答案/解析/分析/解”严格分离开来！
    - `content` (题干)：**只能**包含题目本身的问题描述、背景资料和提问。**绝对禁止**将“分析”、“解”、“证明过程”、“答案是”等答题过程混入题干！
    - `explanation` (解析)：必须把原图/原文中的“分析”、“详解”、“解题思路”单独提取出来，存放在此字段。
    你必须具备“剪刀手”能力，绝不能把题目和答案无脑连在一起输出！

    【致命格式警告 - JSON LaTeX 转义】
    由于你必须输出合法的 JSON 字符串，所有 LaTeX 公式中的反斜杠 `\\` 必须按照 JSON 标准进行转义。
    ❌ 错误写法: "content": "\\\$\\frac{1}{2}\\\$" (单斜杠是非法转义，会导致解析崩溃)
    ✅ 正确写法: "content": "\\\$\\\\frac{1}{2}\\\$" (反斜杠必须写两遍)
    这适用于所有指令：\\\\sum, \\\\frac, \\\\lim, \\\\boldsymbol, \\\\alpha 等。

    【🚨 填空题公式崩溃警告（极其重要）】
    如果是填空题，**绝对禁止**将连续的下划线 `___` 放在 LaTeX 公式符号 `\$` 内部！
    因为 `_` 在 LaTeX 中是下标语法，`\$a = ___\$` 会引发严重的语法崩溃（导致公式变红报错）。
    ❌ 崩溃写法: "则 \\\$ a = _____ \\\$" (下划线在 \$ 内部，必报错！)
    ✅ 正确写法: "则 \\\$ a = \\\$ _____" (必须把下划线放在 \$ 外部的普通文本区！)

    【🏞️ 绝对保留图片标签警告（生死红线）】
    原文本中如果存在类似 `![alt](sandbox://...)` 的 Markdown 图片标签，它们代表着极其重要的配图！
    你在提取题干（content）或解析（explanation）时，**必须原封不动地保留所有图片标签，绝对不允许删除、修改或弄丢任何一个图片链接！**
    必须把图片标签准确放置在题目描述对应的原始位置。

    【🌀 全并发智能内核：题干与答案异步拼图模式（最高层级指令）】
    认定这个事实：当 PDF 分块并发处理时，一个批次可能只包含题干而没有答案，另一批次可能只有答案而没有题干。
    你必须支持两种输出模式：
    - 模式 A（正常完整题目）: {"q_num": "题号，如 1、2、或空字符串", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": "答案", "explanation": "解析"}
    - 模式 B（只有题干，未见答案）: {"q_num": "题号", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": null, "explanation": null}
    - 模式 C（只有答案页，未见题干）: {"q_num": "题号", "type": null, "content": null, "standard_answer": "答案", "explanation": "解析"}
    关键：当你看到纯答案页（如 “1. A  2. B  3. C” 或 “参考答案: 1.B”）时，**绝对不允许丢弃**！必须按模式 C 输出，将每道题的答案逆向提取出来！
    `q_num` 字段必须尽可能识别原文中的题目编号（如 "1"、"2"、"3"），它将用于全局归并算法对题干和答案进行拼图配对。

    【输出格式最高指令】
    你必须且只能输出合法的 JSON 数组，**绝对禁止**在 JSON 外部输出任何多余的闲聊、问候语、警告解释或确认语。
    你的输出必须严格以 "[" 开头，以 "]" 结尾。

    【LaTeX子集约束-渲染引擎限制必须遵守】
    允许: \\frac \\sqrt \\sum \\int \\prod \\lim 及希腊字母 \\alpha~\\omega
    允许: \\leq \\geq \\neq \\approx \\in \\subset \\cup \\cap \\vec \\sin \\cos \\tan \\log \\ln \\pm \\cdot \\times \\div
    填空占位符必须用普通文本___绝不加dollar包裹，严禁放在dollar内部
    严禁: \\begin{cases} \\begin{matrix} \\mathbb \\mathcal \\mathfrak \\def \\newcommand
    严禁: 超过3层嵌套的\\frac或\\sqrt

    【待解析文本】
    <document>
    $rawText
    </document>
    ''';

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.1, "maxOutputTokens": 8192, "responseMimeType": "application/json"}}))
            .timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: ${res.statusCode} | Body: ${res.body}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.1, "max_tokens": 8192, "response_format": {"type": "json_object"}}))
            .timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode} | Body: ${res.body}");
        }
      }
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("块级解析失败: $e");
    }
  }

  Future<List<Map<String, dynamic>>> _findQuestionAnchors(String rawText, Map<String, dynamic> profile) async {
    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';

    final prompt = '''
    你是一个文档结构分析专家。请通读以下试卷全文，找到每一道独立试题（包含其题干、选项、答案和所有解析内容）的起始和结束物理边界。
    
    【输出要求】
    你必须且只能输出合法的 JSON 数组，绝不允许输出多余的解释。格式如下：
    [
      {"q_num": 1, "start": "第一题开头的15个字符...", "end": "第一题解析结尾的15个字符..."},
      {"q_num": 2, "start": "第二题开头的15个字符...", "end": "第二题解析结尾的15个字符..."}
    ]

    【极端重要警告】
    1. 绝对不要尝试输出全文！你只需要返回坐标字符串（start 和 end）。
    2. start 和 end 必须是你从原文中一字不差复制出来的连续 15-20 个字符（包含空格、标点、甚至是图片标签的一部分）。
    3. 如果一道题包含多个小问（如(1)(2)），必须将它们视为一道完整的大题，只返回大题开头和最后一个小问解答结尾的坐标。
    4. "start" 是题干的第一句话，"end" 是这道题最终解答的最后一句话。

    【待解析文本】
    <document>
    $rawText
    </document>
    ''';

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.1, "maxOutputTokens": 4096, "responseMimeType": "application/json"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: ${res.statusCode}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.1, "max_tokens": 4096, "response_format": {"type": "json_object"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode}");
        }
      }
      
      // 提取 JSON：不依赖整体 JSON 结构，寻找最外层或包含数组的中括号
      int startIdx = responseText.indexOf('[');
      int endIdx = responseText.lastIndexOf(']');
      
      if (startIdx != -1 && endIdx != -1 && startIdx < endIdx) {
        String jsonStr = responseText.substring(startIdx, endIdx + 1);
        try {
          // 借用清理单斜杠防崩溃逻辑
          final cleaned = AiDataSanitizer.cleanAndParseJson(jsonStr);
          if (cleaned.isNotEmpty) {
            return cleaned;
          }
        } catch (e) {
           debugPrint("尝试提取数组解析失败: $e");
        }
      }
      
      throw Exception("未能从 AI 回复中提取到任何有效的坐标对象数组。");
    } catch (e) {
      debugPrint("雷达定位阶段失败: $e");
      return [];
    }
  }

  // 宏观重构：两阶段 LLM 流水线架构
  Future<List<Map<String, dynamic>>> parseTextToQuestions(String rawText) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    // 第一阶段：雷达定位
    debugPrint("🚀 [第一阶段] 启动全文雷达扫描...");
    List<Map<String, dynamic>> anchors = await _findQuestionAnchors(rawText, profile);
    
    List<String> questionBlocks = [];
    if (anchors.isNotEmpty) {
      debugPrint("✅ 成功定位 ${anchors.length} 道题目坐标，开始本地切割...");
      int lastEndIndex = 0;
      for (var anchor in anchors) {
        String startStr = anchor['start']?.toString().trim() ?? '';
        String endStr = anchor['end']?.toString().trim() ?? '';
        
        if (startStr.isEmpty || endStr.isEmpty) continue;

        int startIndex = rawText.indexOf(startStr, lastEndIndex);
        if (startIndex == -1) startIndex = rawText.indexOf(startStr); // 容错：全量查找
        
        int endIndex = rawText.indexOf(endStr, startIndex);
        
        if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
           int endCut = endIndex + endStr.length;
           if (endCut > rawText.length) endCut = rawText.length;
           questionBlocks.add(rawText.substring(startIndex, endCut));
           lastEndIndex = endCut;
        } else {
           debugPrint("⚠️ 警告：无法在原文中精准定位坐标: start=$startStr");
        }
      }
    }
    
    // 降级容错：如果定位完全失败或者提取数量极低，回退到按空行块切分的保守方案
    if (questionBlocks.length < 2) {
      debugPrint("⚠️ 第一阶段雷达定位失败或命中率过低，回退到智能分块算法...");
      questionBlocks.clear();
      StringBuffer currentChunk = StringBuffer();
      final paragraphs = rawText.split(RegExp(r'\n\s*\n'));
      for (var p in paragraphs) {
        final text = p.trim();
        if (text.isEmpty) continue;
        if (currentChunk.length + text.length > 4000) { // 安全微批次大小
          if (currentChunk.isNotEmpty) {
            questionBlocks.add(currentChunk.toString());
            currentChunk.clear();
          }
        }
        currentChunk.writeln(text);
        currentChunk.writeln();
      }
      if (currentChunk.isNotEmpty) {
        questionBlocks.add(currentChunk.toString());
      }
    }

    // 第二阶段：微批次精洗组装 (限制每个批次约 4000 字)
    List<String> microBatches = [];
    StringBuffer currentBatch = StringBuffer();
    for (String block in questionBlocks) {
       if (currentBatch.length + block.length > 4000 && currentBatch.isNotEmpty) {
           microBatches.add(currentBatch.toString());
           currentBatch.clear();
       }
       currentBatch.writeln(block);
       currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
       microBatches.add(currentBatch.toString());
    }

    // 调度引擎
    List<Map<String, dynamic>> allQuestions = [];
    int failCount = 0;
    debugPrint("🚀 [第二阶段] 将启动 ${microBatches.length} 次微批次精洗格式化...");
    
    for (int i = 0; i < microBatches.length; i++) {
      debugPrint("🚀 正在解析第 ${i + 1}/${microBatches.length} 块...");
      
      bool success = false;
      int retry = 0;
      
      while (retry < 3 && !success) {
        try {
          final chunkQuestions = await _parseSingleChunkToQuestions(microBatches[i], profile);
          allQuestions.addAll(chunkQuestions);
          success = true;
          // 防御性休眠：每批次请求之间强制休眠 3 秒，防止免费 API 触发 429 熔断
          if (i < microBatches.length - 1) {
              await Future.delayed(const Duration(seconds: 3));
          }
        } catch (e) {
          retry++;
          debugPrint("第 ${i + 1} 块解析失败 (重试 $retry/3): $e");
          if (retry >= 3) {
             failCount++;
          } else {
             int delaySeconds = e.toString().contains('429') ? (5 * retry) : 2;
             debugPrint("触发频率限制/错误，冷却 $delaySeconds 秒后重试...");
             await Future.delayed(Duration(seconds: delaySeconds));
          }
        }
      }
      
      if (failCount >= microBatches.length && microBatches.length > 1 && i == microBatches.length - 1) {
         throw Exception("所有请求全军覆没！请检查是否触发了大模型的并发限制（429 Too Many Requests），或网络完全断开。");
      }
    }
    
    if (allQuestions.isEmpty) {
       throw Exception("解析完成，但未提取到任何有效题目。可能是文档全为废话或已被 AI 拦截。");
    }
    
    debugPrint("【两阶段引擎】流水线完成，共提取 ${allQuestions.length} 题！");
    return allQuestions;
  }

  // --- 多模态视觉引擎：多图解析通道 ---
  Future<List<Map<String, dynamic>>> parseImagesWithVision(List<String> imagePaths) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('vision');
    if (profile == null) throw Exception("未激活视觉 AI 引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("视觉引擎配置不完整");
    if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    
    final isGemini = baseUrl.contains('generativelanguage.googleapis.com');

    final prompt = '''
    你是一个严谨的教育数据清洗专家。这是试卷/习题的高清扫描件图片。
    【最高指令：绝对防漏题】解析出其中的**每一道题**，绝对不允许遗漏！遇到代码或公式，必须用 Markdown 原样保留。数学公式请使用 \$ 包裹行内公式，\$\$ 包裹段落公式。
    
    【⚠️ 大题防撕裂最高法则（绝对红线）】
    遇到包含 (I)、(II)、(III) 或 (1)、(2) 等多个小问的综合性大题、材料阅读题时，**绝对禁止将其拆分为多道独立的题**！
    你必须将它作为【一道完整的大题】，把所有小问及其前面的**共用大背景题干**合并写进 `content` 中，并将所有小问的解答合并写进 `explanation` 中。绝不允许丢掉任何前置背景描述！
    
    【✂️ 题干与解析精准剥离法则（核心指令）】
    在扫描图片或文本时，务必将“题目本身（题干）”与附带的“题目答案/解析/分析/解”严格分离开来！
    - `content` (题干)：**只能**包含题目本身的问题描述、背景资料和提问。**绝对禁止**将“分析”、“解”、“证明过程”、“答案是”等答题过程混入题干！
    - `explanation` (解析)：必须把原图/原文中的“分析”、“详解”、“解题思路”单独提取出来，存放在此字段。
    你必须具备“剪刀手”能力，绝不能把题目和答案无脑连在一起输出！

    【🌀 全并发智能内核：题干与答案异步拼图模式（最高层级指令）】
    认定这个事实：当 PDF 分块并发处理时，一个批次可能只包含题干而没有答案，另一批次可能只有答案而没有题干。
    你必须支持两种输出模式：
    - 模式 A（正常完整题目）: {"q_num": "题号，如 1、2、或空字符串", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": "答案", "explanation": "解析"}
    - 模式 B（只有题干，未见答案）: {"q_num": "题号", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": null, "explanation": null}
    - 模式 C（只有答案页，未见题干）: {"q_num": "题号", "type": null, "content": null, "standard_answer": "答案", "explanation": "解析"}
    关键：当你看到纯答案页（如 “1. A  2. B  3. C” 或 “参考答案: 1.B”）时，**绝对不允许丢弃**！必须按模式 C 输出，将每道题的答案逆向提取出来！
    `q_num` 字段必须尽可能识别原文中的题目编号（如 "1"、"2"、"3"），它将用于全局归并算法对题干和答案进行拼图配对。

    【严格格式约束】直接输出纯 JSON 数组：
    [
      {"type": 0, "content": "选择题干", "options": ["A.", "B."], "standard_answer": "A", "explanation": "解析"},
      {"type": 2, "content": "填空题干，空格用 ___", "options": [], "standard_answer": "答案", "explanation": "解析"},
      {"type": 3, "content": "完整的大题或简答题干(含所有小问)", "options": [], "standard_answer": "略", "explanation": "所有小问的解析合并"}
    ]
    【致命警告：JSON转义】所有反斜杠必须经过严格的双重转义！例如 \\\\pi，否则你的输出会导致系统崩溃。
    ''';

    try {
      // 将所有图片转为 Base64 并进行极速压缩
      List<Map<String, dynamic>> imageContents = [];
      for (var path in imagePaths) {
        List<int> bytes = await File(path).readAsBytes();
        
        try {
          final image = img.decodeImage(Uint8List.fromList(bytes));
          if (image != null) {
            img.Image resized = image;
            // 并发模式下降低分辨率上限（900px/65%），减少单次请求体积，换取更快的响应时间
            if (image.width > 900) {
              resized = img.copyResize(image, width: 900);
            }
            bytes = img.encodeJpg(resized, quality: 65);
            debugPrint('多图预处理: 图片 $path 已压缩至 ${bytes.length / 1024} KB');
          }
        } catch (e) {
          debugPrint('图片压缩失败，回退使用原图: $e');
        }

        final base64Img = base64Encode(bytes);
        final mimeType = "image/jpeg";
        
        if (isGemini) {
          imageContents.add({"inline_data": {"mime_type": mimeType, "data": base64Img}});
        } else {
          imageContents.add({"type": "image_url", "image_url": {"url": "data:$mimeType;base64,$base64Img"}});
        }
      }

      debugPrint("🚀 正在组装 ${imagePaths.length} 张图片并向视觉大模型发起请求，请耐心等待 (约需几十秒到一分钟)...");
      final startTime = DateTime.now();

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            "contents": [{"parts": [{"text": prompt}, ...imageContents]}],
            "generationConfig": {"temperature": temp}
          }),
        ).timeout(const Duration(minutes: 8));

        if (res.statusCode == 200) {
          debugPrint("✅ Gemini Vision 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final data = jsonDecode(res.body);
          if (data['candidates'] == null || (data['candidates'] as List).isEmpty) throw Exception("Gemini 返回为空");
          return await compute(AiDataSanitizer.cleanAndParseJson, data['candidates'][0]['content']['parts'][0]['text']?.toString() ?? "");
        } else {
          throw Exception("Gemini 错误: ${res.statusCode}");
        }
      } else {
        final isZhipu = baseUrl.contains('bigmodel.cn');
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'},
          body: jsonEncode({
            "model": model,
            "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}, ...imageContents]}],
            "temperature": temp
          }),
        ).timeout(const Duration(minutes: 8));

        if (res.statusCode == 200) {
          debugPrint("✅ Vision API 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final data = jsonDecode(res.body);
          if (data['choices'] == null || (data['choices'] as List).isEmpty) throw Exception("API 返回为空");
          return await compute(AiDataSanitizer.cleanAndParseJson, data['choices'][0]['message']['content']?.toString() ?? "");
        } else {
          throw Exception("Vision API 错误: ${res.statusCode} - ${res.body}");
        }
      }
    } catch (e) {
      throw Exception("多图视觉解析异常: $e");
    }
  }

  Future<List<Map<String, dynamic>>> parseFileWithVision(String filePath) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('vision');
    if (profile == null) throw Exception("未激活视觉引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("视觉引擎配置不完整");
    if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    
    final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
    final isZhipu = baseUrl.contains('bigmodel.cn');
    final lowerPath = filePath.toLowerCase();
    final isPdf = lowerPath.endsWith('.pdf');
    final isDocx = lowerPath.endsWith('.docx');

    if (isDocx) throw Exception("视觉模型无法直接看懂 Word，请先另存为 PDF 或截图！");
    if (isPdf && !isGemini && !isZhipu) throw Exception("标准 OpenAI 协议不支持直传 PDF，请切换回 Gemini 或 智谱！");

    List<int> bytes = await File(filePath).readAsBytes();
    
    // 核心提速优化：如果传入的是图片，进行极速压缩与降采样
    if (!isPdf) {
      try {
        final image = img.decodeImage(Uint8List.fromList(bytes));
        if (image != null) {
          img.Image resized = image;
          // 如果图片宽度大于 1024，进行等比例缩小，极大降低 Token 消耗与传输延迟
          if (image.width > 1024) {
            resized = img.copyResize(image, width: 1024);
          }
          // 强制转换为 JPG 格式并压缩质量到 80%
          bytes = img.encodeJpg(resized, quality: 80);
          debugPrint('图片压缩完成，压缩后大小: ${bytes.length / 1024} KB');
        }
      } catch (e) {
        debugPrint('图片压缩失败，回退使用原图: $e');
      }
    }

    final base64File = base64Encode(bytes);

    final prompt = '''
    你是一个数据清洗专家。这是一份试卷的原始扫描件/截图。
    【最高指令】解析出其中的**每一道题**，绝对不允许遗漏！
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    [{"type": 0, "content": "题干", "options": ["A.", "B."], "standard_answer": "A", "explanation": "解析"}]
    【致命警告：JSON转义】遇到 LaTeX 公式，所有反斜杠必须双重转义！例如 \\\\pi。
    【LaTeX子集约束-渲染引擎限制必须遵守】
    允许: \\\\frac \\\\sqrt \\\\sum \\\\int \\\\prod \\\\lim 及希腊字母 \\\\alpha~\\\\omega
    允许: \\\\leq \\\\geq \\\\neq \\\\approx \\\\in \\\\subset \\\\cup \\\\cap \\\\vec \\\\sin \\\\cos \\\\tan \\\\log \\\\ln \\\\pm \\\\cdot \\\\times \\\\div
    允许简单矩阵: \\\\begin{pmatrix}a&b\\\\\\\\c&d\\\\end{pmatrix} 仅2x2或3x3
    填空占位符必须用普通文本___绝不加任何dollar包裹
    严禁: 将___放在dollar内部会导致下标解析崩溃
    严禁: \\\\begin{cases} \\\\begin{matrix} \\\\mathbb \\\\mathcal \\\\mathfrak \\\\def \\\\newcommand
    严禁: 超过3层嵌套的\\\\frac或\\\\sqrt
    ''';

    try {
      debugPrint("🚀 正在向视觉大模型发起文件/单图解析请求，请耐心等待...");
      final startTime = DateTime.now();

      if (isGemini) {
        if (isDocx) throw Exception("Gemini 不支持 Word 直传");
        final mimeType = isPdf ? "application/pdf" : "image/jpeg";
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}, {"inline_data": {"mime_type": mimeType, "data": base64File}}]}], "generationConfig": {"temperature": temp}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          debugPrint("✅ Gemini Vision 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text']?.toString() ?? "";
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("Gemini 错误: ${res.statusCode}");
      } else if (isZhipu && isPdf) {
        final uploadUrl = baseUrl.endsWith('/v4') ? "$baseUrl/files" : "$baseUrl/v4/files";
        var request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
        request.headers['Authorization'] = 'Bearer $apiKey';
        request.fields['purpose'] = 'file-extract';
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
        debugPrint("⏳ 正在上传文件至智谱服务器...");
        var uploadRes = await request.send().timeout(const Duration(seconds: 60));
        var uploadResBody = await uploadRes.stream.bytesToString();
        if (uploadRes.statusCode != 200) throw Exception("智谱上传失败: ${uploadRes.statusCode}");
        
        final fileId = jsonDecode(uploadResBody)['id'];
        final chatUrl = _buildChatUrl(baseUrl, true);
        final res = await http.post(Uri.parse(chatUrl), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}, {"type": "file", "file_url": {"url": fileId}}]}], "temperature": temp})).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          debugPrint("✅ 智谱 Vision 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = _extractContent(res.body);
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("智谱解析失败: ${res.statusCode}");
      } else {
        final mimeType = "image/jpeg";
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}, {"type": "image_url", "image_url": {"url": "data:$mimeType;base64,$base64File"}}]}], "temperature": temp})).timeout(const Duration(seconds: 90));
        if (res.statusCode == 200) {
          debugPrint("✅ Vision API 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = _extractContent(res.body);
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("Vision 错误: ${res.statusCode}");
      }
    } catch (e) {
      if (e.toString().contains('SocketException')) throw Exception("连接中断。请检查网络代理，或尝试体积较小的文件。");
      throw Exception("解析异常: $e");
    }
  }
}
