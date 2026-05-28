import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  String input = r'已知 a_n < b_n $$n=1,2,\cdots$$ , 若 \sum a_n 与 \sum b_n 均收敛，则 \sum a_n 绝对收敛是 \sum b_n 绝对收敛的';
  String output = AiDataSanitizer.formatLatex(input);
  print('OUTPUT:');
  print(output);
}
