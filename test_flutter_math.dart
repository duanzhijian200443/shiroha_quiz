import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';

void main() {
  try {
    SyntaxTree tree = SyntaxTree(greenRoot: TexParser('n=1,2,\\cdots', const TexParserSettings()).parse());
    print("Success: $tree");
  } catch (e) {
    print("Error 1: $e");
  }

  try {
    SyntaxTree tree = SyntaxTree(greenRoot: TexParser(r'n=1,2,\cdots', const TexParserSettings()).parse());
    print("Success 2: $tree");
  } catch (e) {
    print("Error 2: $e");
  }
}
