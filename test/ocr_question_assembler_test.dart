import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

void main() {
  group('OcrQuestionAssembler', () {
    test('extracts choice options and normalizes answer from OCR region', () {
      final region = OcrQuestionRegion(
        number: 1,
        stemParts: const [
          '1 设 lim f(x)/ln x = 1，则（ ）',
          '(A) f(1)=0',
          '(B) lim f(x)=0',
          '(C) f\'(1)=1',
          '(D) lim f\'(x)=1',
        ],
        answerParts: const ['B'],
        explanationParts: const ['解析：由极限可知 ...'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0001'],
        diagnostics: const [],
      );

      final result = const OcrQuestionAssembler().assemble(region);
      final q = result.question;

      expect(q['q_num'], '1');
      expect(q['question_number'], 1);
      expect(q['type'], 0);
      expect(q['options'], [
        'A. f(1)=0',
        'B. lim f(x)=0',
        'C. f\'(1)=1',
        'D. lim f\'(x)=1',
      ]);
      expect(q['standard_answer'], 'B');
      expect(q['content'], '设 lim f(x)/ln x = 1，则（ ）');
      expect(q['content'].toString(), isNot(contains('(A)')));
      expect(q['content'].toString(), isNot(contains('(D)')));
      expect(q['content'].toString(), isNot(contains('答案')));
      expect(q['content'].toString(), isNot(contains('解析')));
      expect(q['source'], 'glm_ocr_intermediate');
    });

    test('extracts inline parenthesized options from one OCR block', () {
      final region = OcrQuestionRegion(
        number: 2,
        stemParts: const [
          '2 选择正确表达式。'
              '(A) alpha value (B) beta value '
              '(C) gamma value (D) delta value',
        ],
        answerParts: const ['C'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0002'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.choice,
      );

      final question = const OcrQuestionAssembler().assemble(region).question;

      expect(question['options'], [
        'A. alpha value',
        'B. beta value',
        'C. gamma value',
        'D. delta value',
      ]);
      expect(question['content'], '选择正确表达式。');
      expect(question['content'].toString(), isNot(contains('(A)')));
      expect(question['content'].toString(), isNot(contains('(D)')));
    });

    test('extracts options split across two OCR blocks', () {
      final region = OcrQuestionRegion(
        number: 3,
        stemParts: const [
          '3 根据条件选择结论。',
          '(A) first choice (B) second choice',
          '(C) third choice (D) fourth choice',
        ],
        answerParts: const ['D'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0003', 'p001_b0004'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.choice,
      );

      final question = const OcrQuestionAssembler().assemble(region).question;

      expect(question['options'], [
        'A. first choice',
        'B. second choice',
        'C. third choice',
        'D. fourth choice',
      ]);
      expect(question['content'], '根据条件选择结论。');
    });

    test('accepts whitespace or newline after parenthesized labels', () {
      final region = OcrQuestionRegion(
        number: 4,
        stemParts: const [
          '4 选择一个结果。',
          '(A)\nfirst result',
          '(B)   second result',
          '(C)\n  third result',
          '(D) fourth result',
        ],
        answerParts: const ['A'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0005'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.choice,
      );

      final question = const OcrQuestionAssembler().assemble(region).question;

      expect(question['options'], [
        'A. first result',
        'B. second result',
        'C. third result',
        'D. fourth result',
      ]);
      expect(question['content'], '选择一个结果。');
    });

    test('does not split ordinary mathematical variables as options', () {
      const original = '5 已知矩阵 A、B、C、D，且 A+B=C，求 D 的表达式。';
      final region = OcrQuestionRegion(
        number: 5,
        stemParts: const [original],
        answerParts: const ['D=C-A-B'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0006'],
        diagnostics: const [],
      );

      final question = const OcrQuestionAssembler().assemble(region).question;

      expect(question['options'], isEmpty);
      expect(question['type'], 3);
      expect(question['content'], original.substring(2));
    });

    test('keeps a single parenthesized variable in the stem', () {
      const original = '6 设条件 (A) 成立，求目标量。';
      final region = OcrQuestionRegion(
        number: 6,
        stemParts: const [original],
        answerParts: const ['目标量'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0007'],
        diagnostics: const [],
      );

      final question = const OcrQuestionAssembler().assemble(region).question;

      expect(question['options'], isEmpty);
      expect(question['content'], original.substring(2));
    });

    test('keeps an incomplete option sequence in the stem', () {
      const original = '7 选择结论。(A) first (B) second (D) fourth';
      final region = OcrQuestionRegion(
        number: 7,
        stemParts: const [original],
        answerParts: const ['B'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0008'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.choice,
      );

      final result = const OcrQuestionAssembler().assemble(region);

      expect(result.question['options'], isEmpty);
      expect(result.question['content'], original.substring(2));
      expect(result.diagnostics, contains('choice_options_less_than_2'));
    });

    test('drops explanation for fill blanks and preserves subjective questions',
        () {
      final fillRegion = OcrQuestionRegion(
        number: 12,
        stemParts: const [
          '12 已知矩阵 A 和 E-A 可逆，求 B-A = ____。',
        ],
        answerParts: const ['-E'],
        explanationParts: const ['解析：填空题的合法解析。'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0001'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.fillBlank,
      );

      final fillResult = const OcrQuestionAssembler().assemble(fillRegion);
      expect(fillResult.question['type'], 2);
      expect(fillResult.question['explanation'], isEmpty);
      expect(fillResult.question['raw_explanation'], '填空题的合法解析。');
      expect(
        fillResult.question['diagnostics'],
        contains('dropped_non_subjective_explanation'),
      );

      final essayRegion = OcrQuestionRegion(
        number: 21,
        stemParts: const [
          '21 设二次型 f(x1,x2,x3) = ...',
        ],
        answerParts: const ['k(-1,1,0)^T'],
        explanationParts: const ['解析：由正交变换可得标准形。'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0002'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.subjective,
      );

      final essayResult = const OcrQuestionAssembler().assemble(essayRegion);
      expect(essayResult.question['type'], 3);
      expect(essayResult.question['explanation'], contains('正交变换'));
    });

    test('uses declared kind before local option and blank heuristics', () {
      final fillWithoutBlank = OcrQuestionRegion(
        number: 14,
        stemParts: const [
          '14 已知平面区域 D，计算 I。',
        ],
        answerParts: const [r'\frac{1}{2}'],
        explanationParts: const ['解析：填空题合法解析。'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0001'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.fillBlank,
      );

      final fillResult =
          const OcrQuestionAssembler().assemble(fillWithoutBlank);
      expect(fillResult.question['type'], 2);
      expect(fillResult.question['options'], isEmpty);
      expect(fillResult.question['explanation'], isEmpty);
      expect(fillResult.question['raw_explanation'], '填空题合法解析。');
      expect(
        fillResult.question['diagnostics'],
        contains('dropped_non_subjective_explanation'),
      );

      final choiceWithoutOptions = OcrQuestionRegion(
        number: 1,
        stemParts: const [
          '1 设 lim f(x)/ln x = 1，则（ ）',
        ],
        answerParts: const ['B'],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0002'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.choice,
      );

      final choiceResult =
          const OcrQuestionAssembler().assemble(choiceWithoutOptions);
      expect(choiceResult.question['type'], 0);
      expect(choiceResult.question['options'], isEmpty);
      expect(
        choiceResult.question['diagnostics'],
        contains('choice_options_less_than_2'),
      );
    });

    test('raw explanation can supply a deterministic choice answer', () {
      const region = OcrQuestionRegion(
        number: 8,
        stemParts: [
          '8 Question stem (A) first (B) second (C) third (D) fourth',
        ],
        answerParts: [],
        explanationParts: ['解析：由条件可知，故选 C。'],
        sourcePageIndices: [1],
        sourceBlockIds: ['p001_b0008'],
        diagnostics: [],
        declaredKind: TextQuestionKind.choice,
      );

      final result = const OcrQuestionAssembler().assemble(region);

      expect(result.question['standard_answer'], 'C');
      expect(result.question['explanation'], isEmpty);
      expect(result.question['raw_explanation'], contains('故选 C'));
    });
  });
}
