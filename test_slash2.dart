import 'dart:convert';

void main() {
  String jsonStr3 = '{"text": "\\\\n"}';
  String fixSlashes(String input) {
    return input.replaceAllMapped(RegExp(r'(?<!\\)\\\\(?!\\)'), (match) {
       return r'\\\\';
    });
  }
  print("Fixed 3: " + jsonDecode(fixSlashes(jsonStr3))['text']);
}
