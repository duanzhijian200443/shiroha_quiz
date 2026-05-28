import 'dart:convert';
void main() {
  String jsonStr = '{"text": "\\\\begin and \\\\pi and \\\\n"}';
  print("Double escaped: " + jsonDecode(jsonStr)['text']);
  
  String jsonStr2 = '{"text": "\\begin and \\pi"}';
  try {
    print("Single escaped: " + jsonDecode(jsonStr2)['text']);
  } catch(e) {
    print("Single escaped error: $e");
  }

  // What if the string has \ b e g i n
  String jsonStr3 = '{"text": "\\begin"}';
  try {
    String decoded = jsonDecode(jsonStr3)['text'];
    print("Single escaped \\begin: " + decoded);
    print("Code units: " + decoded.codeUnits.toString());
  } catch(e) {
    print("Single escaped \\begin error: $e");
  }
}
