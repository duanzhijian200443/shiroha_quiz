import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';

void main() {
  test('Test n=1,2,cdots', () {
    try {
      SyntaxTree tree = SyntaxTree(greenRoot: TexParser('n=1,2,\\cdots', const TexParserSettings()).parse());
      print("Success 1: $tree");
    } catch (e) {
      print("Error 1: $e");
    }

    try {
      SyntaxTree tree = SyntaxTree(greenRoot: TexParser('\\begin{cases}x=t^2+2t\\y=\\sin t\\end{cases}', const TexParserSettings()).parse());
      print("Success 2: $tree");
    } catch (e) {
      print("Error 2: $e");
    }
  });
}
