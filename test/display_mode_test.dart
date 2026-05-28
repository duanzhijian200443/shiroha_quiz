import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  test('Test display mode parsing', () {
    try {
      SyntaxTree tree = SyntaxTree(greenRoot: TexParser('n=1,2,\\cdots', const TexParserSettings()).parse());
      print("Success: $tree");
    } catch (e) {
      print("Error: $e");
    }
  });
}
