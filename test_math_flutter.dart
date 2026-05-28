import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

void main() {
  testWidgets('Math.tex test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Math.tex('n=1,2,\\cdots\u200B', onErrorFallback: (e) => Text('ERROR: $e')),
        ),
      ),
    );
    expect(find.textContaining('ERROR'), findsNothing);
  });
}
