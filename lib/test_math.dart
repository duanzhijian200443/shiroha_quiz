import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(
        child: Math.tex(
          r"\begin{split} D_1 &= \left\{ (r,\theta) \; \middle| \; 0 \leqslant r \end{split}",
          mathStyle: MathStyle.display,
          onErrorFallback: (err) => Text("Crash: $err"),
        ),
      ),
    ),
  ));
}
