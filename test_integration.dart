import 'package:shiroha_quiz/services/latex_import_repair.dart';
import 'package:shiroha_quiz/utils/content_normalizer.dart';
import 'package:shiroha_quiz/utils/content_tokenizer.dart';

void main() {
  final repairer = LatexImportRepairService.instance;
  // Let's assume the AI outputted EXACTLY the text from the screenshot
  final aiOutput = r'(I) 计算特征多项式|\lambda E - A| = \lambda^2(\lambda - 14)，得特征值0（二重）和14。对于\lambda = 0，解方程组Ax = 0，得基础解系(-2, 1, 0)^T, (-3, 0, 1)^T ；对于\lambda = 14，解方程组(14E - A)x = 0，得基础解系 \((1, 2, 3)^T\) 。（II）将特征向量正交化、单位化，得到正交矩阵\(Q\) 。（III）二次型\(f(x_1, x_2, x_3) = 14y_1^2\)，故\(f(x_1, x_2, x_3) = 0\)的通解为特征向量的线性组合。';
  
  final repaired = repairer.repairInline(aiOutput);
  final normalized = ContentNormalizer.normalizeForRender(repaired);
  
  print('--- Normalized ---');
  print(normalized);
  
  print('\n--- Tokenization ---');
  final tokens = ContentTokenizer.tokenize(normalized);
  for (final t in tokens) {
    if (t is ParseErrorToken) {
      print('ERROR: ${t.reason}\n${t.raw}');
    } else if (t is InlineMathToken) {
      print('MATH: ${t.tex}');
    } else if (t is TextToken) {
      print('TEXT: ${t.text}');
    }
  }
}
