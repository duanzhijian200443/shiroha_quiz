import 'package:flutter/foundation.dart';

import '../data/models/question_identity.dart';
import '../utils/ai_data_sanitizer.dart';

class QuestionAssemblyResult {
  const QuestionAssemblyResult({
    required this.questions,
    required this.answerOnlyCount,
    required this.diagnostics,
  });

  final List<Map<String, dynamic>> questions;
  final int answerOnlyCount;
  final List<String> diagnostics;
}

class QuestionParsePipeline {
  const QuestionParsePipeline();

  Future<List<Map<String, dynamic>>> parseVisionQuestions(
    String responseText, {
    bool strictContentQuality = false,
  }) async {
    final questions = await compute(
      AiDataSanitizer.cleanAndParseJson,
      responseText,
    );

    if (!strictContentQuality || questions.isEmpty) {
      return questions;
    }

    final emptyStemCount = questions.where(_hasEmptyOrPlaceholderStem).length;
    if (emptyStemCount / questions.length > 0.5) {
      throw Exception('题干提取率过低，疑似文档结构识别失败或AI未严格抄录题干！请更换大模型或检查文档图片结构。');
    }
    return questions;
  }

  QuestionAssemblyResult mergeAnswerOnlyQuestions(
    List<Map<String, dynamic>> questions,
  ) {
    final mergedQuestions = <Map<String, dynamic>>[];
    final answerPool = <Map<String, dynamic>>[];
    final diagnostics = <String>[];

    for (final question in questions) {
      final copiedQuestion = Map<String, dynamic>.from(question);
      if (isAnswerOnlyQuestion(copiedQuestion)) {
        answerPool.add(copiedQuestion);
      } else {
        mergedQuestions.add(copiedQuestion);
      }
    }

    if (answerPool.isEmpty) {
      return QuestionAssemblyResult(
        questions: mergedQuestions,
        answerOnlyCount: 0,
        diagnostics: diagnostics,
      );
    }

    for (final answer in answerPool) {
      final rawAnswerNumber = answer['q_num']?.toString().trim() ?? '';
      final answerNumber = normalizeQuestionNumber(rawAnswerNumber);

      if (answerNumber.isEmpty) {
        mergedQuestions.add(answer);
        continue;
      }

      final targetIndex = mergedQuestions.indexWhere((question) {
        final questionNumber =
            normalizeQuestionNumber(question['q_num']?.toString());
        return questionNumber == answerNumber;
      });

      if (targetIndex != -1) {
        mergedQuestions[targetIndex]['standard_answer'] =
            answer['standard_answer'];
        final explanation = answer['explanation']?.toString().trim() ?? '';
        if (explanation.isNotEmpty) {
          mergedQuestions[targetIndex]['explanation'] = answer['explanation'];
        }
        diagnostics.add('题号 $rawAnswerNumber (标准号:$answerNumber) 的题干与答案拼图成功！');
      } else {
        mergedQuestions.add(answer);
        diagnostics.add(
          '题号 $rawAnswerNumber (标准号:$answerNumber) 的答案未能找到题干配对，已独立保留。',
        );
      }
    }

    return QuestionAssemblyResult(
      questions: mergedQuestions,
      answerOnlyCount: answerPool.length,
      diagnostics: diagnostics,
    );
  }

  String normalizeQuestionNumber(String? raw) {
    return QuestionIdentity.normalizeQuestionNumber(raw);
  }

  bool isAnswerOnlyQuestion(Map<String, dynamic> question) {
    final content = question['content']?.toString().trim() ?? '';
    final answer = question['standard_answer']?.toString().trim() ?? '';
    if (answer.isEmpty) return false;
    if (content.isEmpty) return true;
    if (content.length <= 10 &&
        RegExp(r'^[A-Da-d√×正确错误ABCD,，\s]+$').hasMatch(content)) {
      return true;
    }
    if (content.contains('[纯答案') || content.contains('[ANSWER')) {
      return true;
    }
    if (content == answer) return true;
    if (content.length < 35 &&
        (content.contains(answer) || answer.contains(content))) {
      return true;
    }
    if (content.length < 15 &&
        (content.startsWith('I=') || content.contains('略'))) {
      return true;
    }
    return false;
  }

  bool _hasEmptyOrPlaceholderStem(Map<String, dynamic> question) {
    final content = question['content']?.toString() ?? '';
    return content.isEmpty || content.contains('假设');
  }
}
