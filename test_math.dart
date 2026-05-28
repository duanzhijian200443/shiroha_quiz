import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/ast.dart';
void main() {
  try {
    SyntaxTree(greenRoot: TexParser('n=1,2,\\cdots', const TexParserSettings()).parse());
    print("SUCCESS");
  } catch (e) {
    print("ERROR: $e");
  }
}
