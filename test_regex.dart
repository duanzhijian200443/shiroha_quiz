import 'lib/utils/ai_data_sanitizer.dart';

void main() {
  String input = r'\( y = \mathrm{e}^{- \int \frac{1}{2 \sqrt{x}} \mathrm{d}x} \left[ \int (2 + \sqrt{x}) \mathrm{e}^{\int \frac{1}{2 \sqrt{x}} \mathrm{d}x} \mathrm{d}x + C_{0} \right] \)';
  print('Output:\n' + AiDataSanitizer.formatLatex(input));
}
