import 'package:flutter/foundation.dart';

import '../data/models/ai_engine_profile.dart';
import '../data/models/question_draft.dart';
import '../data/repositories/ai_engine_repository.dart';
import '../data/repositories/question_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import 'ai_prompts.dart';
import 'llm_api_client.dart';

class AiTextGenerationService {
  AiTextGenerationService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
    QuestionRepository? questionRepository,
  })  : _apiClient = apiClient,
        _engineRepository = engineRepository ?? AiEngineRepository.instance,
        _questionRepository = questionRepository ?? QuestionRepository.instance;

  final LlmApiClient _apiClient;
  final AiEngineRepository _engineRepository;
  final QuestionRepository _questionRepository;

  Future<String> judgeAnswer(
    String question,
    String standardAnswer,
    String userAnswer,
  ) async {
    final profile = await _engineRepository.getActiveTextEngine();
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

  Future<List<QuestionDraft>> generateQuestions(
    String topic, {
    int count = 1,
    int type = 0,
  }) async {
    final profile = await _requireActiveTextEngine();
    final prompt = AiPrompts.generateQuestions(
      topic: topic,
      count: count,
      type: type,
    );

    try {
      return _callDraftList(profile, prompt);
    } catch (e) {
      throw Exception("生成失败: $e");
    }
  }

  Future<Map<String, String>> answerSingleQuestion(
    Map<String, dynamic> question,
  ) async {
    final profile = await _requireActiveTextEngine();
    final prompt = AiPrompts.answerSingleQuestion(question);

    try {
      final responseText = await _apiClient.callText(
        profile: profile,
        prompt: prompt,
        temperature: profile.temperature,
        reasoningEffort: profile.reasoningEffort,
        jsonResponse: true,
      );
      final parsedList =
          await compute(AiDataSanitizer.cleanAndParseJson, responseText);
      if (parsedList.isNotEmpty) {
        final answer = parsedList.first['standard_answer']?.toString() ?? '';
        return {'standard_answer': answer, 'explanation': ''};
      }
      throw Exception("AI 返回了空数据");
    } catch (e) {
      throw Exception("AI 解答失败: $e");
    }
  }

  Future<List<QuestionDraft>> generateExamPaper({
    required String topic,
    required int singleCount,
    required int fillCount,
    required int shortCount,
    String? customPrompt,
  }) async {
    final profile = await _requireActiveTextEngine();
    final prompt = AiPrompts.generateExamPaper(
      topic: topic,
      singleCount: singleCount,
      fillCount: fillCount,
      shortCount: shortCount,
      customPrompt: customPrompt,
    );

    try {
      return _callDraftList(profile, prompt);
    } catch (e) {
      throw Exception("生成试卷失败: $e");
    }
  }

  Future<List<QuestionDraft>> generateAndSaveQuestionsFromMistakes({
    String targetBankName = '🔥 弱点突击训练营',
    int limit = 30,
    int count = 10,
  }) async {
    final profile = await _requireActiveTextEngine();
    final wrongQuestions =
        await _questionRepository.getRecentWrongQuestions(limit: limit);
    if (wrongQuestions.isEmpty) {
      throw Exception("没有找到近期错题，快去刷题吧！");
    }

    final prompt = AiPrompts.questionsFromMistakes(
      mistakeContext: _buildMistakeContext(wrongQuestions),
      count: count,
    );

    try {
      final drafts = await _callDraftList(profile, prompt);
      if (drafts.isNotEmpty) {
        await _questionRepository.saveQuestionDraftsToBank(
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

  Future<AiEngineProfile> _requireActiveTextEngine() async {
    final profile = await _engineRepository.getActiveTextEngine();
    if (profile == null) throw Exception("未激活文本引擎");
    return profile;
  }

  Future<List<QuestionDraft>> _callDraftList(
    AiEngineProfile profile,
    String prompt,
  ) async {
    final responseText = await _apiClient.callText(
      profile: profile,
      prompt: prompt,
      temperature: profile.temperature,
      reasoningEffort: profile.reasoningEffort,
    );
    final parsedList =
        await compute(AiDataSanitizer.cleanAndParseJson, responseText);
    return QuestionDraft.listFromMaps(parsedList);
  }

  String _buildMistakeContext(List<Map<String, dynamic>> wrongQuestions) {
    final contextBuffer = StringBuffer();
    for (var i = 0; i < wrongQuestions.length; i++) {
      final wrongQuestion = wrongQuestions[i];
      contextBuffer.writeln("错题 ${i + 1}:");
      contextBuffer.writeln("【题干】${wrongQuestion['content']}");
      contextBuffer.writeln("【标准答案】${wrongQuestion['standard_answer']}");

      final lastWrongAnswer = wrongQuestion['last_wrong_answer'];
      if (lastWrongAnswer != null && lastWrongAnswer.toString().isNotEmpty) {
        contextBuffer.writeln("【学生的错误回答】$lastWrongAnswer");
      }
      contextBuffer.writeln("---");
    }
    return contextBuffer.toString();
  }
}
