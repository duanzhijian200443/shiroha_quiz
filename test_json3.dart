import 'dart:convert';

void main() {
  String json1 = '''[
  {
    "type": 0,
    "content": "hello",
    "options": [
      "A",
      "B"
    ]''';

  String json2 = '''[
  {
    "type": 0,
    "content": "hello"
  }
]
[注]
''';

  void testRepair(String rawText) {
    int startIndex = rawText.indexOf('[');
    int endIndex = rawText.lastIndexOf(']');
    String cleanText = rawText.substring(startIndex, endIndex + 1);
    
    try {
      print(jsonDecode(cleanText));
    } catch (e) {
      print("Failed, trying repair...");
      int lastBrace = cleanText.lastIndexOf('}');
      if (lastBrace != -1) {
        String repaired = cleanText.substring(0, lastBrace + 1) + ']';
        try {
          print(jsonDecode(repaired));
        } catch (e2) {
          print("Repair failed: \$e2");
        }
      } else {
        print("No brace found.");
      }
    }
  }

  print("--- Test 1 ---");
  testRepair(json1);
  print("--- Test 2 ---");
  testRepair(json2);
}
