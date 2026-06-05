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
