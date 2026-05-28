import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  try {
    print(AiDataSanitizer.formatLatex(r'$'));
  } catch(e) {
    print('CRASH: $e');
  }
}
