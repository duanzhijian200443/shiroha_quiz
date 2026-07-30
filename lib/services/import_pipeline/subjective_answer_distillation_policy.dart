import '../../data/models/import_question_validation.dart';
import '../../data/models/question_draft.dart';
import 'question_fragment.dart';
import 'subjective_answer_expectation.dart';
import 'subjective_answer_extractor.dart';

class SubjectiveAnswerDistillationPolicy {
  const SubjectiveAnswerDistillationPolicy({
    SubjectiveAnswerExpectationPolicy expectationPolicy =
        const SubjectiveAnswerExpectationPolicy(),
    SubjectiveAnswerExtractor extractor = const SubjectiveAnswerExtractor(),
  })  : _expectationPolicy = expectationPolicy,
        _extractor = extractor;

  static const candidateCode = 'subjective_answer_distillation_candidate';
  final SubjectiveAnswerExpectationPolicy _expectationPolicy;
  final SubjectiveAnswerExtractor _extractor;

  bool isCandidate(
    QuestionDraft question, {
    required bool isStemOnly,
  }) {
    if (isStemOnly || question.type != QuestionType.shortAnswer) return false;
    if (_expectationPolicy.classify(question) ==
        SubjectiveAnswerExpectation.proofExplanation) {
      return false;
    }
    if (isMeaningfulAnswer(question.standardAnswer)) return false;
    if (question.explanation.trim().isEmpty) return false;
    if (_isImagePlaceholderOnly(question.explanation)) return false;
    if (_extractor
        .extract(
          questionNumber: 0,
          content: question.content,
          standardAnswer: question.standardAnswer,
          explanation: question.explanation,
        )
        .matched) {
      return false;
    }
    return !hasBlockingStructureIssue(question);
  }

  bool hasBlockingStructureIssue(QuestionDraft question) {
    final content = question.content.trim();
    return content.isEmpty ||
        QuestionFragment.isPlaceholderStem(content) ||
        meaningfulOptions(question.options).isNotEmpty;
  }

  bool _isImagePlaceholderOnly(String explanation) {
    final remaining = explanation
        .replaceAll(
          RegExp(
            r'!\[[^\]]*\]\([^)]*\)|\[图片[^\]]*\]|【图片[^】]*】|<img\b[^>]*>',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return remaining.isEmpty;
  }
}
