import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../core/database/database_helper.dart';
import '../utils/ai_data_sanitizer.dart';
import 'task_manager.dart';
import 'document_profiler.dart';

// 顶级函数：用于 Isolate 压缩图片
List<int> _compressImageSync(List<int> bytes) {
  try {
    final image = img.decodeImage(Uint8List.fromList(bytes));
    if (image != null) {
      img.Image resized = image;
      if (image.width > 900) {
        resized = img.copyResize(image, width: 900);
      }
      return img.encodeJpg(resized, quality: 65);
    }
  } catch (e) {
    debugPrint('图片压缩失败，回退使用原图: $e');
  }
  return bytes;
}

class AiService {
  static final AiService instance = AiService._();
  AiService._();

  Future<void> resumeTask(String taskId) async {
    final task = TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
    task.status = TaskStatus.processing;
    TaskManager.instance.updateProgress(taskId, '正在继续执行断点重传...', task.percent);

    if (task.sourceType == 'text') {
      final pending = List<String>.from(task.pendingChunks ?? []);
      try {
        await parseMicroBatches(pending, taskId: taskId);
        final updatedTask = TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
        TaskManager.instance.requireReview(taskId, '恢复解析成功，请校对入库', updatedTask.parsedData ?? [], updatedTask.bankName ?? '', updatedTask.folderName ?? '');
      } catch (e) {
        TaskManager.instance.failTask(taskId, e.toString());
      }
    } else if (task.sourceType == 'vision') {
      final pending = List<String>.from(task.pendingChunks ?? []);
      try {
        for (var path in pending) {
          final res = await parseImagesWithVision([path]);
          TaskManager.instance.markChunkSuccess(taskId, path, res);
        }
        final updatedTask = TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
        TaskManager.instance.requireReview(taskId, '恢复解析成功，请校对入库', updatedTask.parsedData ?? [], updatedTask.bankName ?? '', updatedTask.folderName ?? '');
      } catch (e) {
        TaskManager.instance.failTask(taskId, e.toString());
      }
    }
  }

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
        ? '[{"type": 0, "content": "题干", "options": ["A.", "B."], "standard_answer": "A"}]'
        : (type == 2 
            ? '[{"type": 2, "content": "题干(用___表示填空)", "options": [], "standard_answer": "答案"}]'
            : (type == 3 
                ? '[{"type": 3, "content": "简答题干", "options": [], "standard_answer": "标准答案"}]'
                : '[{"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A"}]'));

    final prompt = '''
    你是一个命题专家。请根据知识点：“$topic”，生成 $count 道题。
    题型要求：$typeReq
    【格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
    $exampleJson
    【致命警告：JSON LaTeX 物理隔离法则】
    由于 JSON 解析器极易与 LaTeX 的反斜杠 `\\` 发生冲突，**你输出的 JSON 字符串中绝对不能出现真实的 `\\` 符号！**
    你必须使用大写的 `BSLASH` 作为所有 LaTeX 反斜杠的占位符（例如 BSLASHpi, BSLASHfrac）。系统会在安全层自动替换回反斜杠。
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

  Future<Map<String, String>> answerSingleQuestion(Map<String, dynamic> question) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    final qType = question['type'] as int? ?? 3;
    final qContent = question['content']?.toString() ?? '';
    final qOptions = question['options']?.toString() ?? '';

    String prompt = '''
你是一个无所不知的超级学霸和全能做题家。请解答下面这道题。
【题目内容】
$qContent
''';

    if (qType == 0 || qType == 1) {
      prompt += '''
【选项】
$qOptions
''';
    }

    prompt += '''
【要求】
1. 你必须且只能输出合法的 JSON 对象，格式必须完全遵守下方示例：
{"standard_answer": "你的最终答案（尽量简短，如A、B、或者一个词语、公式）"}
2. standard_answer 字段中绝对禁止出现多余的解释文字，只保留最终核心答案！
3. 输出的 JSON 必须严格合法：公式或内容中的换行必须写为 \\n，LaTeX 公式必须转义。绝对禁止在 JSON 字符串值中出现真实的物理回车换行！绝对禁止在字符串内容中直接使用未经转义的双引号(请替换为单引号或转义为 \\\")！
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
        reqBody["response_format"] = {"type": "json_object"};
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode(reqBody)).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      }

      final parsedList = await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      if (parsedList.isNotEmpty) {
        final ans = parsedList.first['standard_answer']?.toString() ?? '';
        return {"standard_answer": ans, "explanation": ""};
      }
      throw Exception("AI 返回了空数据");
    } catch (e) {
      throw Exception("AI 解答失败: $e");
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
      {"type": 0, "content": "单选题干", "options": ["A.", "B."], "standard_answer": "A"},
      {"type": 2, "content": "填空题干(用___)", "options": [], "standard_answer": "填空答案"},
      {"type": 3, "content": "简答题干", "options": [], "standard_answer": "简答答案"}
    ]
    【致命警告：JSON转义】遇到 LaTeX 公式，所有反斜杠必须双重转义！例如 \\pi。
    ''';
    // LaTeX constraint injected into prompt after base definition
    prompt += '\n    【LaTeX子集约束-渲染引擎限制必须遵守】\n'
        '    防呆指令：所有数学公式、符号、分数、甚至孤立的字母，必须且只能用 \$ [数学公式] \$ 包裹！绝不能出现裸奔的 \\\\frac 等公式！\n'
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

  // --- 错题重练引擎：根据错题生成新题并存入指定题库 ---
  Future<List<Map<String, dynamic>>> generateAndSaveQuestionsFromMistakes({String targetBankName = '🔥 弱点突击训练营', int limit = 30, int count = 10}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    // 1. 获取近期错题
    final wrongQuestions = await DatabaseHelper.instance.getRecentWrongQuestions(limit: limit);
    if (wrongQuestions.isEmpty) {
      throw Exception("没有找到近期错题，快去刷题吧！");
    }

    // 2. 组装精简上下文
    StringBuffer contextBuffer = StringBuffer();
    for (int i = 0; i < wrongQuestions.length; i++) {
      final w = wrongQuestions[i];
      contextBuffer.writeln("错题 ${i+1}:");
      contextBuffer.writeln("【题干】${w['content']}");
      contextBuffer.writeln("【标准答案】${w['standard_answer']}");
      if (w['last_wrong_answer'] != null && w['last_wrong_answer'].toString().isNotEmpty) {
        contextBuffer.writeln("【学生的错误回答】${w['last_wrong_answer']}");
      }
      contextBuffer.writeln("---");
    }

    final prompt = '''
你是一个无所不知的教育专家。以下是学生最近做错的题目及其错误答案：
<mistakes>
${contextBuffer.toString()}
</mistakes>

请深入分析这些错题暴露出的薄弱知识点，并针对这些薄弱点，为学生**生成 $count 道**全新的类似题目（混合单选、填空、解答），帮助他巩固。

【严格格式约束】直接输出纯 JSON 数组，绝不要 markdown 包裹。
[
  {"type": 0, "content": "单选题干", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "A"},
  {"type": 2, "content": "填空题干(用___)", "options": [], "standard_answer": "填空答案"},
  {"type": 3, "content": "解答题干", "options": [], "standard_answer": "最终结果"}
]

【核心红线规则】
1. 绝对禁止生成 explanation(解析) 字段！只需要题干和答案。
2. 由于 JSON 冲突，所有 LaTeX 反斜杠必须替换为 BSLASH（如 BSLASHpi）。数学公式必须用 \$ 包裹。
3. 遇到包含小问的大题，必须合并为一道 type:3 题目。
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
        if (effort.isNotEmpty) reqBody["reasoning_effort"] = effort;
        else reqBody["temperature"] = temp;
        reqBody["max_tokens"] = 8192;
        
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode(reqBody)).timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode} - ${res.body}");
        }
      }
      
      final parsedList = await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      
      if (parsedList.isNotEmpty) {
        // 确保目标题库（文件夹）存在
        await DatabaseHelper.instance.updateBankFolder(targetBankName, '🎯 智能生成');
        
        final db = await DatabaseHelper.instance.database;
        final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        
        await db.transaction((txn) async {
          for (int i = 0; i < parsedList.length; i++) {
            final q = parsedList[i];
            String qId = 'ai_mistake_' + DateTime.now().millisecondsSinceEpoch.toString() + '_' + i.toString();
            await txn.insert('questions', {
              'id': qId,
              'bank_name': targetBankName,
              'type': q['type'] ?? 0,
              'content': q['content'],
              'options': q['options'] != null ? jsonEncode(q['options']) : '[]',
              'standard_answer': q['standard_answer'],
              'explanation': '', // 统一为空
              'created_at': nowUnix,
            });
          }
        });
      }
      
      return parsedList;
    } catch (e) {
      throw Exception("根据错题生成新题失败: $e");
    }
  }

  // 核心抽离：单块文本解析（处理小块，防止截断，保证永不超时和截断）
  Future<List<Map<String, dynamic>>> _parseSingleChunkToQuestions(String rawText, Map<String, dynamic> profile, {bool isMarkdown = false, String parseMode = 'all'}) async {
    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';

    String modeInstruction = "";
    if (parseMode == 'stem_only') {
      modeInstruction = "【当前为题干区模式】请只提取题干(content)和选项(options)，将 standard_answer 和 explanation 设为 null 或留空！绝对禁止在 content 中使用占位符敷衍！";
    } else if (parseMode == 'answer_only') {
      modeInstruction = "【当前为纯答案区模式】请坚决让 content 为 null！仅输出 q_num(题号) 和 standard_answer(答案)。绝对不要把答案填进 content 凑数！";
    } else {
      modeInstruction = '''
【输出模式】
模式A（完整题目）：输出 content 和 standard_answer。
模式B（只有题干）：standard_answer 设为 null。
模式C（纯答案区）：type 设为 null, content 设为 null, 仅输出 q_num 和 standard_answer。

绝对不要生成任何解析(explanation)字段，我们只需要题干和答案！
对于模式A和模式B：绝对禁止在 content 中使用“原题干”、“同上”、“略”等任何占位符敷衍！必须一字不落地将完整的题干抄录下来！
对于模式C：请坚决让 content 为 null，绝对不要把答案填进 content 凑数！

【扫描件题解混排处理法则】
如果扫描件中包含【分析】、【解】、【证明】等解题过程标记：
- content（题干）必须在第一个此类标记出现前截止，绝不包含解题过程！
- standard_answer 提取解题过程最终得出的答案值或结论。⚠️特例：如果是【证明题】或【解答题】，并且原文给出了完整的证明过程/解答步骤，请务必将完整的证明与解答步骤全部提取到 standard_answer 中！对于证明题，真正的答案就是证明过程本身，绝对不允许只写“证明略”或重复题干！
- explanation 字段直接输出 null，不需要提取解析内容。

反例（错误）：
content: "设二次型...（III）f(x₁,x₂,x₃)=0的解为 【解】设...化简得..."

正例（正确）：
content: "设二次型...（III）f(x₁,x₂,x₃)=0的解为"
standard_answer: "k₁(-2,1,0)ᵀ + k₂(-3,0,1)ᵀ，k₁k₂为任意常数"
explanation: null
''';
    }

    final prompt = '''
你是一个严谨的教育数据提取专家。请将以下文本提取为结构化的题库 JSON 数组。如果没有检测到题目，直接返回空数组 []。

【题型与格式】
1. 选择题 (type: 0): {"q_num": "题号", "type": 0, "content": "题干完整原文(包含选项部分)", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "正确选项"}
2. 填空题 (type: 2): {"q_num": "题号", "type": 2, "content": "题干完整原文", "options": [], "standard_answer": "答案内容"}
3. 解答题 (type: 3): {"q_num": "题号", "type": 3, "content": "题干完整原文", "options": [], "standard_answer": "最终结果"}

【综合大题提取法则】
遇到包含 (1)(2) 或 (I)(II) 等多个小问的综合大题，绝对禁止将其拆分为多道独立的题！
必须按以下标准合并为一道 type:3（解答题）：
1. content（题干）：必须包含大题的前置背景描述，并依次追加 (I)(II) 等所有小问的题目原文。
2. standard_answer（答案）：必须依次合并包含 (I)(II) 对应的所有解答内容。
绝对不允许把小问的题干丢进答案里，各归其位！

$modeInstruction

【致命警告：JSON LaTeX 物理隔离法则】
由于 JSON 解析器极易与 LaTeX 的反斜杠 `\\` 发生冲突，**你输出的 JSON 字符串中绝对不能出现真实的 `\\` 符号！**
你必须使用大写的 `BSLASH` 作为所有 LaTeX 反斜杠的占位符（例如 BSLASHpi, BSLASHfrac）。系统会在安全层自动替换回反斜杠。
所有的数学公式（包括独立成行的推导等式，如 BSLASHln L = ...），必须使用标准的 LaTeX 行内 \$...\$ 或块级 \$\$...\$\$ 严密包裹。绝对不能出现裸露在外的数学命令！
特别注意矩阵和方程组，必须整体包在一个 \$\$...\$\$ 里，绝不拆分！
正例：\$\$k_1BSLASHbegin{pmatrix}-2BSLASHBSLASH1BSLASHBSLASH0BSLASHend{pmatrix}+k_2BSLASHbegin{pmatrix}-3BSLASHBSLASH0BSLASHBSLASH1BSLASHend{pmatrix}\$\$
反例：\$k_1BSLASHbegin{pmatrix}...BSLASHend{pmatrix}\$\$\$+k_2\$\$\$BSLASHbegin{pmatrix}...BSLASHend{pmatrix}\$ （这是断裂拼接，绝对禁止！）
必须且只能输出纯 JSON 对象，包含 "questions" 数组。不要用 markdown 包裹。

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
      final parsedList = await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      return parsedList;
    } catch (e) {
      throw Exception("块级解析失败: $e");
    }
  }

  // 通用文本分块 (限制1500字)
  List<String> splitTextIntoMicroBatches(String rawText) {
    List<String> questionBlocks = [];
    StringBuffer currentChunk = StringBuffer();
    final paragraphs = rawText.split(RegExp(r'\n\s*\n'));
    for (var p in paragraphs) {
      final text = p.trim();
      if (text.isEmpty) continue;
      if (currentChunk.length + text.length > 1500) {
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

    List<String> microBatches = [];
    StringBuffer currentBatch = StringBuffer();
    for (String block in questionBlocks) {
       if (currentBatch.length + block.length > 1500 && currentBatch.isNotEmpty) {
           microBatches.add(currentBatch.toString());
           currentBatch.clear();
       }
       currentBatch.writeln(block);
       currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
       microBatches.add(currentBatch.toString());
    }
    return microBatches;
  }

  // 专属 Markdown 分块 (基于语义与结构的严格切分)
  List<String> splitMarkdownIntoMicroBatches(String rawText) {
    List<String> microBatches = [];
    StringBuffer currentBatch = StringBuffer();
    // 剔除空行切割，严格依赖标题 (###) 和 序号 (1. 或 一、)
    final parts = rawText.split(RegExp(r'\n(?=(?:#{1,6}\s|\d+\.|[一二三四五六七八九十]+、))'));
    
    for (var part in parts) {
      final text = part.trim();
      if (text.isEmpty) continue;
      
      if (currentBatch.length + text.length > 2000) {
        if (currentBatch.isNotEmpty) {
          microBatches.add(currentBatch.toString());
          currentBatch.clear();
        }
      }
      currentBatch.writeln(text);
      currentBatch.writeln();
    }
    if (currentBatch.isNotEmpty) {
      microBatches.add(currentBatch.toString());
    }
    return microBatches;
  }

  Future<List<Map<String, dynamic>>> parseTextToQuestions(String rawText, {String? taskId, bool isMarkdown = false}) async {
    final docProfile = scanDocumentStructure(rawText);
    debugPrint("📊 [文档结构探针] \$docProfile");

    String processedText = rawText;
    
    // 路径 A：行内有答案 + 尾部也有答案 -> 裁掉尾部冗余，转化成路径 C
    if (docProfile.hasInlineAnswers && docProfile.hasTailAnswerBlock && docProfile.tailAnswerOffset > 0) {
      debugPrint("✂️ [路径 A] 检测到尾部冗余答案块，执行安全物理裁剪 (Offset: \${docProfile.tailAnswerOffset})...");
      try {
        processedText = rawText.substring(0, docProfile.tailAnswerOffset);
      } catch (e) {
        debugPrint("⚠️ 尾部裁剪异常: \$e，回退使用全文");
        processedText = rawText;
      }
    } else if (!docProfile.hasInlineAnswers && docProfile.hasTailAnswerBlock) {
      debugPrint("🧭 [路径 B] 检测到首尾分离结构，实施物理剪切提取...");
      final stemText = rawText.substring(0, docProfile.tailAnswerOffset);
      final ansText = rawText.substring(docProfile.tailAnswerOffset);
      
      final stemBatches = isMarkdown ? splitMarkdownIntoMicroBatches(stemText) : splitTextIntoMicroBatches(stemText);
      final ansBatches = isMarkdown ? splitMarkdownIntoMicroBatches(ansText) : splitTextIntoMicroBatches(ansText);
      
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(taskId, isMarkdown ? 'markdown' : 'text', stemBatches);
        TaskManager.instance.appendPendingChunks(taskId, isMarkdown ? 'markdown' : 'text', ansBatches);
      }
      
      final stemQuestions = await parseMicroBatches(stemBatches, taskId: taskId, isMarkdown: isMarkdown, parseMode: 'stem_only');
      final ansQuestions = await parseMicroBatches(ansBatches, taskId: taskId, isMarkdown: isMarkdown, parseMode: 'answer_only');
      
      return [...stemQuestions, ...ansQuestions];
    } else if (!docProfile.hasInlineAnswers && !docProfile.hasTailAnswerBlock) {
      debugPrint("🧭 [路径 D] 全文无答案，将生成残缺题干等待用户补填...");
      final microBatches = isMarkdown ? splitMarkdownIntoMicroBatches(processedText) : splitTextIntoMicroBatches(processedText);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches, taskId: taskId, isMarkdown: isMarkdown, parseMode: 'stem_only');
    } else {
      debugPrint("🧭 [路径 C] 标准行内解析结构，直接提取...");
      final microBatches = isMarkdown ? splitMarkdownIntoMicroBatches(processedText) : splitTextIntoMicroBatches(processedText);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches, taskId: taskId, isMarkdown: isMarkdown);
    }
    
    // Fallback for Path A and any other unknown paths
    final microBatches = isMarkdown ? splitMarkdownIntoMicroBatches(processedText) : splitTextIntoMicroBatches(processedText);
    if (taskId != null) {
      TaskManager.instance.appendPendingChunks(taskId, isMarkdown ? 'markdown' : 'text', microBatches);
    }
    return await parseMicroBatches(microBatches, taskId: taskId, isMarkdown: isMarkdown);
  }

  Future<List<Map<String, dynamic>>> parseMicroBatches(List<String> microBatches, {String? taskId, bool isMarkdown = false, String parseMode = 'all'}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    // 调度引擎 (多线程高并发版本)
    List<Map<String, dynamic>> allQuestions = [];
    int failCount = 0;
    debugPrint("🚀 [智能分块] 将启动 ${microBatches.length} 次微批次精洗格式化...");
    
    List<List<Map<String, dynamic>>?> results = List.filled(microBatches.length, null);
    int currentIndex = 0;
    
    Future<void> worker(int workerId) async {
      while (true) {
        int i;
        if (currentIndex >= microBatches.length) break;
        i = currentIndex++;
        
        debugPrint("🚀 [并发线程 ${workerId + 1}] 正在解析第 ${i + 1}/${microBatches.length} 块...");
        bool success = false;
        int retry = 0;
        
        while (retry < 3 && !success) {
          try {
            final chunkQuestions = await _parseSingleChunkToQuestions(microBatches[i], profile, isMarkdown: isMarkdown, parseMode: parseMode);
            results[i] = chunkQuestions;
            if (taskId != null) {
              TaskManager.instance.markChunkSuccess(taskId, microBatches[i], chunkQuestions);
            }
            success = true;
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            retry++;
            debugPrint("⚠️ 第 ${i + 1} 块解析失败 (重试 $retry/3): $e");
            if (retry >= 3) {
               failCount++;
               if (taskId != null) {
                 TaskManager.instance.markChunkFailed(taskId, microBatches[i]);
               }
            } else {
               int delaySeconds = e.toString().contains('429') || e.toString().toLowerCase().contains('timeout') || e.toString().toLowerCase().contains('socketexception') || e.toString().toLowerCase().contains('clientexception') ? (5 * retry) : 2;
               debugPrint("⚠️ 触发频率限制/错误，冷却 $delaySeconds 秒后重试...");
               await Future.delayed(Duration(seconds: delaySeconds));
            }
          }
        }
      }
    }
    
    int maxConcurrent = 3;
    List<Future<void>> workers = [];
    for (int w = 0; w < maxConcurrent; w++) {
       workers.add(worker(w));
    }
    await Future.wait(workers);

    for (int i = 0; i < results.length; i++) {
       final r = results[i];
       if (r != null) {
          allQuestions.addAll(r);
       }
    }

    if (allQuestions.isEmpty) {
      if (failCount > 0) {
        throw Exception("全部 ${microBatches.length} 个分块解析失败！请检查您的 API Key、余额或网络连通性。");
      } else {
        throw Exception("文本已成功送达并被大模型处理，但大模型未能从中提取出任何符合规范的考题数据。这可能是因为文档主要是概念解析而缺乏试题结构。");
      }
    }

    // === Claude 启发式题号标准化流水线 ===
    String normalizeQNum(String? raw) {
      if (raw == null || raw.isEmpty) return '';
      var s = raw.trim();
      s = s.replaceAll(RegExp(r'[.。、）\)：:]+$'), '');
      s = s.replaceAll(RegExp(r'^(?:第)?\s*'), '');
      s = s.replaceAll(RegExp(r'\s*(?:题)$'), '');
      const map = {'一':'1','二':'2','三':'3','四':'4','五':'5',
                   '六':'6','七':'7','八':'8','九':'9','十':'10'};
      map.forEach((k, v) => s = s.replaceAll(k, v));
      return s.trim().toLowerCase();
    }

    // === Claude 启发式答案剥离判断 ===
    bool isAnswerOnly(Map<String, dynamic> q) {
      final content = q['content']?.toString().trim() ?? '';
      final ans = q['standard_answer']?.toString().trim() ?? '';
      if (ans.isEmpty) return false;
      if (content.isEmpty) return true;
      if (content.length <= 10 && RegExp(r'^[A-Da-d√×正确错误ABCD,，\s]+$').hasMatch(content)) return true;
      if (content.contains('[纯答案') || content.contains('[ANSWER')) return true;
      // 如果题干和答案完全一致，说明 AI 把纯答案复制了两份，属于纯答案页
      if (content == ans) return true;
      // 防截断假题干识别（当题干较短且高度疑似算式或包含于答案片段时）
      if (content.length < 35 && (content.contains(ans) || ans.contains(content))) return true;
      if (content.length < 15 && (content.startsWith('I=') || content.contains('略'))) return true;
      return false;
    }

    // 单文件内题干与答案的极速拼图归并算法
    List<Map<String, dynamic>> mergedQuestions = [];
    List<Map<String, dynamic>> answerPool = [];

    // 第一遍分离：将残缺的纯答案页剥离出来进入答案池
    for (var q in allQuestions) {
      if (isAnswerOnly(q)) {
        answerPool.add(q);
      } else {
        mergedQuestions.add(q);
      }
    }

    // 第二遍配对：将答案池中的答案，按标准化题号回填给对应的题干
    if (answerPool.isNotEmpty) {
      debugPrint("🧩 触发同一文件内的答案拼图归并：找到 ${answerPool.length} 个独立答案。");
      for (var ans in answerPool) {
        String rawAnsNum = ans['q_num']?.toString().trim() ?? '';
        String ansNum = normalizeQNum(rawAnsNum);
        
        if (ansNum.isEmpty) {
           mergedQuestions.add(ans);
           continue;
        }
        
        // 寻找题干池中缺少答案且题号匹配的题目
        int targetIdx = mergedQuestions.indexWhere((q) {
           String qNum = normalizeQNum(q['q_num']?.toString());
           return qNum == ansNum;
        });
        
        if (targetIdx != -1) {
           mergedQuestions[targetIdx]['standard_answer'] = ans['standard_answer'];
           if (ans['explanation'] != null && ans['explanation'].toString().trim().isNotEmpty) {
               mergedQuestions[targetIdx]['explanation'] = ans['explanation'];
           }
           debugPrint("🔗 题号 $rawAnsNum (标准号:$ansNum) 的题干与答案拼图成功！");
        } else {
           // 如果找不到匹配的题干，依然保留该答案项，防止数据丢失
           mergedQuestions.add(ans);
           debugPrint("⚠️ 题号 $rawAnsNum (标准号:$ansNum) 的答案未能找到题干配对，已独立保留。");
        }
      }
      allQuestions = mergedQuestions;
    }


    if (failCount > 0) {
      debugPrint("⚠️ 警告：有 $failCount 个分块最终解析失败，部分题目可能丢失！");
    } else {
      debugPrint("✅ ${microBatches.length} 个分块全部顺利解析合并完毕！共组装出 ${allQuestions.length} 道高纯度题目。");
    }

    return allQuestions;
  }

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
你是一个教育数据清洗专家。这是试卷扫描件。请严格按照以下格式解析出每道题：

【题型与格式】
1. 选择题 (type: 0): {"q_num": "题号", "type": 0, "content": "题干完整原文", "options": ["A. xx", "B. xx", "C. xx", "D. xx"], "standard_answer": "正确选项"}
2. 填空题 (type: 2): {"q_num": "题号", "type": 2, "content": "题干完整原文", "options": [], "standard_answer": "答案内容"}
3. 解答题 (type: 3): {"q_num": "题号", "type": 3, "content": "题干完整原文", "options": [], "standard_answer": "最终结果"}

【综合大题提取法则】
遇到包含 (1)(2) 或 (I)(II) 等多个小问的综合大题，绝对禁止将其拆分为多道独立的题！
必须按以下标准合并为一道 type:3（解答题）：
1. content（题干）：必须包含大题的前置背景描述，并依次追加 (I)(II) 等所有小问的题目原文。
2. standard_answer（答案）：必须依次合并包含 (I)(II) 对应的所有解答内容。
绝对不允许把小问的题干丢进答案里，各归其位！

【输出模式】
模式A（完整题目）：输出 content 和 standard_answer。
模式B（只有题干，没有答案）：standard_answer 设为 null。
模式C（纯答案区）：type 设为 null, content 设为 null, 仅输出 q_num 和 standard_answer。

【扫描件题解混排处理法则】
如果扫描件中包含【分析】、【解】、【证明】等解题过程标记：
- content（题干）必须在第一个此类标记出现前截止，绝不包含解题过程！
- standard_answer 提取解题过程最终得出的答案值或结论。⚠️特例：如果是【证明题】或【解答题】，并且原文给出了完整的证明过程/解答步骤，请务必将完整的证明与解答步骤全部提取到 standard_answer 中！对于证明题，真正的答案就是证明过程本身，绝对不允许只写“证明略”或重复题干！
- explanation 字段直接输出 null，不需要提取解析内容。

反例（错误）：
content: "设二次型...（III）f(x₁,x₂,x₃)=0的解为 【解】设...化简得..."

正例（正确）：
content: "设二次型...（III）f(x₁,x₂,x₃)=0的解为"
standard_answer: "k₁(-2,1,0)ᵀ + k₂(-3,0,1)ᵀ，k₁k₂为任意常数"
explanation: null

【严格限制】
绝对不要生成任何解析(explanation)字段，我们只需要题干和答案！
绝对禁止在 content 字段中使用“原题干”、“同上”、“略”等任何占位符敷衍！必须一字不落地将完整的题干文字抄录下来！否则将导致系统严重错误！
系数与矩阵/向量必须合并在同一个 \$\$...\$\$ 内，绝不允许系数在外、矩阵在内的分裂写法（例如 \$\$k_1\\begin{pmatrix}...\$\$ 是正确的）。矩阵、向量、方程组必须整体包在一个 \$\$...\$\$ 里，绝不允许拆分成多个 \$...\$。
必须且只能输出纯 JSON 对象，包含 "questions" 数组。不要用 markdown 包裹。
由于 JSON 冲突，所有 LaTeX 反斜杠必须替换为 BSLASH（如 BSLASHpi）。数学公式必须用 \$ 包裹。
    ''';

    try {
      // 将所有图片转为 Base64 并进行极速压缩
      List<Map<String, dynamic>> imageContents = [];
      for (var path in imagePaths) {
        List<int> bytes = await File(path).readAsBytes();
        
        // 性能优化：只有图片大于 500KB 时才进行重度 Dart 压缩，且放入 Isolate 避免阻塞 UI
        if (bytes.length > 500 * 1024) {
          bytes = await compute(_compressImageSync, bytes);
          debugPrint('多图预处理: 图片 $path 已压缩至 ${bytes.length ~/ 1024} KB');
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
          List<Map<String, dynamic>> finalQuestions = await compute(AiDataSanitizer.cleanAndParseJson, data['candidates'][0]['content']['parts'][0]['text']?.toString() ?? "");
          final emptyStems = finalQuestions.where((q) => q['content'] == null || q['content'].toString().isEmpty || q['content'].toString().contains('假设')).length;
          if (finalQuestions.isNotEmpty && (emptyStems / finalQuestions.length > 0.5)) {
            throw Exception('题干提取率过低，疑似文档结构识别失败或AI未严格抄录题干！请更换大模型或检查文档图片结构。');
          }
          return finalQuestions;
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
          List<Map<String, dynamic>> finalQuestions = await compute(AiDataSanitizer.cleanAndParseJson, data['choices'][0]['message']['content']?.toString() ?? "");
          final emptyStems = finalQuestions.where((q) => q['content'] == null || q['content'].toString().isEmpty || q['content'].toString().contains('假设')).length;
          if (finalQuestions.isNotEmpty && (emptyStems / finalQuestions.length > 0.5)) {
            throw Exception('题干提取率过低，疑似文档结构识别失败或AI未严格抄录题干！请更换大模型或检查文档图片结构。');
          }
          return finalQuestions;
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
    【致命警告：JSON LaTeX 物理隔离法则】
    由于 JSON 解析器极易与 LaTeX 的反斜杠 `\\` 发生冲突，**你输出的 JSON 字符串中绝对不能出现真实的 `\\` 符号！**
    你必须使用大写的 `BSLASH` 作为所有 LaTeX 反斜杠的占位符（例如 BSLASHpi, BSLASHfrac）。系统会在安全层自动替换回反斜杠。
    
    【✂️ 题干与解析精准剥离法则（核心指令）】
    在扫描图片或文本时，务必将“题目本身（题干）”与附带的“题目答案/解析/分析/解”严格分离开来！
    - `content` (题干)：**只能**包含题目本身的问题描述、背景资料和提问。**绝对禁止**将“分析”、“解”、“证明过程”、“答案是”等答题过程混入题干！
    - `explanation` (解析)：如果原文中有“分析”、“详解”、“解题思路”，请提取到此字段。如果没有，请设为 null 或空字符串。**绝对不要自己推导或补全解析！首要任务是原样提取题目和答案。**

    【🌀 全并发智能内核：题干与答案异步拼图模式（最高层级指令）】
    你需要支持以下模式来解耦题干与答案：
    - 模式 A（正常完整题目）: {"q_num": "题号", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": "答案", "explanation": ""}
    - 模式 B（只有题干，未见答案）: {"q_num": "题号", "type": 0/2/3, "content": "题干", "options": [], "standard_answer": null, "explanation": null}
    - 模式 C（只有答案页，未见题干）: {"q_num": "题号", "type": null, "content": null, "standard_answer": "答案", "explanation": ""}
    关键：当你看到纯答案文档（如 “1. A  2. B  3. C” 或 “参考答案: 1.B”）时，**必须按模式 C 输出**，提取答案并明确将 `content` 设为 null！绝对不能把解答步骤写进题干里！
    `q_num` 字段必须尽可能识别原文中的题目编号，以供归并。

    【⚠️ 大题防撕裂最高法则（绝对红线）】
    遇到包含 (I)、(II)、(III) 或 (1)、(2) 或 步骤1、步骤2 等多个小问的综合性大题、材料阅读题时，**绝对禁止将其拆分为多道独立的顶级题**！
    判断是否为新题的唯一标准：行首出现独立的阿拉伯数字编号（如 1. 22.）或中文大写编号（如 一、 二、）。
    带有小括号的数字 (1)、小写字母 (a)、罗马数字 (I) 等绝对不允许独立！
    你必须将它作为【一道完整的大题】，把所有小问合并写进 `content` 中，并将所有小问的解答步骤合并写进 `explanation` 中。
    
    【LaTeX子集约束-渲染引擎限制必须遵守】
    防呆指令：所有数学公式、符号、等式（如 BSLASHln L = ...），即使是独立成行，也必须且只能用 \$ [数学公式] \$ 或 \$\$ [数学公式] \$\$ 严密包裹！绝不能出现没有 \$ 包裹的裸露公式（如裸露的 BSLASHfrac）！
    允许: BSLASHfrac BSLASHsqrt BSLASHsum BSLASHint BSLASHprod BSLASHlim 及希腊字母 BSLASHalpha~BSLASHomega
    允许: BSLASHleq BSLASHgeq BSLASHneq BSLASHapprox BSLASHin BSLASHsubset BSLASHcup BSLASHcap BSLASHvec BSLASHsin BSLASHcos BSLASHtan BSLASHlog BSLASHln BSLASHpm BSLASHcdot BSLASHtimes BSLASHdiv
    允许简单矩阵: BSLASHbegin{pmatrix}a&b BSLASHBSLASH c&d BSLASHend{pmatrix} 仅2x2或3x3
    填空占位符必须用普通文本___绝不加任何dollar包裹
    严禁: 将___放在dollar内部会导致下标解析崩溃
    严禁: BSLASHbegin{cases} BSLASHbegin{matrix} BSLASHmathbb BSLASHmathcal BSLASHmathfrak BSLASHdef BSLASHnewcommand
    严禁: 超过3层嵌套的BSLASHfrac或BSLASHsqrt
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

  // 轻量级 AI 结构化二次配对 (用于跨文件合并，如题干文件 + 答案文件)
  Future<List<Map<String, dynamic>>> mergeStructuredQuestions(List<List<Map<String, dynamic>>> fileResults) async {
    if (fileResults.isEmpty) return [];
    if (fileResults.length == 1) return fileResults.first; // 单文件无需合并

    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎，无法执行合并");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) throw Exception("引擎配置不完整");

    // 将结构化数据序列化，以极简 JSON 传给 AI
    String combinedJsonStr = jsonEncode(fileResults);

    final prompt = '''
    你是一个逻辑严密的教育数据归并专家。
    我将向你提供一个包含多个数组的列表，这些数组是通过分别解析多个独立文档（如一份是【题目卷】，一份是【答案卷】）得到的结构化碎片。
    
    【核心任务】
    请你根据题目逻辑、题号（可能包含数字或中文序号）或者上下文，将属于同一道题的【题干碎片】和【答案碎片】完美合并为一个完整的题目对象。
    如果是孤立无法匹配的碎片，也请尽量保留。

    【反幻觉与防撕裂指令】
    1. 绝对禁止拆分题目：合并后，主大题的数量必须与原文题目数量一致。绝对不允许把大题的解题步骤、小问（如 (I)、(II)、步骤1）独立成新的顶级题目！
    2. 禁止遗漏：所有提供的碎片必须完全被归并，不允许丢弃任何细节。

    【格式约束与死命令】
    1. 你必须且只能输出一个合法的 JSON 对象，格式如下：
```json
{"questions": [ {"type": 0, "content": "真实的题干内容", "options": ["A", "B"], "standard_answer": "完整的答案", "explanation": "完整的解析"} ]}
```
    绝对禁止输出 缩写或骨架模板！必须输出真实的完整数据数组！
    2. 绝对不允许在 JSON 外部输出任何多余的废话、问候语或解释！
    3. 合并后的题目必须包含：type, content, options(若是选择题), standard_answer。至于 explanation（解析），如果碎片中原本就没有解析，绝对不要自行推导补全！
    4. 【致命警告：JSON LaTeX 物理隔离法则】由于 JSON 解析器极易与 LaTeX 的反斜杠 `\\` 发生冲突，**你输出的 JSON 字符串中绝对不能出现真实的 `\\` 符号！** 你必须使用大写的 `BSLASH` 作为所有 LaTeX 反斜杠的占位符（例如 BSLASHpi, BSLASHfrac）。系统会在安全层自动替换回反斜杠。所有数学公式必须使用 \$ [数学公式] \$ 包裹！
    5. 【致命警告：严禁省略】无论合并后的输出有多长，必须完整输出每一个题目对象的所有内容字符！绝对不允许使用 省略号或 "省略" 等任何缩写形式来中断或偷懒！

    【待合并的碎片数据】
    $combinedJsonStr
    ''';

    try {
      if (baseUrl.endsWith('/')) baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"temperature": 0.1, "maxOutputTokens": 8192, "responseMimeType": "application/json"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']['parts'][0]['text'] ?? "";
        } else {
          throw Exception("API Error: ${res.statusCode}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $apiKey'}, body: jsonEncode({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0.1, "max_tokens": 8192, "response_format": {"type": "json_object"}})).timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = _extractContent(res.body);
        } else {
          throw Exception("API Error: ${res.statusCode}");
        }
      }
      
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("AI 多文件交叉配对合并失败: $e");
    }
  }
}
