import 'package:shiroha_quiz/utils/content_normalizer.dart';
import 'package:shiroha_quiz/utils/content_tokenizer.dart';
import 'package:shiroha_quiz/services/latex_import_repair.dart';

void main() {
  final inputs = [
    r'对于 \lambda = 14，解方程组(14E - A)x = 0，得基础解系 \((1, 2, 3)^T\) 。（II）将特征向量正交化、单位化，得到正交矩阵\(Q\) 。（III）二次型\(f(x_1, x_2, x_3) = 14y_1^2\)，故\(f(x_1, x_2, x_3) = 0\)的通解为特征向量的线性组合。',
    r'得基础解系 \((1, 2, 3)^T\)',
    r'得基础解系\((1, 2, 3)^T\)',
    r'得基础解系 \(\((1, 2, 3)^T\)\)',
    r'得基础解系 \( \((1, 2, 3)^T\) \)',
  ];

  final repairer = LatexImportRepairService.instance;

  for (final input in inputs) {
    print('\n==============================');
    print('INPUT: $input');
    final repaired = repairer.repairInline(input);
    final normalized = ContentNormalizer.normalizeForRender(repaired);

    final tokens = ContentTokenizer.tokenize(normalized);
    for (final t in tokens) {
      if (t is ParseErrorToken) {
        print('  ERROR: ${t.reason}\n  RAW: ${t.raw}');
      }
    }
  }
}
