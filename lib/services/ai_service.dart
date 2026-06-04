import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/database/database_helper.dart';
import '../data/models/question_draft.dart';
import '../data/repositories/question_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import '../utils/image_utils.dart';
import 'ai_prompts.dart';
import 'document_chunker.dart';
import 'llm_api_client.dart';
import 'llm_providers/llm_provider_client.dart';
import 'llm_providers/llm_provider_registry.dart';
import 'parse_batch_runner.dart';
import 'question_parse_pipeline.dart';
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
  final ParseBatchRunner _batchRunner = const ParseBatchRunner();
  final DocumentChunker _chunker = const DocumentChunker();
  final QuestionParsePipeline _parsePipeline = const QuestionParsePipeline();

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

  Future<String> judgeAnswer(
      String question, String standardAnswer, String userAnswer) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) return "【系统提示】未激活文本 AI 引擎";

    final prompt = AiPrompts.judgeAnswer(
      question: question,
      standardAnswer: standardAnswer,
      userAnswer: userAnswer,
    );

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: 0.3,
        timeout: const Duration(seconds: 15),
      );
      return responseText.trim().isNotEmpty ? responseText : "解析失败";
    } catch (e) {
      return "【网络异常】$e";
    }
  }

  Future<List<QuestionDraft>> generateQuestions(String topic,
      {int count = 1, int type = 0}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

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
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      return QuestionDraft.listFromMaps(parsedList);
    } catch (e) {
      throw Exception("生成失败: $e");
    }
  }

  Future<Map<String, String>> answerSingleQuestion(
      Map<String, dynamic> question) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

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

  Future<List<QuestionDraft>> generateExamPaper(
      {required String topic,
      required int singleCount,
      required int fillCount,
      required int shortCount,
      String? customPrompt}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

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
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      return QuestionDraft.listFromMaps(parsedList);
    } catch (e) {
      throw Exception("生成试卷失败: $e");
    }
  }

  // --- 错题重练引擎：根据错题生成新题并存入指定题库 ---
  Future<List<QuestionDraft>> generateAndSaveQuestionsFromMistakes(
      {String targetBankName = '🔥 弱点突击训练营',
      int limit = 30,
      int count = 10}) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) throw Exception("未激活文本引擎");

    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort = profile['reasoning_effort'] as String? ?? '';

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
      final drafts = QuestionDraft.listFromMaps(parsedList);

      if (parsedList.isNotEmpty) {
        await QuestionRepository.instance.saveQuestionDraftsToBank(
          bankName: targetBankName,
          folderName: '🎆 智能生成',
          questions: drafts,
        );
      }

      return drafts;
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

      final stemBatches = _chunker.split(stemText, isMarkdown: isMarkdown);
      final ansBatches = _chunker.split(ansText, isMarkdown: isMarkdown);

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
      final microBatches =
          _chunker.split(processedText, isMarkdown: isMarkdown);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches,
          taskId: taskId, isMarkdown: isMarkdown, parseMode: 'stem_only');
    } else {
      debugPrint("🧭 [路径 C] 标准行内解析结构，直接提取...");
      final microBatches =
          _chunker.split(processedText, isMarkdown: isMarkdown);
      if (taskId != null) {
        TaskManager.instance.appendPendingChunks(
            taskId, isMarkdown ? 'markdown' : 'text', microBatches);
      }
      return await parseMicroBatches(microBatches,
          taskId: taskId, isMarkdown: isMarkdown);
    }

    // Fallback for Path A and any other unknown paths
    final microBatches = _chunker.split(processedText, isMarkdown: isMarkdown);
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

    debugPrint("🚀 [智能分块] 将启动 ${microBatches.length} 次微批次精洗格式化...");

    final batchResult = await _batchRunner.run(
      chunks: microBatches,
      parseChunk: (chunk) => _parseSingleChunkToQuestions(
        chunk,
        profile,
        isMarkdown: isMarkdown,
        parseMode: parseMode,
      ),
      onChunkSuccess: taskId == null
          ? null
          : (chunk, questions) {
              TaskManager.instance.markChunkSuccess(taskId, chunk, questions);
            },
      onChunkFailed: taskId == null
          ? null
          : (chunk) {
              TaskManager.instance.markChunkFailed(taskId, chunk);
            },
      onLog: debugPrint,
    );

    var allQuestions = batchResult.questions;
    final failCount = batchResult.failedCount;

    if (allQuestions.isEmpty) {
      if (failCount > 0) {
        throw Exception(
            "全部 ${microBatches.length} 个分块解析失败！请检查您的 API Key、余额或网络连通性。");
      } else {
        throw Exception(
            "文本已成功送达并被大模型处理，但大模型未能从中提取出任何符合规范的考题数据。这可能是因为文档主要是概念解析而缺乏试题结构。");
      }
    }

    final assemblyResult =
        _parsePipeline.mergeAnswerOnlyQuestions(allQuestions);
    if (assemblyResult.answerOnlyCount > 0) {
      debugPrint(
          "🧩 触发同一文件内的答案拼图归并：找到 ${assemblyResult.answerOnlyCount} 个独立答案。");
      for (final diagnostic in assemblyResult.diagnostics) {
        debugPrint(diagnostic.startsWith('题号') && diagnostic.contains('成功')
            ? '🔗 $diagnostic'
            : '⚠️ $diagnostic');
      }
      allQuestions = assemblyResult.questions;
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

    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    final prompt = AiPrompts.visionParseWithConstraints();

    try {
      // 将所有图片转为 Base64 并进行极速压缩
      final assets = <LlmVisionAsset>[];
      for (var path in imagePaths) {
        List<int> bytes = await File(path).readAsBytes();

        // 性能优化：只有图片大于 500KB 时才进行重度 Dart 压缩，且放入 Isolate 避免阻塞 UI
        if (bytes.length > 500 * 1024) {
          bytes = await compute(_compressImageSync, bytes);
          debugPrint('多图预处理: 图片 $path 已压缩至 ${bytes.length ~/ 1024} KB');
        }

        assets.add(
          LlmVisionAsset.inline(
            mimeType: 'image/jpeg',
            base64Data: base64Encode(bytes),
          ),
        );
      }

      debugPrint(
          "🚀 正在组装 ${imagePaths.length} 张图片并向视觉大模型发起请求，请耐心等待 (约需几十秒到一分钟)...");
      final startTime = DateTime.now();

      final responseText = await _apiClient.callVision(
        profile: profile,
        prompt: prompt,
        assets: assets,
        temperature: temp,
        timeout: const Duration(minutes: 8),
      );
      debugPrint(
          "✅ Vision API 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
      return _parsePipeline.parseVisionQuestions(
        responseText,
        strictContentQuality: true,
      );
    } catch (e) {
      throw Exception("多图视觉解析异常: $e");
    }
  }

  Future<String> _readFileAsVisionBase64(
    String filePath, {
    required bool compressImage,
  }) async {
    List<int> bytes = await File(filePath).readAsBytes();
    if (compressImage) {
      bytes = ImageUtils.compressFilePreviewSync(bytes);
      debugPrint('图片压缩完成，压缩后大小: ${bytes.length ~/ 1024} KB');
    }
    return base64Encode(bytes);
  }

  Future<List<Map<String, dynamic>>> parseFileWithVision(
      String filePath) async {
    final profile = await DatabaseHelper.instance.getActiveAiEngine('vision');
    if (profile == null) throw Exception("未激活视觉引擎");

    final providerProfile = LlmProviderProfile.fromMap(profile);
    if (!providerProfile.isComplete) {
      throw Exception("视觉引擎配置不完整: ${providerProfile.missingFields.join(', ')}");
    }
    final temp = (profile['temperature'] as num?)?.toDouble() ?? 0.1;

    final providerKind =
        LlmProviderRegistry.kindForBaseUrl(providerProfile.baseUrl);
    final isGemini = providerKind == LlmProviderKind.gemini;
    final isZhipu = providerKind == LlmProviderKind.zhipu;
    final lowerPath = filePath.toLowerCase();
    final isPdf = lowerPath.endsWith('.pdf');
    final isDocx = lowerPath.endsWith('.docx');

    if (isDocx) throw Exception("视觉模型无法直接看懂 Word，请先另存为 PDF 或截图！");
    if (isPdf && !isGemini && !isZhipu) {
      throw Exception("标准 OpenAI 协议不支持直传 PDF，请切换回 Gemini 或 智谱！");
    }

    final prompt = AiPrompts.visionParsePrompt;

    try {
      debugPrint("🚀 正在向视觉大模型发起文件/单图解析请求，请耐心等待...");
      final startTime = DateTime.now();

      final asset = isZhipu && isPdf
          ? LlmVisionAsset.uploadFile(
              mimeType: 'application/pdf',
              filePath: filePath,
            )
          : LlmVisionAsset.inline(
              mimeType: isPdf ? 'application/pdf' : 'image/jpeg',
              base64Data: await _readFileAsVisionBase64(
                filePath,
                compressImage: !isPdf,
              ),
            );

      final responseText = await _apiClient.callVision(
        profile: profile,
        prompt: prompt,
        assets: [asset],
        temperature: temp,
        timeout: isZhipu && isPdf
            ? const Duration(minutes: 5)
            : isGemini
                ? const Duration(minutes: 3)
                : const Duration(seconds: 90),
      );

      if (isZhipu && isPdf) {
        debugPrint(
            "✅ 智谱 Vision 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
      } else if (isGemini) {
        debugPrint(
            "✅ Gemini Vision 返回成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
      } else {
        debugPrint(
            "✅ Vision API 解析成功，耗时 ${DateTime.now().difference(startTime).inSeconds} 秒。");
      }
      return _parsePipeline.parseVisionQuestions(responseText);
    } catch (e) {
      if (e.toString().contains('SocketException')) {
        throw Exception("连接中断。请检查网络代理，或尝试体积较小的文件。");
      }
      throw Exception("解析异常: $e");
    }
  }

  // 轻量级 AI 结构化二次配对 (用于跨文件合并，如题干文件 + 答案文件)
  Future<List<Map<String, dynamic>>> mergeStructuredQuestions(
      List<List<Map<String, dynamic>>> fileResults) async {
    if (fileResults.isEmpty) return [];
    if (fileResults.length == 1) return fileResults.first;

    final profile = await DatabaseHelper.instance.getActiveAiEngine('text');
    if (profile == null) {
      throw Exception('未激活文本 AI 引擎，无法执行多文件合并');
    }

    final combinedJsonStr = jsonEncode(fileResults);
    final prompt = AiPrompts.mergeStructuredQuestions(combinedJsonStr);

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: 0.1,
        maxTokens: 8192,
        jsonResponse: true,
        timeout: const Duration(minutes: 3),
      );
      return await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception('AI 多文件交叉匹配合并失败: $e');
    }
  }
}
