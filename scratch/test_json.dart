import 'dart:convert';
void main() {
  String rawText = '[{"type": 0, "content": "设\\\\\\lim\\\\\\limits_{x \\\\to 1} \\\\frac{f(x)}{\\\\\\ln x}"}]';
  print('Raw AI Output: ' + rawText);
  
  String cleanText = rawText;
  cleanText = cleanText.replaceAllMapped(RegExp(r'\\([^"\\/bfnrt])'), (match) {
      return '\\\\${match.group(1)}';
  });
  print('After regex: ' + cleanText);
  
  try {
    var decoded = jsonDecode(cleanText);
    print('Decoded: ' + decoded.toString());
  } catch (e) {
    print('Error: ' + e.toString());
  }
}
