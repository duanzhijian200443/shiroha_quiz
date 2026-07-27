import 'dart:async';
import 'dart:convert';

import '../../data/models/import_question_validation.dart';
import '../../data/models/question_draft.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../llm_api_client.dart';
import 'subjective_answer_expectation.dart';
import 'subjective_answer_distillation_policy.dart';

abstract interface class SubjectiveAnswerDistiller {
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  });
}

class SubjectiveAnswerDistillationResult {
  const SubjectiveAnswerDistillationResult.applied(
    String answer, {
    this.diagnostics = const ['answer_distillation_applied'],
  })  : applied = true,
        standardAnswer = answer;

  const SubjectiveAnswerDistillationResult.rejected({
    required this.diagnostics,
  })  : applied = false,
        standardAnswer = null;

  final bool applied;
  final String? standardAnswer;
  final List<String> diagnostics;
}

class SubjectiveAnswerDistillationService implements SubjectiveAnswerDistiller {
  const SubjectiveAnswerDistillationService({
    required AiEngineRepository engineRepository,
    LlmApiClient apiClient = const LlmApiClient(),
    SubjectiveAnswerDistillationPolicy policy =
        const SubjectiveAnswerDistillationPolicy(),
  })  : _engineRepository = engineRepository,
        _apiClient = apiClient,
        _policy = policy;

  static const _maximumTimeout = Duration(seconds: 30);
  static const _maximumAnswerCharacters = 240;

  final AiEngineRepository _engineRepository;
  final LlmApiClient _apiClient;
  final SubjectiveAnswerDistillationPolicy _policy;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = _maximumTimeout,
  }) async {
    if (!_policy.isCandidate(question, isStemOnly: isStemOnly)) {
      return const SubjectiveAnswerDistillationResult.rejected(
        diagnostics: [
          'answer_distillation_failed',
          'answer_distillation_failure_type:AnswerDistillationNotCandidateException',
        ],
      );
    }

    try {
      final profile = await _engineRepository.getActiveTextEngine();
      if (profile == null) {
        throw const AnswerDistillationNotConfiguredException();
      }

      final effectiveTimeout =
          timeout.compareTo(_maximumTimeout) > 0 ? _maximumTimeout : timeout;
      if (effectiveTimeout <= Duration.zero) {
        throw TimeoutException('answer distillation budget exhausted');
      }

      final response = await _apiClient.callText(
        profile: profile,
        prompt: _buildPrompt(questionNumber, question),
        temperature: 0,
        maxTokens: 512,
        jsonResponse: true,
        timeout: effectiveTimeout,
      );
      final decoded = _parseResponse(response);
      final returnedNumber = _readQuestionNumber(decoded['question_number']);
      if (returnedNumber != questionNumber) {
        return const SubjectiveAnswerDistillationResult.rejected(
          diagnostics: [
            'answer_distillation_rejected_question_number_changed',
          ],
        );
      }
      if (decoded['basis'] != 'explanation') {
        return const SubjectiveAnswerDistillationResult.rejected(
          diagnostics: ['answer_distillation_rejected_basis'],
        );
      }

      final rawAnswer = decoded['standard_answer'];
      if (rawAnswer == null ||
          rawAnswer is String && rawAnswer.trim().isEmpty) {
        return const SubjectiveAnswerDistillationResult.rejected(
          diagnostics: ['answer_distillation_rejected_empty'],
        );
      }
      if (rawAnswer is! String || rawAnswer.contains('```')) {
        throw const FormatException('invalid answer distillation output');
      }

      final answer = rawAnswer.trim();
      if (!isMeaningfulAnswer(answer)) {
        return const SubjectiveAnswerDistillationResult.rejected(
          diagnostics: ['answer_distillation_rejected_placeholder'],
        );
      }
      if (_isTooVerbose(answer, question.explanation)) {
        return const SubjectiveAnswerDistillationResult.rejected(
          diagnostics: ['answer_distillation_rejected_too_verbose'],
        );
      }

      return SubjectiveAnswerDistillationResult.applied(answer);
    } catch (error) {
      return SubjectiveAnswerDistillationResult.rejected(
        diagnostics: [
          'answer_distillation_failed',
          'answer_distillation_failure_type:${error.runtimeType}',
        ],
      );
    }
  }

  String _buildPrompt(int questionNumber, QuestionDraft question) {
    final input = jsonEncode({
      'question_number': questionNumber,
      'type': question.type.code,
      'answer_expectation':
          const SubjectiveAnswerExpectationPolicy().classify(question).name,
      'content': question.content,
      'explanation': question.explanation,
    });
    return '''
你不是重新解题。
只能依据提供的解析，提取或简洁概括解析中已经明确支持的最终答案。
解析中没有明确结论时，不得创造新结论或补充解析中不存在的推导。
只能输出一个 JSON object，且只能包含 question_number、standard_answer 和 basis。
basis 必须固定为 explanation。
不得改写题干、解析或题型；不得输出 Markdown 代码块、长推导或额外正文。
输入：
$input
''';
  }

  Map<String, dynamic> _parseResponse(String response) {
    final decoded = jsonDecode(response.trim());
    if (decoded is! Map) {
      throw const FormatException('answer distillation response is not object');
    }
    final result = <String, dynamic>{};
    decoded.forEach((key, value) => result[key.toString()] = value);
    const allowedKeys = {'question_number', 'standard_answer', 'basis'};
    if (result.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException(
          'answer distillation response has extra keys');
    }
    return result;
  }

  int? _readQuestionNumber(Object? value) {
    return switch (value) {
      final int number => number,
      final num number => number.toInt(),
      final String number => int.tryParse(number.trim()),
      _ => null,
    };
  }

  bool _isTooVerbose(String answer, String explanation) {
    final answerLength = answer.runes.length;
    final explanationLength = explanation.trim().runes.length;
    if (answerLength > _maximumAnswerCharacters) return true;

    final normalizedAnswer = _normalizeForComparison(answer);
    final normalizedExplanation = _normalizeForComparison(explanation);
    if (normalizedAnswer == normalizedExplanation) return true;

    return answerLength >= 120 &&
        explanationLength >= 120 &&
        answerLength * 10 >= explanationLength * 8;
  }

  String _normalizeForComparison(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim();
}

class AnswerDistillationNotConfiguredException implements Exception {
  const AnswerDistillationNotConfiguredException();
}
