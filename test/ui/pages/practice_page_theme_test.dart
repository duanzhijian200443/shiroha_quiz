import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';

void main() {
  const question = Question(
    id: 'question-1',
    type: 0,
    content: 'Synthetic question',
    options: '["A. One","B. Two"]',
    answer: 'A',
    createdAt: 1,
    bankName: 'synthetic',
    explanation: 'Synthetic explanation',
  );

  for (final brightness in Brightness.values) {
    testWidgets('practice colors follow the $brightness color scheme',
        (tester) async {
      final scheme = ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: brightness,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: const PracticePage(initialQuestions: <Question>[question]),
        ),
      );
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey<String>('practice-page-scaffold')),
      );
      expect(scaffold.backgroundColor, scheme.surface);

      final questionCard = tester.widget<Container>(
        find.byKey(const ValueKey<String>('practice-question-card')),
      );
      expect(
        (questionCard.decoration! as BoxDecoration).color,
        scheme.surfaceContainerLow,
      );

      AnimatedContainer option() => tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('practice-option-0')),
          );
      expect(
        (option().decoration! as BoxDecoration).color,
        scheme.surfaceContainerLow,
      );
      expect(
        ((option().decoration! as BoxDecoration).border! as Border).top.color,
        scheme.outlineVariant,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('practice-option-0')),
      );
      await tester.pumpAndSettle();
      expect(
        (option().decoration! as BoxDecoration).color,
        scheme.primaryContainer,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('practice-reveal-answer')),
      );
      await tester.pumpAndSettle();
      expect(
        (option().decoration! as BoxDecoration).color,
        scheme.tertiaryContainer,
      );

      final gradeBar = tester.widget<Container>(
        find.byKey(const ValueKey<String>('practice-grade-bar')),
      );
      expect(
        (gradeBar.decoration! as BoxDecoration).color,
        scheme.surfaceContainer,
      );
    });
  }
}
