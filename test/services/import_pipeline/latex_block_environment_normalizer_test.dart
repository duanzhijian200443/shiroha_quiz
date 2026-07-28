import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_block_environment_normalizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_renderability_checker.dart';

void main() {
  const normalizer = LatexBlockEnvironmentNormalizer();
  const checker = LatexRenderabilityChecker();

  group('LatexBlockEnvironmentNormalizer', () {
    test('treats an unmatched currency dollar as ordinary text', () {
      expect(checker.check(r'price is $5.').isRenderable, isTrue);
    });

    test('wraps allow-listed bare environments without changing their body',
        () {
      for (final environment in const ['array', 'matrix', 'cases']) {
        final columnSpec = environment == 'array' ? '{l}' : '';
        final input =
            '\\begin{$environment}$columnSpec x_1=1\\\\x_2=2\\end{$environment}';

        final result = normalizer.normalize(input);

        expect(result.changed, isTrue, reason: environment);
        expect(result.text, '\\[$input\\]', reason: environment);
        expect(result.renderability.isRenderable, isTrue, reason: environment);
      }
    });

    test(
        'keeps environments already inside supported math delimiters unchanged',
        () {
      for (final input in const [
        r'\(\begin{matrix}1&2\\3&4\end{matrix}\)',
        r'\[\begin{array}{cc}1&2\\3&4\end{array}\]',
        r'$$\begin{cases}x&x>0\\-x&x\leq0\end{cases}$$',
      ]) {
        final result = normalizer.normalize(input);
        expect(result.changed, isFalse, reason: input);
        expect(result.text, input, reason: input);
        expect(result.renderability.isRenderable, isTrue, reason: input);
      }
    });

    test('wraps only minimum environment spans and preserves order', () {
      const first = r'\begin{matrix}1&2\end{matrix}';
      const second = r'\begin{cases}x&x>0\end{cases}';
      const input = 'Before $first after.\nThen $second done.';

      final result = normalizer.normalize(input);

      expect(
          result.text, 'Before \\[$first\\] after.\nThen \\[$second\\] done.');
      expect(
          result.text.indexOf('Before'), lessThan(result.text.indexOf(first)));
      expect(
          result.text.indexOf(first), lessThan(result.text.indexOf('after')));
      expect(
        result.text.indexOf('Then'),
        lessThan(result.text.indexOf(second)),
      );
    });

    test('wraps screenshot-like brace plus array without inventing delimiters',
        () {
      const input = r'''\{\begin{array}{l}
x_1=\frac{1}{2}\\
x_2=y
\end{array}''';

      final result = normalizer.normalize(input);

      expect(result.text, '${r'\['}$input${r'\]'}');
      expect(result.text, isNot(contains(r'\left')));
      expect(result.text, isNot(contains(r'\right')));
      expect(result.text, contains(r'\frac{1}{2}\\'));
      expect(checker.check(result.text).isRenderable, isTrue);
    });

    test(
        'keeps a Q21-like missing array terminator unchanged for review',
        () {
      const input = r'''Before.
$$\begin{array}{l}
x_1=1\\
x_2=2
$$
说明文字。
$$\begin{array}{l}
y_1=3\\
y_2=4
\end{array}$$''';

      final result = normalizer.normalize(input);

      expect(result.changed, isFalse);
      expect(result.text, input);
      expect(result.renderability.isRenderable, isFalse);
      expect(RegExp(r'\\end\{array\}').allMatches(result.text), hasLength(1));
    });

    test('does not guess unsafe missing environment terminators', () {
      for (final input in const [
        r'$$\begin{array}{l}x',
        r'$$\begin{array}{l}x$$',
        r'\(\begin{matrix}1 & 2\)',
        r'$$\begin{array}{l}\begin{matrix}x\end{matrix}$$',
        r'$$\begin{array}x$$',
        r'$$\begin{array}{l}x\begin{matrix}y$$',
        r'$$\begin{array}{l}x\end{matrix}$$',
      ]) {
        final result = normalizer.normalize(input);

        expect(result.changed, isFalse, reason: input);
        expect(result.text, input, reason: input);
        expect(result.renderability.isRenderable, isFalse, reason: input);
      }
    });

    test('rejects incomplete, mismatched, unknown, and ambiguous structures',
        () {
      for (final input in const [
        r'\begin{array}{l}x',
        r'\begin{array}{l}x\end{matrix}',
        r'\begin{matrix}\begin{cases}x\end{matrix}\end{cases}',
        r'\begin{unknown}x\end{unknown}',
        r'\begin{array}{l x\end{array}',
        r'ordinary text\begin{matrix}x\end{matrix}',
        r'\text{ordinary}\begin{matrix}x\end{matrix}',
        r'\text{\begin{matrix}1\end{matrix}}',
        r'\operatorname{foo}\begin{matrix}1\end{matrix}',
        r'\color{red}\begin{matrix}1\end{matrix}',
        r'\text {1}\begin{matrix}2\end{matrix}',
        r'\operatorname {+}\begin{matrix}1\end{matrix}',
        r'\color {1}\begin{matrix}2\end{matrix}',
      ]) {
        final result = normalizer.normalize(input);
        expect(result.changed, isFalse, reason: input);
        expect(result.text, input, reason: input);
        expect(result.renderability.isRenderable, isFalse, reason: input);
      }
    });
  });
}
