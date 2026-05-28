import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  testWidgets('Math.tex exact test with newline', (WidgetTester tester) async {
    bool crashed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Math.tex(
            'n=1,2,\\n\\cdots',
            mathStyle: MathStyle.display,
            textStyle: TextStyle(fontSize: 14, color: Colors.black),
            onErrorFallback: (e) {
              crashed = true;
              return Text('CRASHED');
            },
          ),
        ),
      ),
    );
    expect(crashed, true); // We EXPECT it to crash to test our theory
  });
}
