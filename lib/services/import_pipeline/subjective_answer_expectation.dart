import '../../data/models/question_draft.dart';

enum SubjectiveAnswerExpectation {
  conciseAnswer,
  proofExplanation,
  unknown,
}

class SubjectiveAnswerExpectationPolicy {
  const SubjectiveAnswerExpectationPolicy();

  SubjectiveAnswerExpectation classify(QuestionDraft question) {
    if (question.type != QuestionType.shortAnswer) {
      return SubjectiveAnswerExpectation.unknown;
    }

    final content = question.content.trim();
    if (_proofInstruction.hasMatch(content)) {
      return SubjectiveAnswerExpectation.proofExplanation;
    }
    if (_conciseAnswerInstruction.hasMatch(content)) {
      return SubjectiveAnswerExpectation.conciseAnswer;
    }
    return SubjectiveAnswerExpectation.unknown;
  }

  static final RegExp _proofInstruction = RegExp(
    r'(?:^|[。；！？\n])\s*(?:请证明|试证明|求证|试证|证明)(?!了|过|中|过程)',
  );

  static final RegExp _conciseAnswerInstruction = RegExp(
    r'(?:^|[。；！？\n])\s*(?:求|计算|解答|回答|写出|确定)',
  );
}
