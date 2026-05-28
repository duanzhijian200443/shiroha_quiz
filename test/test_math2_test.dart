import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';

void main() {
  test('math test middle', () {
    try {
      SyntaxTree tree = SyntaxTree(
        greenRoot: TexParser(r"\left\{ (r,\theta) \; \middle| \; 0 \right\}", const TexParserSettings()).parse(),
      );
      print("Success middle");
    } catch (e) {
      dynamic err = e;
      print("Crash middle: " + err.message.toString());
    }
  });
}
