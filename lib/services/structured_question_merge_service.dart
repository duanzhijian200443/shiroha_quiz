import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repositories/ai_engine_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import 'ai_prompts.dart';
import 'llm_api_client.dart';

class StructuredQuestionMergeService {
  StructuredQuestionMergeService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository ?? AiEngineRepository.instance;

  final LlmApiClient _apiClient;
  final AiEngineRepository _engineRepository;

  Future<List<Map<String, dynamic>>> merge(
    List<List<Map<String, dynamic>>> fileResults,
  ) async {
    if (fileResults.isEmpty) return [];
    if (fileResults.length == 1) return fileResults.first;

    final profile = await _engineRepository.getActiveTextEngine();
    if (profile == null) {
      throw Exception('未激活文本 AI 引擎，无法执行多文件合并');
    }

    final prompt = AiPrompts.mergeStructuredQuestions(jsonEncode(fileResults));

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: 0.1,
        maxTokens: 8192,
        jsonResponse: true,
        timeout: const Duration(minutes: 3),
      );
      return compute(AiDataSanitizer.cleanAndParseJson, responseText);
    } catch (e) {
      throw Exception('AI 多文件交叉匹配合并失败: $e');
    }
  }
}
