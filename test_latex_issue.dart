import 'dart:convert';
import 'lib/utils/ai_data_sanitizer.dart';

void main() {
  String json1 = r'{"content": "$\\begin{cases}x=t^2+2t\\\\y=\\sin t\\end{cases}$"}';
  String json2 = r'{"content": "$$n=1,2,\\cdots$$"}';
  String json3 = r'{"content": "$\\begin{pmatrix}E&AB\\\\AB&O\\end{pmatrix}$"}';

  var parsed1 = AiDataSanitizer.cleanAndParseJson('[$json1]');
  print("Parsed 1 (before format): " + parsed1[0]['content']);
  print("Parsed 1 (after format) : " + AiDataSanitizer.formatLatex(parsed1[0]['content']));
  
  var parsed2 = AiDataSanitizer.cleanAndParseJson('[$json2]');
  print("\nParsed 2 (before format): " + parsed2[0]['content']);
  print("Parsed 2 (after format) : " + AiDataSanitizer.formatLatex(parsed2[0]['content']));

  var parsed3 = AiDataSanitizer.cleanAndParseJson('[$json3]');
  print("\nParsed 3 (before format): " + parsed3[0]['content']);
  print("Parsed 3 (after format) : " + AiDataSanitizer.formatLatex(parsed3[0]['content']));
}
