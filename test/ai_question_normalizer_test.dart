import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ai_question_normalizer.dart';

void main() {
  group('AiQuestionNormalizer tests', () {
    test('Type normalization of String, num, null', () {
      final input = [
        {'type': '2', 'content': 'Q1'}, // parsed string int
        {'type': 3.0, 'content': 'Q2'}, // parsed double num
        {'type': '填空题', 'content': 'Q3'}, // parsed display name
        {
          'type': null,
          'options': ['A', 'B'],
          'content': '下列哪项正确？'
        }, // parsed choice (has options)
        {
          'type': 0,
          'options': [],
          'content': 'Q5'
        }, // choice degraded to subjective (no options)
      ];

      final res = AiQuestionNormalizer.normalizeAll(input);
      expect(res.questions.length, 5);

      expect(res.questions[0]['type'], 2);
      expect(res.questions[1]['type'], 3);
      expect(res.questions[2]['type'], 2);
      expect(res.questions[3]['type'], 0);
      expect(res.questions[4]['type'],
          3); // Degraded from 0 to 3 because options list is empty
    });

    test('Options parsing from various shapes', () {
      final input = [
        {'options': null},
        {
          'content': '下列哪项正确？',
          'options': ['Opt A', 'Opt B']
        },
        {'content': '下列哪项正确？', 'options': '["Json Opt A", "Json Opt B"]'},
        {'content': '下列哪项正确？', 'options': "Line A\nLine B\nLine C"},
        {
          'content': '下列哪项正确？',
          'options': "A. choice X B. choice Y C. choice Z"
        },
      ];

      final res = AiQuestionNormalizer.normalizeAll(input);
      expect(res.questions.length, 5);

      expect(res.questions[0]['options'], isEmpty);
      expect(res.questions[1]['options'], ['Opt A', 'Opt B']);
      expect(res.questions[2]['options'], ['Json Opt A', 'Json Opt B']);
      expect(res.questions[3]['options'], ['Line A', 'Line B', 'Line C']);
      expect(res.questions[4]['options'],
          ['A. choice X', 'B. choice Y', 'C. choice Z']);
    });

    test('Answer field migration to standard_answer', () {
      final input = [
        {'answer': 'A', 'content': 'Q1'}, // standard_answer missing
        {
          'standard_answer': 'B',
          'answer': 'C',
          'content': 'Q2'
        }, // standard_answer wins
      ];

      final res = AiQuestionNormalizer.normalizeAll(input);
      expect(res.questions[0]['standard_answer'], 'A');
      expect(res.questions[1]['standard_answer'], 'B');
    });

    test('Placeholder answers are normalized to empty', () {
      final placeholders = [
        '无',
        '未提供',
        '未见答案',
        '暂无',
        'null',
        'none',
        'NULL',
        'NONE'
      ];
      for (final ph in placeholders) {
        final res = AiQuestionNormalizer.normalizeAll([
          {'standard_answer': ph, 'content': 'Q'}
        ]);
        expect(res.questions.first['standard_answer'], '');
      }
    });

    test('Empty content remains empty and is not overwritten', () {
      final res = AiQuestionNormalizer.normalizeAll([
        {'content': '', 'standard_answer': 'A'}
      ]);
      expect(res.questions.first['content'], '');
    });

    test('Non-map items and empty maps are dropped safely with diagnostics',
        () {
      final input = [
        null,
        'string item',
        123,
        {},
        {'content': 'Valid question'}
      ];

      final res = AiQuestionNormalizer.normalizeAll(input);
      expect(res.questions.length, 1);
      expect(res.droppedCount, 4);
      expect(res.questions.first['content'], 'Valid question');
      expect(res.diagnostics.containsKey('dropLogs'), true);
    });

    test('Polluted fields like sub_questions are removed', () {
      final input = [
        {
          'content': 'Q',
          'sub_questions': [
            {'content': 'Sub Q'}
          ]
        }
      ];

      final res = AiQuestionNormalizer.normalizeAll(input);
      expect(res.questions.first.containsKey('sub_questions'), false);
    });

    test('Subjective stem with hallucinated A-D content is coerced to essay',
        () {
      final res = AiQuestionNormalizer.normalizeAll([
        {
          'type': 0,
          'content':
              '设二次型，写出矩阵；求正交变换；求方程的解。\nA. 是充分非必要条件。\nB. 是充分必要条件。\nC. 是必要非充分条件。',
          'options': ['A. 是充分非必要条件', 'B. 是充分必要条件', 'C. 是必要非充分条件'],
          'standard_answer': 'A',
        }
      ]);

      final q = res.questions.single;
      expect(q['type'], 3);
      expect(q['options'], isEmpty);
      expect(q['content'], '设二次型，写出矩阵；求正交变换；求方程的解。');
      expect(res.warnings.any((w) => w.contains('脑补')), true);
    });

    test('Non-essay explanations are removed', () {
      final res = AiQuestionNormalizer.normalizeAll([
        {
          'type': 2,
          'content': '函数的极值为___。',
          'standard_answer': '0',
          'explanation': '这里是模型多生成的解析',
        }
      ]);

      final q = res.questions.single;
      expect(q['type'], 2);
      expect(q['explanation'], '');
    });
  });
}
