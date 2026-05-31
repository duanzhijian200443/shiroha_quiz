import 'dart:io';
import '../lib/utils/ai_data_sanitizer.dart';

void main() {
  String text1 = r"设函数y(x)是微分方程y' + 1/(2\sqrt x) y = 2 + \sqrt x的满足条件y(1)=3的解,求曲线y = y(x)的渐近线.";
  String text2 = r"\[ k_1 \begin{pmatrix}-2\\1\\0\end{pmatrix} + k_2 \begin{pmatrix}1\\1\\1\end{pmatrix} \]";
  String text3 = r"\[ \begin{cases} \frac{1}{2} \\ 0 \end{cases} \]";

  print("=== Text 1 ===");
  print(AiDataSanitizer.formatLatex(text1));
  print("\n=== Text 2 ===");
  print(AiDataSanitizer.formatLatex(text2));
  print("\n=== Text 3 ===");
  print(AiDataSanitizer.formatLatex(text3));
}
