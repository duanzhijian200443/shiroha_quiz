import 'package:shiroha_quiz/utils/content_normalizer.dart';
import 'package:shiroha_quiz/utils/content_tokenizer.dart';

void main() {
  final input = r'\( \( (1, 2, 3)^T\)';
  final normalized = ContentNormalizer.normalizeForRender(input);
  print('Normalized: $normalized');

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
