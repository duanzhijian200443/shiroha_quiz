import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_math_fork/tex.dart';

void main() {
  try {
    SyntaxTree tree = SyntaxTree(
      greenRoot: TexParser(
              r"\begin{split} D_1 &= \left\{ (r,\theta) \; \middle| \; 0 \leqslant r \end{split}",
              const TexParserSettings())
          .parse(),
    );
    print("Success");
  } catch (e) {
    print("Crash: $e");
  }
}
