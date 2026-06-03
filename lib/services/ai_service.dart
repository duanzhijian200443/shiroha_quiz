import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../core/database/database_helper.dart';
import '../data/repositories/question_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import '../utils/image_utils.dart';
import 'ai_prompts.dart';
import 'llm_api_client.dart';
import 'task_manager.dart';
import 'document_profiler.dart';

// 顶级函数：用于 Isolate 压缩图片
List<int> _compressImageSync(List<int> bytes) {
  try {
    return ImageUtils.compressForVisionSync(bytes);
  } catch (e) {
    debugPrint('图片压缩失败，回退使用原图: $e');
  }
  return bytes;
}

class AiService {
  final LlmApiClient _apiClient = const LlmApiClient();

  static final AiService instance = AiService._();
  AiService._();

  Future<String> callLlmApi(String prompt, {List<String>? imagePaths}) async {
    if (imagePaths != null && imagePaths.isNotEmpty) {
      final questions = await parseImagesWithVision(imagePaths);
      return jsonEncode({'questions': questions});
    }

    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");
    return _apiClient.callText(profile: profile, prompt: prompt);
  }

  Future<void> resumeTask(String taskId) async {
    final task = TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
    task.status = TaskStatus.processing;
    TaskManager.instance.updateProgress(taskId, '正在继续执行断点重传...', task.percent);

    if (task.sourceType == 'text') {
      final pending = List<String>.from(task.pendingChunks ?? []);
      try {
        await parseMicroBatches(pending, taskId: taskId);
        final updatedTask =
            TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
        TaskManager.instance.requireReview(
            taskId,
            '恢复解析成功，请校对入库',
            updatedTask.parsedData ?? [],
            updatedTask.bankName ?? '',
            updatedTask.folderName ?? '');
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
        final updatedTask =
            TaskManager.instance.tasks.firstWhere((t) => t.id == taskId);
        TaskManager.instance.requireReview(
            taskId,
            '恢复解析成功，请校对入库',
            updatedTask.parsedData ?? [],
            updatedTask.bankName ?? '',
            updatedTask.folderName ?? '');
      } catch (e) {
        TaskManager.instance.failTask(taskId, e.toString());
      }
    }
  }

  // 核心修复：智能 URL 路由构建器，完美兼容 v1 和 v4 协议
  String _buildChatUrl(String baseUrl, bool isZhipu) {
    return LlmApiClient.buildChatUrl(baseUrl, isZhipu);
  }

  // 核心容错：提取内容，自动兼容含有 reasoning_content 的深度思考模型（如老版 DeepSeek R1）
  String _extractContent(String responseBody) {
    return LlmApiClient.extractContent(responseBody);
  }

  Future<String> judgeAnswer(
      String question, String standardAnswer, String userAnswer) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) return "【系统提示】未激活文本 AI 引擎";

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      return "【系统提示】引擎配置不完整";

    final prompt = AiPrompts.judgeAnswer(
      question: question,
      standardAnswer: standardAnswer,
      userAnswer: userAnswer,
    );

    try {
      if (baseUrl.endsWith('/'))
        baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http
            .post(Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  "contents": [
                    {
                      "parts": [
                        {"text": prompt}
                      ]
                    }
                  ]
                }))
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          return jsonDecode(res.body)['candidates'][0]['content']['parts'][0]
                  ['text'] ??
              "解析失败";
        }
        return "【请求失败】Gemini 错误: ${res.statusCode}";
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http
            .post(Uri.parse(url),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $apiKey'
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {"role": "user", "content": prompt}
                  ],
                  "temperature": 0.3
                }))
            .timeout(const Duration(seconds: 15));
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

  Future<List<Map<String, dynamic>>> generateQuestions(String topic,
      {int count = 1, int type = 0}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    final prompt = AiPrompts.generateQuestions(
      topic: topic,
      count: count,
      type: type,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: temp,
        reasoningEffort: effort,
      );
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("生成失败: $e");
    }
  }

  Future<Map<String, String>> answerSingleQuestion(
      Map<String, dynamic> question) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    final prompt = AiPrompts.answerSingleQuestion(question);

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: temp,
        reasoningEffort: effort,
        jsonResponse: true,
      );
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      if (parsedList.isNotEmpty) {
        final ans = parsedList.first['standard_answer']?.toString() ?? '';
        return {"standard_answer": ans, "explanation": ""};
      }
      throw Exception("AI 返回了空数据");
    } catch (e) {
      throw Exception("AI 解答失败: $e");
    }
  }

  Future<List<Map<String, dynamic>>> generateExamPaper(
      {required String topic,
      required int singleCount,
      required int fillCount,
      required int shortCount,
      String? customPrompt}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    final prompt = AiPrompts.generateExamPaper(
      topic: topic,
      singleCount: singleCount,
      fillCount: fillCount,
      shortCount: shortCount,
      customPrompt: customPrompt,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: temp,
        reasoningEffort: effort,
      );
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("生成试卷失败: $e");
    }
  }

  // --- 错题重练引擎：根据错题生成新题并存入指定题库 ---
  Future<List<Map<String, dynamic>>> generateAndSaveQuestionsFromMistakes(
      {String targetBankName = '🔥 弱点突击训练营',
      int limit = 30,
      int count = 10}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    // 1. 获取近期错题
    final wrongQuestions =
        await DatabaseHelper.instance.getRecentWrongQuestions(limit: limit);
    if (wrongQuestions.isEmpty) {
      throw Exception("没有找到近期错题，快去刷题吧！");
    }

    // 2. 组装精简上下文
    StringBuffer contextBuffer = StringBuffer();
    for (int i = 0; i < wrongQuestions.length; i++) {
      final w = wrongQuestions[i];
      contextBuffer.writeln("错题 ${i + 1}:");
      contextBuffer.writeln("【题干】${w['content']}");
      contextBuffer.writeln("【标准答案】${w['standard_answer']}");
      if (w['last_wrong_answer'] != null &&
          w['last_wrong_answer'].toString().isNotEmpty) {
        contextBuffer.writeln("【学生的错误回答】${w['last_wrong_answer']}");
      }
      contextBuffer.writeln("---");
    }

    final prompt = AiPrompts.questionsFromMistakes(
      mistakeContext: contextBuffer.toString(),
      count: count,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: temp,
        reasoningEffort: effort,
      );
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);

      if (parsedList.isNotEmpty) {
        await QuestionRepository.instance.saveQuestionsToBank(
          bankName: targetBankName,
          folderName: '🎆 智能生成',
          questions: parsedList,
        );
      }

      return parsedList;
    } catch (e) {
      throw Exception("根据错题生成新题失败: $e");
    }
  }

  // 核心抽离：单块文本解析（处理小块，防止截断，保证永不超时和截断）
  Future<List<Map<String, dynamic>>> _parseSingleChunkToQuestions(
      String rawText, Map<String, dynamic> profile,
      {bool isMarkdown = false, String parseMode = 'all'}) async {
    final prompt = AiPrompts.parseChunk(
      rawText: rawText,
      parseMode: parseMode,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: 0.1,
        jsonResponse: true,
      );
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);
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
      if (currentBatch.length + block.length > 1500 &&
          currentBatch.isNotEmpty) {
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
    final parts =
        rawText.split(RegExp(r'\n(?=(?:#{1,6}\s|\d+\.|[一二三四五六七八九十]+、))'));

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

  Future<List<Map<String, dynamic>>> parseTextToQuestions(String rawText,
      {String? taskId, bool isMarkdown = false}) async {
    final docProfile = scanDocumentStructure(rawText);
    debugPrint("📊 [文档结构探针] \$docProfile");

    String processedText = rawText;

    // 路径 A：行内有答案 + 尾部也有答案 -> 裁掉尾部冗余，转化成路径 C
    if (docProfile.hasInlineAnswers &&
        docProfile.hasTailAnswerBlock &&
        docProfile.tailAnswerOffset > 0) {
      debugPrint(
          "✂️ [路径 A] 检测到尾部冗余答案块，执行安全物理裁剪 (Offset: \${docProfile.tailAnswerOffset})...");
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

      final stemBatches = isMarkdown
          ? splitMarkdownIntoMicroBatches(stemText)
          : splitTextIntoMicroBatches(stemText);
      final ansBatches = isMarkdown
          ? splitMarkdownIntoMicroBatches(ansText)
          : splitTextIntoMicroBatches(ansText);

      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', stemBatches);
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', ansBatches);
      }

      final stemQuestions = await parseMicroBatches(stemBatches,
          taskId: taskId, isMarkdown: isMarkdown, parseMode: 'stem_only');
      final ansQuestions = await parseMicroBatches(ansBatches,
          taskId: taskId, isMarkdown: isMarkdown, parseMode: 'answer_only');

      return [...stemQuestions, ...ansQuestions];
    } else if (!docProfile.hasInlineAnswers && !docProfile.hasTailAnswerBlock) {
      debugPrint("🧭 [路径 D] 全文无答案，将生成残缺题干等待用户补填...");
      final microBatches = isMarkdown
          ? splitMarkdownIntoMicroBatches(processedText)
          : splitTextIntoMicroBatches(processedText);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches,
          taskId: taskId, isMarkdown: isMarkdown, parseMode: 'stem_only');
    } else {
      debugPrint("🧭 [路径 C] 标准行内解析结构，直接提取...");
      final microBatches = isMarkdown
          ? splitMarkdownIntoMicroBatches(processedText)
          : splitTextIntoMicroBatches(processedText);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches,
          taskId: taskId, isMarkdown: isMarkdown);
    }

    // Fallback for Path A and any other unknown paths
    final microBatches = isMarkdown
        ? splitMarkdownIntoMicroBatches(processedText)
        : splitTextIntoMicroBatches(processedText);
    if (taskId != null) {
      TaskManager.instance.appendPendingChunks(
          taskId, isMarkdown ? 'markdown' : 'text', microBatches);
    }
    return await parseMicroBatches(microBatches,
        taskId: taskId, isMarkdown: isMarkdown);
  }

  Future<List<Map<String, dynamic>>> parseMicroBatches(
      List<String> microBatches,
      {String? taskId,
      bool isMarkdown = false,
      String parseMode = 'all'}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    // 调度引擎 (多线程高并发版本)
    List<Map<String, dynamic>> allQuestions = [];
    int failCount = 0;
    debugPrint("🚀 [智能分块] 将启动 ${microBatches.length} 次微批次精洗格式化...");

    List<List<Map<String, dynamic>>?> results =
        List.filled(microBatches.length, null);
    int currentIndex = 0;

    Future<void> worker(int workerId) async {
      while (true) {
        int i;
        if (currentIndex >= microBatches.length) break;
        i = currentIndex++;

        debugPrint(
            "🚀 [并发线程 ${workerId + 1}] 正在解析第 ${i + 1}/${microBatches.length} 块...");
        bool success = false;
        int retry = 0;

        while (retry < 3 && !success) {
          try {
            final chunkQuestions = await _parseSingleChunkToQuestions(
                microBatches[i], profile,
                isMarkdown: isMarkdown, parseMode: parseMode);
            results[i] = chunkQuestions;
            if (taskId != null) {
              TaskManager.instance
                  .markChunkSuccess(taskId, microBatches[i], chunkQuestions);
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
              int delaySeconds = e.toString().contains('429') ||
                      e.toString().toLowerCase().contains('timeout') ||
                      e.toString().toLowerCase().contains('socketexception') ||
                      e.toString().toLowerCase().contains('clientexception')
                  ? (5 * retry)
                  : 2;
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
        throw Exception(
            "全部 ${microBatches.length} 个分块解析失败！请检查您的 API Key、余额或网络连通性。");
      } else {
        throw Exception(
            "文本已成功送达并被大模型处理，但大模型未能从中提取出任何符合规范的考题数据。这可能是因为文档主要是概念解析而缺乏试题结构。");
      }
    }

    // === Claude 启发式题号标准化流水线 ===
    String normalizeQNum(String? raw) {
      if (raw == null || raw.isEmpty) return '';
      var s = raw.trim();
      s = s.replaceAll(RegExp(r'[.。、）\)：:]+$'), '');
      s = s.replaceAll(RegExp(r'^(?:第)?\s*'), '');
      s = s.replaceAll(RegExp(r'\s*(?:题)$'), '');
      const map = {
        '一': '1',
        '二': '2',
        '三': '3',
        '四': '4',
        '五': '5',
        '六': '6',
        '七': '7',
        '八': '8',
        '九': '9',
        '十': '10'
      };
      map.forEach((k, v) => s = s.replaceAll(k, v));
      return s.trim().toLowerCase();
    }

    // === Claude 启发式答案剥离判断 ===
    bool isAnswerOnly(Map<String, dynamic> q) {
      final content = q['content']?.toString().trim() ?? '';
      final ans = q['standard_answer']?.toString().trim() ?? '';
      if (ans.isEmpty) return false;
      if (content.isEmpty) return true;
      if (content.length <= 10 &&
          RegExp(r'^[A-Da-d√×正确错误ABCD,，\s]+$').hasMatch(content)) return true;
      if (content.contains('[纯答案') || content.contains('[ANSWER')) return true;
      // 如果题干和答案完全一致，说明 AI 把纯答案复制了两份，属于纯答案页
      if (content == ans) return true;
      // 防截断假题干识别（当题干较短且高度疑似算式或包含于答案片段时）
      if (content.length < 35 &&
          (content.contains(ans) || ans.contains(content))) return true;
      if (content.length < 15 &&
          (content.startsWith('I=') || content.contains('略'))) return true;
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
          mergedQuestions[targetIdx]['standard_answer'] =
              ans['standard_answer'];
          if (ans['explanation'] != null &&
              ans['explanation'].toString().trim().isNotEmpty) {
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
      debugPrint(
          "✅ ${microBatches.length} 个分块全部顺利解析合并完毕！共组装出 ${allQuestions.length} 道高纯度题目。");
    }

    return allQuestions;
  }

  Future<List<Map<String, dynamic>>> parseImagesWithVision(
      List<String> imagePaths) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('vision');
    if (profile == null) throw Exception("未激活视觉 AI 引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("视觉引擎配置不完整");
    if (baseUrl.endsWith('/'))
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);

    final isGemini = baseUrl.contains('generativelanguage.googleapis.com');

    final prompt = AiPrompts.visionParseWithConstraints();

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
          imageContents.add({
            "inline_data": {"mime_type": mimeType, "data": base64Img}
          });
        } else {
          imageContents.add({
            "type": "image_url",
            "image_url": {"url": "data:$mimeType;base64,$base64Img"}
          });
        }
      }

      debugPrint(
          "🚀 正在组装 ${imagePaths.length} 张图片并向视觉大模型发起请求，请耐心等待 (约需几十秒到一分钟)...");
      final startTime = DateTime.now();

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http
            .post(
              Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                "contents": [
                  {
                    "parts": [
                      {"text": prompt},
                      ...imageContents
                    ]
                  }
                ],
                "generationConfig": {"temperature": temp}
              }),
            )
            .timeout(const Duration(minutes: 8));

        if (res.statusCode == 200) {
          debugPrint(
              "✅ Gemini Vision 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final data = jsonDecode(res.body);
          if (data['candidates'] == null ||
              (data['candidates'] as List).isEmpty)
            throw Exception("Gemini 返回为空");
          List<Map<String, dynamic>> finalQuestions = await compute(
              AiDataSanitizer.cleanAndParseJson,
              data['candidates'][0]['content']['parts'][0]['text']
                      ?.toString() ??
                  "");
          final emptyStems = finalQuestions
              .where((q) =>
                  q['content'] == null ||
                  q['content'].toString().isEmpty ||
                  q['content'].toString().contains('假设'))
              .length;
          if (finalQuestions.isNotEmpty &&
              (emptyStems / finalQuestions.length > 0.5)) {
            throw Exception('题干提取率过低，疑似文档结构识别失败或AI未严格抄录题干！请更换大模型或检查文档图片结构。');
          }
          return finalQuestions;
        } else {
          throw Exception("Gemini 错误: ${res.statusCode}");
        }
      } else {
        final isZhipu = baseUrl.contains('bigmodel.cn');
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http
            .post(
              Uri.parse(url),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey'
              },
              body: jsonEncode({
                "model": model,
                "messages": [
                  {
                    "role": "user",
                    "content": [
                      {"type": "text", "text": prompt},
                      ...imageContents
                    ]
                  }
                ],
                "temperature": temp
              }),
            )
            .timeout(const Duration(minutes: 8));

        if (res.statusCode == 200) {
          debugPrint(
              "✅ Vision API 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final data = jsonDecode(res.body);
          if (data['choices'] == null || (data['choices'] as List).isEmpty)
            throw Exception("API 返回为空");
          List<Map<String, dynamic>> finalQuestions = await compute(
              AiDataSanitizer.cleanAndParseJson,
              data['choices'][0]['message']['content']?.toString() ?? "");
          final emptyStems = finalQuestions
              .where((q) =>
                  q['content'] == null ||
                  q['content'].toString().isEmpty ||
                  q['content'].toString().contains('假设'))
              .length;
          if (finalQuestions.isNotEmpty &&
              (emptyStems / finalQuestions.length > 0.5)) {
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

  Future<List<Map<String, dynamic>>> parseFileWithVision(
      String filePath) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('vision');
    if (profile == null) throw Exception("未激活视觉引擎");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("视觉引擎配置不完整");
    if (baseUrl.endsWith('/'))
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);

    final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
    final isZhipu = baseUrl.contains('bigmodel.cn');
    final lowerPath = filePath.toLowerCase();
    final isPdf = lowerPath.endsWith('.pdf');
    final isDocx = lowerPath.endsWith('.docx');

    if (isDocx) throw Exception("视觉模型无法直接看懂 Word，请先另存为 PDF 或截图！");
    if (isPdf && !isGemini && !isZhipu)
      throw Exception("标准 OpenAI 协议不支持直传 PDF，请切换回 Gemini 或 智谱！");

    List<int> bytes = await File(filePath).readAsBytes();

    // 核心提速优化：如果传入的是图片，进行极速压缩与降采样
    if (!isPdf) {
      bytes = ImageUtils.compressFilePreviewSync(bytes);
      debugPrint('图片压缩完成，压缩后大小: ${bytes.length ~/ 1024} KB');
    }

    final base64File = base64Encode(bytes);

    final prompt = AiPrompts.visionParsePrompt;

    try {
      debugPrint("🚀 正在向视觉大模型发起文件/单图解析请求，请耐心等待...");
      final startTime = DateTime.now();

      if (isGemini) {
        if (isDocx) throw Exception("Gemini 不支持 Word 直传");
        final mimeType = isPdf ? "application/pdf" : "image/jpeg";
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http
            .post(Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  "contents": [
                    {
                      "parts": [
                        {"text": prompt},
                        {
                          "inline_data": {
                            "mime_type": mimeType,
                            "data": base64File
                          }
                        }
                      ]
                    }
                  ],
                  "generationConfig": {"temperature": temp}
                }))
            .timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          debugPrint(
              "✅ Gemini Vision 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = jsonDecode(res.body)['candidates'][0]
                      ['content']['parts'][0]['text']
                  ?.toString() ??
              "";
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("Gemini 错误: ${res.statusCode}");
      } else if (isZhipu && isPdf) {
        final uploadUrl =
            baseUrl.endsWith('/v4') ? "$baseUrl/files" : "$baseUrl/v4/files";
        var request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
        request.headers['Authorization'] = 'Bearer $apiKey';
        request.fields['purpose'] = 'file-extract';
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
        debugPrint("⏳ 正在上传文件至智谱服务器...");
        var uploadRes =
            await request.send().timeout(const Duration(seconds: 60));
        var uploadResBody = await uploadRes.stream.bytesToString();
        if (uploadRes.statusCode != 200)
          throw Exception("智谱上传失败: ${uploadRes.statusCode}");

        final fileId = jsonDecode(uploadResBody)['id'];
        final chatUrl = _buildChatUrl(baseUrl, true);
        final res = await http
            .post(Uri.parse(chatUrl),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $apiKey'
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {
                      "role": "user",
                      "content": [
                        {"type": "text", "text": prompt},
                        {
                          "type": "file",
                          "file_url": {"url": fileId}
                        }
                      ]
                    }
                  ],
                  "temperature": temp
                }))
            .timeout(const Duration(minutes: 5));
        if (res.statusCode == 200) {
          debugPrint(
              "✅ 智谱 Vision 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = _extractContent(res.body);
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("智谱解析失败: ${res.statusCode}");
      } else {
        final mimeType = "image/jpeg";
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http
            .post(Uri.parse(url),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $apiKey'
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {
                      "role": "user",
                      "content": [
                        {"type": "text", "text": prompt},
                        {
                          "type": "image_url",
                          "image_url": {
                            "url": "data:$mimeType;base64,$base64File"
                          }
                        }
                      ]
                    }
                  ],
                  "temperature": temp
                }))
            .timeout(const Duration(seconds: 90));
        if (res.statusCode == 200) {
          debugPrint(
              "✅ Vision API 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
          final String parsedText = _extractContent(res.body);
          return await compute(AiDataSanitizer.cleanAndParseJson, parsedText);
        }
        throw Exception("Vision 错误: ${res.statusCode}");
      }
    } catch (e) {
      if (e.toString().contains('SocketException'))
        throw Exception("连接中断。请检查网络代理，或尝试体积较小的文件。");
      throw Exception("解析异常: $e");
    }
  }

  // 轻量级 AI 结构化二次配对 (用于跨文件合并，如题干文件 + 答案文件)
  Future<List<Map<String, dynamic>>> mergeStructuredQuestions(
      List<List<Map<String, dynamic>>> fileResults) async {
    if (fileResults.isEmpty) return [];
    if (fileResults.length == 1) return fileResults.first; // 单文件无需合并

    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎，无法执行合并");

    final apiKey = profile['api_key'] as String? ?? '';
    String baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty)
      throw Exception("引擎配置不完整");

    // 将结构化数据序列化，以极简 JSON 传给 AI
    String combinedJsonStr = jsonEncode(fileResults);

    final prompt = AiPrompts.mergeStructuredQuestions(combinedJsonStr);

    try {
      if (baseUrl.endsWith('/'))
        baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
      final isZhipu = baseUrl.contains('bigmodel.cn');
      String responseText = "";

      if (isGemini) {
        final url = "$baseUrl/models/$model:generateContent?key=$apiKey";
        final res = await http
            .post(Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  "contents": [
                    {
                      "parts": [
                        {"text": prompt}
                      ]
                    }
                  ],
                  "generationConfig": {
                    "temperature": 0.1,
                    "maxOutputTokens": 8192,
                    "responseMimeType": "application/json"
                  }
                }))
            .timeout(const Duration(minutes: 3));
        if (res.statusCode == 200) {
          responseText = jsonDecode(res.body)['candidates'][0]['content']
                  ['parts'][0]['text'] ??
              "";
        } else {
          throw Exception("API Error: ${res.statusCode}");
        }
      } else {
        final url = _buildChatUrl(baseUrl, isZhipu);
        final res = await http
            .post(Uri.parse(url),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $apiKey'
                },
                body: jsonEncode({
                  "model": model,
                  "messages": [
                    {"role": "user", "content": prompt}
                  ],
                  "temperature": 0.1,
                  "max_tokens": 8192,
                  "response_format": {"type": "json_object"}
                }))
            .timeout(const Duration(minutes: 3));
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
