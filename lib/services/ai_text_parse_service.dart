import 'package:flutter/foundation.dart';

import '../data/models/ai_engine_profile.dart';
import '../data/models/question_parse_mode.dart';
import '../data/repositories/ai_engine_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import 'ai_prompts.dart';
import 'document_parse_router.dart';
import 'llm_api_client.dart';
import 'parse_batch_runner.dart';
import 'question_parse_pipeline.dart';
import 'task_manager.dart';

class AiTextParseService {
  AiTextParseService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
    ParseBatchRunner batchRunner = const ParseBatchRunner(),
    DocumentParseRouter parseRouter = const DocumentParseRouter(),
    QuestionParsePipeline parsePipeline = const QuestionParsePipeline(),
    TaskManager? taskManager,
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository ?? AiEngineRepository.instance,
        _batchRunner = batchRunner,
        _parseRouter = parseRouter,
        _parsePipeline = parsePipeline,
        _taskManager = taskManager ?? TaskManager.instance;

  final LlmApiClient _apiClient;
  final AiEngineRepository _engineRepository;
  final ParseBatchRunner _batchRunner;
  final DocumentParseRouter _parseRouter;
  final QuestionParsePipeline _parsePipeline;
  final TaskManager _taskManager;

  Future<List<Map<String, dynamic>>> parseTextToQuestions(
    String rawText, {
    String? taskId,
    bool isMarkdown = false,
  }) async {
    final plan = _parseRouter.buildPlan(rawText, isMarkdown: isMarkdown);
    debugPrint("📊 [文档结构探针] ${plan.profile}");
    debugPrint(plan.logMessage);

    if (taskId != null) {
      for (final segment in plan.segments) {
        _taskManager.appendPendingChunks(
          taskId,
          isMarkdown ? 'markdown' : 'text',
          segment.batches,
        );
      }
    }

    final questions = <Map<String, dynamic>>[];
    for (final segment in plan.segments) {
      questions.addAll(
        await parseMicroBatches(
          segment.batches,
          taskId: taskId,
          isMarkdown: isMarkdown,
          parseMode: segment.parseMode,
        ),
      );
    }
    return questions;
  }

  Future<List<Map<String, dynamic>>> parseMicroBatches(
    List<String> microBatches, {
    String? taskId,
    bool isMarkdown = false,
    QuestionParseMode parseMode = QuestionParseMode.all,
  }) async {
    final profile = await _engineRepository.getActiveTextEngine();
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
              _taskManager.markChunkSuccess(taskId, chunk, questions);
            },
      onChunkFailed: taskId == null
          ? null
          : (chunk) {
              _taskManager.markChunkFailed(taskId, chunk);
            },
      onLog: debugPrint,
    );

    return _assembleBatchResult(
      batchResult,
      totalChunkCount: microBatches.length,
    );
  }

  Future<List<Map<String, dynamic>>> _parseSingleChunkToQuestions(
    String rawText,
    AiEngineProfile profile, {
    bool isMarkdown = false,
    QuestionParseMode parseMode = QuestionParseMode.all,
  }) async {
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
      return compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception("块级解析失败: $e");
    }
  }

  List<Map<String, dynamic>> _assembleBatchResult(
    ParseBatchRunResult batchResult, {
    required int totalChunkCount,
  }) {
    var allQuestions = batchResult.questions;
    final failCount = batchResult.failedCount;

    if (allQuestions.isEmpty) {
      if (failCount > 0) {
        throw Exception("全部 $totalChunkCount 个分块解析失败！请检查您的 API Key、余额或网络连通性。");
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
          "✅ $totalChunkCount 个分块全部顺利解析合并完毕！共组装出 ${allQuestions.length} 道高纯度题目。");
    }

    return allQuestions;
  }
}
