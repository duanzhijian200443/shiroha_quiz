import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_fragment.dart';

void main() {
  group('QuestionFragment', () {
    test('full question 推导', () {
      final f = QuestionFragment.fromMap({
        'content': '1. Test question',
        'standard_answer': 'A',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.fullQuestion);
      expect(f.hasStem, true);
      expect(f.hasAnswer, true);
    });

    test('stem-only 推导', () {
      final f = QuestionFragment.fromMap({
        'content':
            '1. What is this? This is a long question stem to prevent partial detection.',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.stemOnly);
      expect(f.hasStem, true);
      expect(f.hasAnswer, false);
    });

    test('answer-only 推导 (!hasStem && hasAnswer)', () {
      final f = QuestionFragment.fromMap({
        'q_num': '1',
        'standard_answer': 'A',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.answerOnly);
      expect(f.hasStem, false);
      expect(f.hasAnswer, true);
    });

    test('answer-only 推导 (hasStem but very short like an answer)', () {
      final f = QuestionFragment.fromMap({
        'content': 'A',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.answerOnly);
      expect(f.hasStem, true);
      expect(f.hasAnswer, false);
    });

    test('partial 推导 (hasStem short text)', () {
      final f = QuestionFragment.fromMap({
        'content': 'what',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.partialQuestion);
    });

    test('空字段和类型异常不崩溃', () {
      final f = QuestionFragment.fromMap({
        'content': null,
        'standard_answer': null,
        'q_num': null,
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.orphan);
      expect(f.hasStem, false);
      expect(f.hasAnswer, false);
    });
    test('template placeholder stem is not treated as a real stem', () {
      final f = QuestionFragment.fromMap({
        'q_num': '11',
        'content': '题干内容',
        'standard_answer': 'A',
      }, source: QuestionFragmentSource.text, originalIndex: 0);

      expect(f.kind, QuestionFragmentKind.answerOnly);
      expect(f.hasStem, false);
      expect(f.hasAnswer, true);
    });

    test('Chinese placeholder answers are invalid answers', () {
      for (final placeholder in ['无', '未提供', '未见答案', '暂无']) {
        final f = QuestionFragment.fromMap({
          'content': 'Question stem',
          'standard_answer': placeholder,
        }, source: QuestionFragmentSource.text, originalIndex: 0);

        expect(f.hasAnswer, false);
        expect(f.kind, QuestionFragmentKind.stemOnly);
      }
    });
  });
}
