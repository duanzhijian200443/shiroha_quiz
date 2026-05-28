import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  String input = r"$\begin{pmatrix} A & O \\ E & B \end{pmatrix} y = 0$";
  String output = AiDataSanitizer.formatLatex(input);
  print("Output:");
  print(output);
}
