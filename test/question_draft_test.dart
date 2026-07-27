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

    test('answer placeholders are not meaningful without explanation', () {
      for (final placeholder in const ['无', '暂无', '未知', '未提供', '未给出']) {
        final draft = QuestionDraft(
          type: QuestionType.shortAnswer,
          content: 'Question',
          options: const [],
          standardAnswer: placeholder,
          explanation: '',
        );

        expect(draft.hasAnswerOrExplanation, isFalse, reason: placeholder);
      }
    });

    test('explanation remains meaningful when standalone answer is missing',
        () {
      const draft = QuestionDraft(
        type: QuestionType.shortAnswer,
        content: 'Question',
        options: [],
        standardAnswer: '',
        explanation: 'Retained explanation',
      );

      expect(draft.hasAnswerOrExplanation, isTrue);
    });

    test('keeps raw and final explanation as distinct staging fields', () {
      final draft = QuestionDraft.fromMap({
        'type': 0,
        'content': 'Question',
        'options': const ['A', 'B'],
        'standard_answer': 'A',
        'explanation': '',
        'raw_explanation': 'Extracted provenance',
      });

      expect(draft.explanation, isEmpty);
      expect(draft.rawExplanation, 'Extracted provenance');
      expect(draft.hasAnswerOrExplanation, isTrue);
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
