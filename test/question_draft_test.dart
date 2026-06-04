import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';

void main() {
  group('QuestionDraft', () {
    test('normalizes AI map payloads into typed drafts', () {
      final draft = QuestionDraft.fromMap({
        'type': '2',
        'content': ' 题干 ',
        'options': '["A. x", "B. y"]',
        'answer': ' 42 ',
        'explanation': ' because ',
      });

      expect(draft.type, QuestionType.fillBlank);
      expect(draft.type.displayName, '填空题');
      expect(draft.content, '题干');
      expect(draft.options, ['A. x', 'B. y']);
      expect(draft.standardAnswer, '42');
      expect(draft.explanation, 'because');
    });

    test('falls back defensively for malformed fields', () {
      final draft = QuestionDraft.fromMap({
        'type': 99,
        'options': 'A. only option',
      });

      expect(draft.type, QuestionType.singleChoice);
      expect(draft.content, '无题干');
      expect(draft.options, ['A. only option']);
      expect(draft.hasAnswerOrExplanation, isFalse);
    });
  });
}
