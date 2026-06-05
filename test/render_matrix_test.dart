import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/widgets/markdown_extensions.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';
import 'package:shiroha_quiz/utils/content_normalizer.dart';
import 'package:shiroha_quiz/utils/content_tokenizer.dart';

void main() {
  test('normalizer converts paired dollar delimiters only', () {
    const input = r'Let $x_i$ and $$\sum_{i=1}^{n}x_i$$, price is $5.';
    final output = ContentNormalizer.normalizeForStorage(input);

    expect(output, contains(r'\(x_i\)'));
    expect(output, contains(r'\[\sum_{i=1}^{n}x_i\]'));
    expect(output, contains(r'price is $5.'));
  });

  test('normalizer folds double delimiters to single', () {
    const input1 = r'\(\(\frac{1}{2},0,0\)\)';
    expect(
        ContentNormalizer.normalizeForStorage(input1), r'\(\frac{1}{2},0,0\)');

    const input2 = r'\(\(a\) + \(b\)\)';
    expect(ContentNormalizer.normalizeForStorage(input2), r'\(a\) + \(b\)');

    const input3 = r'\[\[A\]\]';
    expect(ContentNormalizer.normalizeForStorage(input3), r'\[A\]');
  });

  test(
      'normalizer avoids double-wrapping already wrapped formulas in dollar conversion',
      () {
    const input1 = r'$\(x\)$';
    expect(ContentNormalizer.normalizeForStorage(input1), r'\(x\)');

    const input2 = r'$$\[y\]$$';
    expect(ContentNormalizer.normalizeForStorage(input2), r'\[y\]');

    const input3 = r'$\(a\) + \(b\)$';
    expect(ContentNormalizer.normalizeForStorage(input3), r'\(a\) + \(b\)');
  });

  test('normalizer extracts blanks from explicit math', () {
    const input = r'Find \(a=___\), then answer ____.';
    final output = ContentNormalizer.normalizeForStorage(input);

    expect(output, r'Find \(a=\)___, then answer ____.');
  });

  test('sanitizer does not auto-wrap bare LaTeX commands', () {
    const input = r'A. \frac{1}{4} and x_i';
    final output = AiDataSanitizer.cleanLatexBeforeDB(input);

    expect(output, input);
    expect(AiDataSanitizer.findBareLatexCommands(output), contains('frac'));
  });

  test('tokenizer emits structured tokens without guessing bare LaTeX', () {
    const input =
        r'When \(x_i\) then ___ and \[\begin{pmatrix}1&2\\3&4\end{pmatrix}\] but \frac{1}{2}.';
    final tokens = ContentTokenizer.tokenize(input);

    expect(tokens.whereType<InlineMathToken>(), hasLength(1));
    expect(tokens.whereType<BlankToken>(), hasLength(1));
    expect(tokens.whereType<BlockMathToken>(), hasLength(1));
    expect(tokens.whereType<TextToken>().last.text, contains(r'\frac{1}{2}'));
  });

  test('tokenizer isolates unclosed delimiters as parse errors', () {
    const input = r'Before \(x_i and after text';
    final tokens = ContentTokenizer.tokenize(input);

    expect(tokens.whereType<ParseErrorToken>(), hasLength(1));
    expect(tokens.whereType<ParseErrorToken>().single.raw,
        r'\(x_i and after text');
  });

  test(
      'cleanAndParseJson repairs JSON LaTeX escapes without wrapping bare math',
      () {
    const raw = r'''
    {"questions":[{"type":0,"content":"Stem with \(x_i\)","options":["A. \frac{1}{4}","B. \(\\frac{1}{2}\)"],"standard_answer":"B"}]}
    ''';
    final parsed = AiDataSanitizer.cleanAndParseJson(raw);
    final options = parsed.first['options'] as List;

    expect(parsed.first['content'], r'Stem with \(x_i\)');
    expect(options[0], r'A. \frac{1}{4}');
    expect(options[1], r'B. \(\frac{1}{2}\)');
  });

  testWidgets('buildLatexWidget renders explicit inline math and blanks',
      (tester) async {
    const text = r'When \(x_i\geq 0\), fill ___ here.';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
    expect(find.byType(BlankTokenWidget), findsOneWidget);
  });

  testWidgets('buildLatexWidget leaves old bare LaTeX as text', (tester) async {
    const text = r'A. \frac{1}{4}';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsNothing);
    expect(find.textContaining(r'\frac{1}{4}', findRichText: true),
        findsOneWidget);
  });

  testWidgets('buildLatexWidget handles xlongequal defensively',
      (tester) async {
    const text = r'Formula \(a \xlongequal{\text{ok}} b\).';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining('[LaTeX fallback]'), findsNothing);
  });

  testWidgets('buildLatexWidget normalizes unicode math symbols in math only',
      (tester) async {
    const text = 'Formula \\(∬_Σ_1 (−2xz)dydz\\).';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('buildLatexWidget renders explicit block matrix', (tester) async {
    const text = r'\[\begin{pmatrix}1&2\\3&4\end{pmatrix}\]';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('buildLatexWidget promotes complex inline math to block view',
      (tester) async {
    const text = r'Before \(\begin{pmatrix}1&2\\3&4\end{pmatrix}\) after';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);
  });
}
