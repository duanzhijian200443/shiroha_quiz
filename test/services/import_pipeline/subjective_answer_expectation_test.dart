import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_expectation.dart';

QuestionDraft _question(String content, {String explanation = 'Proof steps'}) {
  return QuestionDraft(
    type: QuestionType.shortAnswer,
    content: content,
    options: const [],
    standardAnswer: '',
    explanation: explanation,
  );
}

void main() {
  const policy = SubjectiveAnswerExpectationPolicy();

  test('recognizes only explicit proof instructions', () {
    for (final content in const [
      '证明下列命题',
      '试证明该结论',
      '求证等式成立',
      '请证明函数连续',
      '已知条件。试证结论',
    ]) {
      expect(
        policy.classify(_question(content)),
        SubjectiveAnswerExpectation.proofExplanation,
        reason: content,
      );
    }
  });

  test('ordinary occurrence of 证 is not a proof instruction', () {
    for (final content in const [
      '保证结果正确',
      '给出反例作为证据',
      '验证计算结果',
      '证明了上一步结论后，计算最终结果',
      '证明过程中使用该等式',
      '该结论可证明',
    ]) {
      expect(
        policy.classify(_question(content)),
        isNot(SubjectiveAnswerExpectation.proofExplanation),
        reason: content,
      );
    }
  });
}
