import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  var s1 = r'A. ( )2 1 2 2 , S Fnm S \sim';
  var s2 = r'$)2 1,N\mu\sigma 的简单随机样本， 12,,,mYYY是来自总$';
  var s3 = r'已知 a_n < b_n $$n=1,2,\cdots$$ , 若 \sum a_n 与 \sum b_n 均收敛';
  var s4 = r'已知 $a_n < b_n$ $$n=1,2,\cdots$$ , 若 $ \sum a_n $ 与 $ \sum b_n $ 均收敛';

  print('--- S1 ---');
  print(AiDataSanitizer.formatLatex(s1));
  print('--- S2 ---');
  print(AiDataSanitizer.formatLatex(s2));
  print('--- S3 ---');
  print(AiDataSanitizer.formatLatex(s3));
  print('--- S4 ---');
  print(AiDataSanitizer.formatLatex(s4));
}
