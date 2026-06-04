import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/question_parse_pipeline.dart';

void main() {
  group('QuestionParsePipeline', () {
    const pipeline = QuestionParsePipeline();

    test('merges answer-only rows back into matching stems', () {
      final result = pipeline.mergeAnswerOnlyQuestions([
        {
          'q_num': '第 一 题',
          'content': '这是一道完整题干',
          'standard_answer': '',
        },
        {
          'q_num': '1）',
          'content': 'A',
          'standard_answer': 'A',
          'explanation': '因为选项 A 正确',
        },
      ]);

      expect(result.answerOnlyCount, 1);
      expect(result.questions, hasLength(1));
      expect(result.questions.first['standard_answer'], 'A');
      expect(result.questions.first['explanation'], '因为选项 A 正确');
      expect(result.diagnostics.single, contains('拼图成功'));
    });

    test('keeps unmatched answer-only rows to avoid data loss', () {
      final result = pipeline.mergeAnswerOnlyQuestions([
        {
          'q_num': '2',
          'content': 'B',
          'standard_answer': 'B',
        },
      ]);

      expect(result.answerOnlyCount, 1);
      expect(result.questions, hasLength(1));
      expect(result.questions.first['standard_answer'], 'B');
      expect(result.diagnostics.single, contains('已独立保留'));
    });
  });
}
