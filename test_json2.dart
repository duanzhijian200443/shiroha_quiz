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

  try {
    jsonDecode(json1);
  } catch (e) {
    print("Test 1: " + e.toString());
  }

  String json2 = '''[
  {
    "type": 0,
    "content": "hello"
  }
]
[注]
''';

  int startIndex = json2.indexOf('[');
  int endIndex = json2.lastIndexOf(']');
  String cleanText = json2.substring(startIndex, endIndex + 1);
  try {
    jsonDecode(cleanText);
  } catch (e) {
    print("Test 2: " + e.toString());
  }
}
