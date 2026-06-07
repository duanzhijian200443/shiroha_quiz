import 'package:shiroha_quiz/utils/content_tokenizer.dart';

void main() {
  final input =
      r'\((1, 2, 3)^T\) 。（II）将特征向量正交化、单位化，得到正交矩阵\(Q\) 。（III）二次型\(f(x_1, x_2, x_3) = 14y_1^2\)，故\(f(x_1, x_2, x_3) = 0\)的通解为特征向量的线性组合。';
  final tokens = ContentTokenizer.tokenize(input);
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
