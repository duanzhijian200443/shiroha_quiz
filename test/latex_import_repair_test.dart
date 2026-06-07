import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/latex_import_repair.dart';
import 'package:shiroha_quiz/utils/content_tokenizer.dart';

void main() {
  const repair = LatexImportRepairService.instance;

  test('wraps short bare commands as inline math', () {
    const input = r'答案为 \frac{1}{2}';
    final output = repair.repairInline(input);

    expect(output, r'答案为 \(\frac{1}{2}\)');
  });

  test('keeps existing delimiters unchanged', () {
    const input = r'已包裹 \(x_i\)，块级 \[\sqrt{x}\]';
    final output = repair.repairInline(input);

    expect(output, input);
  });

  test('wraps matrix equations as block math without parse errors', () {
    const input =
        r'矩阵 \begin{pmatrix}x\\y\end{pmatrix}=\begin{pmatrix}1\\0\end{pmatrix}，可得结论';
    final output = repair.repairInline(input);
    final tokens = ContentTokenizer.tokenize(output);

    expect(
      output,
      r'矩阵 \[\begin{pmatrix}x\\y\end{pmatrix}=\begin{pmatrix}1\\0\end{pmatrix}\]，可得结论',
    );
    expect(tokens.whereType<BlockMathToken>(), hasLength(1));
    expect(tokens.whereType<ParseErrorToken>(), isEmpty);
  });

  test('leaves unsafe unbalanced environments untouched', () {
    const input = r'坏公式 \begin{pmatrix}1&2';
    final output = repair.repairInline(input);

    expect(output, input);
  });

  test('unclosed \\( skips delimiter only, continues scanning', () {
    const input = r'前文 \( 坏公式 后文 \iint_D \frac{(x-y)^2}{x^2+y^2} dxdy';
    final output = repair.repairInline(input);
    final tokens = ContentTokenizer.tokenize(output);

    // The opening \( is skipped; later bare LaTeX is wrapped.
    expect(output, contains(r'\iint_D'));
    expect(
      output.contains(r'\(') || output.contains(r'\['),
      isTrue,
    );
    expect(output, isNot(equals(input)));
    // No parse errors from broken delimiter remnants.
    expect(tokens.whereType<ParseErrorToken>(), isEmpty);
  });

  test('unclosed \\[ does not block later bare \\sqrt', () {
    const input = r'解析 \[ 未闭合 之后有 \sqrt{x^2+y^2}';
    final output = repair.repairInline(input);

    expect(output, contains(r'\sqrt'));
    expect(output, contains(r'\sqrt{x^2+y^2}'));
    expect(
      output.contains(r'\(\sqrt{x^2+y^2}\)') ||
          output.contains(r'\[\sqrt{x^2+y^2}\]'),
      isTrue,
    );
  });

  test('unclosed \$ does not block later bare \\sin', () {
    const input = r'坏美元 $ 后面有 \sin\theta + \cos\theta';
    final output = repair.repairInline(input);

    expect(output, contains(r'\sin'));
    expect(output, contains(r'\cos'));
    expect(
      output.contains(r'\(') || output.contains(r'\['),
      isTrue,
    );
  });

  test('already wrapped delimiters are not re-wrapped', () {
    const input = r'已知 \(x^2+y^2=1\)，求 \frac{1}{2}';
    final output = repair.repairInline(input);

    expect(output, contains(r'\(x^2+y^2=1\)'));
    expect(output, isNot(contains(r'\(\(x^2+y^2=1\)\)')));
    expect(output, contains(r'\frac{1}{2}'));
  });

  test('repairs all import draft fields without mutating source map', () {
    final source = {
      'content': r'题干 \sqrt{x}',
      'standard_answer': r'\frac{1}{2}',
      'explanation': r'\begin{pmatrix}1&0\\0&1\end{pmatrix}',
      'options': [r'A. \pi', 1],
    };

    final repaired = repair.repairQuestion(source);

    expect(source['content'], r'题干 \sqrt{x}');
    expect(repaired['content'], r'题干 \(\sqrt{x}\)');
    expect(repaired['standard_answer'], r'\(\frac{1}{2}\)');
    expect(
      repaired['explanation'],
      r'\[\begin{pmatrix}1&0\\0&1\end{pmatrix}\]',
    );
    expect(repaired['options'], [r'A. \(\pi\)', 1]);
  });
}
