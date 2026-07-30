import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_policy.dart';

const _eligible = QuestionDraft(
  type: QuestionType.shortAnswer,
  content: 'Synthetic subjective question',
  options: [],
  standardAnswer: '',
  explanation: 'Synthetic explanation with enough information.',
  rawExplanation: 'Synthetic raw explanation.',
);

void main() {
  const policy = SubjectiveAnswerDistillationPolicy();

  test('routes only safe subjective questions with missing answers', () {
    expect(policy.isCandidate(_eligible, isStemOnly: false), isTrue);

    for (final placeholder in const ['无', '未知', '见解析']) {
      expect(
        policy.isCandidate(
          _eligible.copyWith(standardAnswer: placeholder),
          isStemOnly: false,
        ),
        isTrue,
        reason: placeholder,
      );
    }

    expect(
      policy.isCandidate(
        _eligible.copyWith(standardAnswer: 'A concise answer'),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(
      policy.isCandidate(
        _eligible.copyWith(explanation: ''),
        isStemOnly: false,
      ),
      isFalse,
    );
  });

  test('rejects objective, stem-only, blocked, and image-only candidates', () {
    expect(
      policy.isCandidate(
        _eligible.copyWith(type: QuestionType.singleChoice),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(
      policy.isCandidate(
        _eligible.copyWith(type: QuestionType.fillBlank),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(policy.isCandidate(_eligible, isStemOnly: true), isFalse);
    expect(
      policy.isCandidate(
        _eligible.copyWith(content: ''),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(
      policy.isCandidate(
        _eligible.copyWith(options: const ['A', 'B']),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(
      policy.isCandidate(
        _eligible.copyWith(explanation: '[图片]'),
        isStemOnly: false,
      ),
      isFalse,
    );
  });

  test('rejects proof questions and locally extractable answers', () {
    expect(
      policy.isCandidate(
        _eligible.copyWith(content: '证明该命题成立'),
        isStemOnly: false,
      ),
      isFalse,
    );
    expect(
      policy.isCandidate(
        _eligible.copyWith(explanation: '推导完成。答案为：42'),
        isStemOnly: false,
      ),
      isFalse,
    );
  });
}
