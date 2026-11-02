import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';

void main() {
  const question = Question(
    id: 'preview_question-1',
    type: 0,
    content: 'Synthetic question',
    options: '["A. One","B. Two"]',
    answer: 'A',
    createdAt: 1,
    bankName: 'synthetic',
    explanation: 'Synthetic explanation',
  );

  for (final brightness in Brightness.values) {
    testWidgets(
        'practice retains neutral $brightness preview colors and actions',
        (tester) async {
      // Practice retains its local neutral palette; host feedback colours are
      // inherited. The appearance contract does not yet adopt the global palette.
      final dark = brightness == Brightness.dark;
      final canvas = dark ? const Color(0xFF191A20) : const Color(0xFFF7F7FA);
      final surface = dark ? const Color(0xFF24252B) : Colors.white;
      final ink = dark ? const Color(0xFFEAEAF0) : const Color(0xFF303238);
      final selected = dark ? const Color(0xFF2D2E35) : const Color(0xFFF7F7FA);
      final outline = dark ? const Color(0xFF40414A) : const Color(0xFFE8E8EE);
      final correct = dark ? const Color(0xFF22362E) : const Color(0xFFF0F7F3);
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
      expect(scaffold.backgroundColor, canvas);

      final questionCard = tester.widget<Container>(
        find.byKey(const ValueKey<String>('practice-question-card')),
      );
      expect(
        (questionCard.decoration! as BoxDecoration).color,
        surface,
      );

      AnimatedContainer option() => tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('practice-option-0')),
          );
      Color optionTextColor(String text) =>
          tester.widget<Text>(find.text(text)).style!.color!;
      expect(
        (option().decoration! as BoxDecoration).color,
        surface,
      );
      expect(
        ((option().decoration! as BoxDecoration).border! as Border).top.color,
        outline,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('practice-option-1')),
      );
      await tester.pumpAndSettle();
      AnimatedContainer selectedOption() => tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('practice-option-1')),
          );
      expect(
        (selectedOption().decoration! as BoxDecoration).color,
        selected,
      );
      expect(optionTextColor('Two'), ink);

      await tester.tap(
        find.byKey(const ValueKey<String>('practice-reveal-answer')),
      );
      await tester.pumpAndSettle();
      expect(
        (option().decoration! as BoxDecoration).color,
        correct,
      );
      expect(optionTextColor('One'), ink);
      expect(find.text('正确答案'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(
        (selectedOption().decoration! as BoxDecoration).color,
        scheme.errorContainer,
      );
      expect(optionTextColor('Two'), scheme.onErrorContainer);
      expect(find.text('选择错误'), findsOneWidget);
      expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);

      // The preview_ fixture must never expose formal-session FSRS grades.
      expect(find.byKey(const ValueKey<String>('practice-grade-bar')),
          findsNothing);
      expect(find.text('丢弃').hitTestable(), findsOneWidget);
      final save = find.text('收入题库');
      expect(save.hitTestable(), findsOneWidget);
      final footer = find.ancestor(
          of: save,
          matching: find.byWidgetPredicate(
              (widget) => widget is Container && widget.color != null));
      expect(tester.widget<Container>(footer.first).color, surface);
      expect(tester.takeException(), isNull);
    });
  }
}
