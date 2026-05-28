import 'lib/utils/ai_data_sanitizer.dart';

void main() {
  String text = r'已知 a_n < b_n $$n=1,2,\cdots$$ , 若 \sum a_n 与 \sum b_n 均收敛';
  print("Before: " + text);
  print("After:  " + AiDataSanitizer.formatLatex(text));
}
