import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
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

  test('normalizer preserves escaped commands and row breaks for renderer', () {
    const input = r'\[\\begin{pmatrix}1&2&3\\2&4&6\end{pmatrix}\]';
    final output = ContentNormalizer.normalizeForStorage(input);

    expect(output, input);
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
    {"questions":[{"type":0,"content":"选择正确的是：Stem with \(x_i\)\nA. \frac{1}{4}\nB. \(\\frac{1}{2}\)","options":["A. \frac{1}{4}","B. \(\\frac{1}{2}\)"],"standard_answer":"B"}]}
    ''';
    final parsed = AiDataSanitizer.cleanAndParseJson(raw);
    final options = parsed.first['options'] as List;

    expect(parsed.first['content'], contains(r'Stem with \(x_i\)'));
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

  testWidgets('buildLatexWidget renders escaped matrix from imported JSON',
      (tester) async {
    const text = r'A=\\[\\begin{pmatrix}1&2&3\\2&4&6\\3&6&9\end{pmatrix}\\]';

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
    expect(find.textContaining(r'\begin{pmatrix}', findRichText: true),
        findsNothing);
  });

  testWidgets('buildLatexWidget keeps matrix row breaks before variables',
      (tester) async {
    const text =
        r'\[\\begin{pmatrix}x_2\\x_3\end{pmatrix}=\\begin{pmatrix}1\\0\end{pmatrix}\]';

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
    expect(find.textContaining(r'\x_3', findRichText: true), findsNothing);
  });

  testWidgets('buildLatexWidget strips nested delimiters inside math',
      (tester) async {
    const text = r'\(\int (2 + \sqrt{x})e^{\(\int \frac{1}{2\sqrt{x}}dx\)}dx\)';

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
    expect(find.textContaining(r'\int', findRichText: true), findsNothing);
  });

  testWidgets('buildLatexWidget skips structurally unsafe left right formulas',
      (tester) async {
    const text = r'\(\left[\int\)';
    final debugMessages = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) debugMessages.add(message);
    };

    try {
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
      expect(find.textContaining(r'\left[\int', findRichText: true),
          findsOneWidget);
      expect(
        debugMessages,
        contains('Structured LaTeX render fallback: structurally_unsafe'),
      );
      expect(debugMessages.join('\n'), isNot(contains(r'\left[\int')));
    } finally {
      debugPrint = previousDebugPrint;
    }
  });

  testWidgets('renderer and final audit reject the same mismatched environment',
      (tester) async {
    const text = r'\(\begin{matrix}1\end{pmatrix}\)';
    final audited = auditFinalQuestionLatex({
      'content': text,
      'options': const <String>[],
      'standard_answer': '',
      'explanation': '',
    });

    expect(audited.invalidFields, ['content']);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructuredContentRenderer(text: text)),
      ),
    );

    expect(find.byType(Math), findsNothing);
    expect(
      find.textContaining(
        r'\begin{matrix}1\end{pmatrix}',
        findRichText: true,
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'renderer isolates one malformed math token without hiding valid neighbors',
      (tester) async {
    const malformed = r'\begin{array}{c}1\\2';
    const text = 'Before \\(x=1\\).\nBroken \\[$malformed\\]\nAfter \\(y=2\\).';
    final audited = auditFinalQuestionLatex({
      'content': '',
      'options': const <String>[],
      'standard_answer': '',
      'explanation': text,
    });

    expect(audited.invalidFields, ['explanation']);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructuredContentRenderer(text: text)),
      ),
    );

    expect(find.byType(Math), findsNWidgets(2));
    expect(find.textContaining(malformed, findRichText: true), findsOneWidget);
    expect(find.textContaining('Before', findRichText: true), findsOneWidget);
    expect(find.textContaining('After', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renderer keeps whole-field fallback when damage is not isolated',
      (tester) async {
    const text = r'Before \begin{array}{c}1\\2 after';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructuredContentRenderer(text: text)),
      ),
    );

    final fallback = tester.widget<Text>(find.text(text));
    expect(fallback.style?.color, Colors.deepOrange.shade900);
    expect(find.byType(Math), findsNothing);
  });

  testWidgets(
      'renderer and final audit accept the same bare array normalization',
      (tester) async {
    const text = r'\{\begin{array}{l}x_1=1\\x_2=2\end{array}';
    final audited = auditFinalQuestionLatex({
      'content': text,
      'options': const <String>[],
      'standard_answer': '',
      'explanation': '',
    });

    expect(audited.invalidFields, isEmpty);
    expect(audited.question['content'], '${r'\['}$text${r'\]'}');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructuredContentRenderer(text: text)),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining(r'\begin{array}', findRichText: true),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'renderer safely falls back for Q21-like missing array terminator',
      (tester) async {
    const text = r'''Before.
$$\begin{array}{l}
x_1=1\\
x_2=2
$$
说明文字。
$$\begin{array}{l}y_1=3\\y_2=4\end{array}$$''';
    final audited = auditFinalQuestionLatex({
      'content': '',
      'options': const <String>[],
      'standard_answer': '',
      'explanation': text,
    });

    expect(audited.invalidFields, ['explanation']);
    expect(audited.question['explanation'], text);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StructuredContentRenderer(text: text)),
      ),
    );

    expect(find.byType(Math), findsOneWidget);
    expect(
      find.textContaining(r'\begin{array}{l}', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('说明文字。', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'renderer refuses control-word-adjacent bare environment wrapping',
      (tester) async {
    for (final text in const [
      r'\text{\begin{matrix}1\end{matrix}}',
      r'\operatorname{foo}\begin{matrix}1\end{matrix}',
      r'\color{red}\begin{matrix}1\end{matrix}',
      r'\text {1}\begin{matrix}2\end{matrix}',
      r'\operatorname {+}\begin{matrix}1\end{matrix}',
      r'\color {1}\begin{matrix}2\end{matrix}',
    ]) {
      final audited = auditFinalQuestionLatex({
        'content': text,
        'options': const <String>[],
        'standard_answer': '',
        'explanation': '',
      });

      expect(audited.invalidFields, ['content'], reason: text);
      expect(audited.question['content'], text, reason: text);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StructuredContentRenderer(text: text)),
        ),
      );

      expect(find.byType(Math), findsNothing, reason: text);
      expect(find.text(text), findsOneWidget, reason: text);
      expect(tester.takeException(), isNull, reason: text);
    }
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

  testWidgets('buildLatexWidget degrades unclosed delimiters to plain text',
      (tester) async {
    const text = r'Before \(x_i and after text';

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
    expect(find.textContaining(r'\(x_i and after text', findRichText: true),
        findsOneWidget);
  });
}
