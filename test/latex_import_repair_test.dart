import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/latex_import_repair.dart';

void main() {
  group('LatexImportRepairService Tests', () {
    final repairer = LatexImportRepairService.instance;

    test('Should wrap bare \\frac', () {
      final input = r'求导得到 \frac{1}{x} 即可';
      final output = repairer.repairInline(input);
      expect(output, r'求导得到 \(\frac{1}{x}\) 即可');
    });

    test('Should not double wrap already wrapped \\(', () {
      final input = r'已经是 \(\frac{1}{x}\) 这样了';
      final output = repairer.repairInline(input);
      expect(output, r'已经是 \(\frac{1}{x}\) 这样了');
    });

    test(r'Should not double wrap already wrapped $$', () {
      final input = r'已经是 $$\frac{1}{x}$$ 这样了';
      final output = repairer.repairInline(input);
      expect(output, r'已经是 $$\frac{1}{x}$$ 这样了');
    });

    test('Should not double wrap already wrapped \\]', () {
      final input = r'已经是 \[\frac{1}{x}\] 这样了';
      final output = repairer.repairInline(input);
      expect(output, r'已经是 \[\frac{1}{x}\] 这样了');
    });

    test('Should handle plain Chinese text safely', () {
      final input = '这是普通的中文文本，没有任何公式。';
      final output = repairer.repairInline(input);
      expect(output, input);
    });

    test('Should stop wrapping when encountering Chinese', () {
      final input = r'由 \frac{a}{b}推导可得';
      final output = repairer.repairInline(input);
      // The repairer might stop at '推', wrapping only the \frac part
      expect(output, r'由 \(\frac{a}{b}\)推导可得');
    });

    test('Should repair full question map (standard_answer, options, explanation)', () {
      final Map<String, dynamic> question = {
        'content': r'已知 \int_0^1 x dx',
        'options': [
          r'\frac{1}{2}',
          r'\frac{1}{3}'
        ],
        'standard_answer': r'\frac{1}{2}',
        'explanation': r'根据积分公式 \frac{1}{2} x^2 得到',
      };

      final repaired = repairer.repairQuestion(question);

      expect(repaired['content'], r'已知 \(\int_0^1 x dx\)');
      expect((repaired['options'] as List)[0], r'\(\frac{1}{2}\)');
      expect((repaired['options'] as List)[1], r'\(\frac{1}{3}\)');
      expect(repaired['standard_answer'], r'\(\frac{1}{2}\)');
      expect(repaired['explanation'], r'根据积分公式 \(\frac{1}{2} x^2\) 得到');
    });
  });
}
