// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

// import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/main.dart';

void main() {
  testWidgets('App starts and shows splash screen', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ShirohaQuizApp());

    // Verify that SplashScreen is shown initially.
    expect(find.byType(SplashScreen), findsOneWidget);
    
    // Verify that the app title is present.
    expect(find.text('Shiroha Quiz'), findsOneWidget);
  });
}
