import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  print(AiDataSanitizer.formatLatex(r'$N(\mu, \sigma^2)$ 的简单随机样本'));
  print(AiDataSanitizer.formatLatex(r'N(μ, σ^2) 的简单随机样本'));
  print(AiDataSanitizer.formatLatex(r'a_n < b_n $$n=1,2,\cdots$$'));
  print(AiDataSanitizer.formatLatex(r'已知 a_n < b_n `$$n=1,2,\cdots$$` , 若'));
  print(AiDataSanitizer.formatLatex(r'已知 a_n < b_n ` $$n=1,2,\cdots$$ ` , 若'));
}
