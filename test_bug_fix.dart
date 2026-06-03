import 'package:shiroha_quiz/ui/widgets/markdown_extensions.dart';
import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  String input = "矩阵为\\\\begin{pmatrix}1 \\\\ 2 \\\\ 3\\\\end{pmatrix}";
  print("Input: $input");
  
  // Test replacing missing newline backslashes
  String replaced1 = input.replaceAll(RegExp(r'\\(?=\r?\n)'), r'\\');
  print("After step 1: $replaced1");
  
  String body = "1 \\ \n 2 \\ \n 3"; // JSON output with newlines
  String replaced2 = body.replaceAll(RegExp(r'\\(?=\r?\n)'), r'\\');
  print("After newline replacement: $replaced2");
  
  String replaced3 = replaced2.replaceAllMapped(RegExp(r'\\\\|\\([a-zA-Z0-9]+|.)', dotAll: true), (m) {
    return '==> matched';
  });
  print("Regex dotAll: $replaced3");
}
