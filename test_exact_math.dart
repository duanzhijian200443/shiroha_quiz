import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  testWidgets('Math.tex exact test', (WidgetTester tester) async {
    bool crashed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Math.tex(
            r'n=1,2,\cdots',
            mathStyle: MathStyle.text,
            textStyle: TextStyle(fontSize: 14, color: Colors.black),
            onErrorFallback: (e) {
              crashed = true;
              return Text('CRASHED');
            },
          ),
        ),
      ),
    );
    expect(crashed, false);
  });
}
