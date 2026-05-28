import 'dart:convert';
void main() {
  String correctAi = '[{"type": 0, "content": "设\\\\lim\\\\limits_{x \\\\to 1} \\\\frac{f(x)}{\\\\ln x}"}]';
  String wrongAi = '[{"type": 0, "content": "设\\lim\\limits_{x \\to 1} \\frac{f(x)}{\\ln x}"}]';
  
  String clean(String raw) {
    return raw.replaceAllMapped(RegExp(r'(?<!\\)\\([^"\\/bfnrt])'), (match) {
      return '\\\\${match.group(1)}';
    });
  }
  
  print('Correct AI raw: \$correctAi');
  print('Correct AI clean: \${clean(correctAi)}');
  print('Correct AI decoded: \${jsonDecode(clean(correctAi))}');
  
  print('Wrong AI raw: \$wrongAi');
  print('Wrong AI clean: \${clean(wrongAi)}');
  print('Wrong AI decoded: \${jsonDecode(clean(wrongAi))}');
}
