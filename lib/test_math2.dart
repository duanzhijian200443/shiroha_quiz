import 'package:flutter/foundation.dart';
import 'package:flutter_math_fork/tex.dart';

void main() {
  try {
    SyntaxTree(
      greenRoot: TexParser(
              r"\begin{split} D_1 &= \left\{ (r,\theta) \; \middle| \; 0 \leqslant r \end{split}",
              const TexParserSettings())
          .parse(),
    );
    debugPrint("Success");
  } catch (e) {
    debugPrint("Crash: $e");
  }
}
