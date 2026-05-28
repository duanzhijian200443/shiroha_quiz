import 'dart:convert';

void main() {
  // LLM outputs: A & O \\ E & B  (2 slashes)
  String jsonStr1 = '{"text": "A & O \\\\ E & B"}';
  
  // LLM outputs correctly: A & O \\\\ E & B (4 slashes)
  String jsonStr2 = '{"text": "A & O \\\\\\\\ E & B"}';
  
  String fixSlashes(String input) {
    // Replace 2 slashes with 4 slashes
    return input.replaceAllMapped(RegExp(r'(?<!\\)\\\\(?!\\)'), (match) {
       return r'\\\\';
    });
  }

  print("Fixed 1: " + jsonDecode(fixSlashes(jsonStr1))['text']);
  print("Fixed 2: " + jsonDecode(fixSlashes(jsonStr2))['text']);
}
