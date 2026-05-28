import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(
        child: Math.tex(
          r'\begin{pmatrix} A & O \\ E & B \end{pmatrix} y = 0',
          mathStyle: MathStyle.display,
        ),
      ),
    ),
  ));
}
