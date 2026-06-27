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
      expect(q['options'], hasLength(4));
      expect(q['standard_answer'], 'B');
      expect(q['content'].toString(), isNot(contains('答案')));
      expect(q['content'].toString(), isNot(contains('解析')));
      expect(q['source'], 'glm_ocr_intermediate');
    });

    test('drops explanation for fill blanks and preserves subjective parsing',
        () {
      final fillRegion = OcrQuestionRegion(
        number: 12,
        stemParts: const [
          '12 已知矩阵 A 和 E-A 可逆，求 B-A = ____。',
        ],
        answerParts: const ['-E'],
        explanationParts: const ['解析：填空题不应保留解析。'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0001'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.fillBlank,
      );

      final fillResult = const OcrQuestionAssembler().assemble(fillRegion);
      expect(fillResult.question['type'], 2);
      expect(fillResult.question['explanation'], '');
      expect(fillResult.question['raw_explanation'], isNull);
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
        explanationParts: const ['解析：填空题解析不应入库。'],
        sourcePageIndices: const [1],
        sourceBlockIds: const ['p001_b0001'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.fillBlank,
      );

      final fillResult =
          const OcrQuestionAssembler().assemble(fillWithoutBlank);
      expect(fillResult.question['type'], 2);
      expect(fillResult.question['options'], isEmpty);
      expect(fillResult.question['explanation'], '');

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
  });
}
