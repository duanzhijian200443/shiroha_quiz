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

  test('strips odd trailing backslash inside wrapped formula', () {
    const input = r'\(\frac{E(XY)-E(X)E(Y)}{\sqrt{Var(X)Var(Y)}}=\frac{1}{\sqrt{1\cdot2}}=\frac{\sqrt{2}}{2}\\)';
    final output = repair.repairInline(input);

    expect(output, contains(r'\frac{E(XY)-E(X)E(Y)}'));
    expect(
      output,
      r'\(\frac{E(XY)-E(X)E(Y)}{\sqrt{Var(X)Var(Y)}}=\frac{1}{\sqrt{1\cdot2}}=\frac{\sqrt{2}}{2}\)',
    );
  });

  test('keeps even trailing slashes (matrix row ends) untouched', () {
    const input = r'\[\begin{matrix}1 & 2\\3 & 4\end{matrix}\]';
    final output = repair.repairInline(input);

    expect(output, input);
  });

  test('wraps math set block with escaped braces', () {
    const input = r'D = \{(x,y) | y - 2 \le x \le \sqrt{4-y^2}, 0 \le y \le 2\}';
    final output = repair.repairInline(input);

    expect(output, contains(r'D = '));
    expect(output, contains(r'\{(x,y)'));
    expect(
      output.contains(r'\(\{') || output.contains(r'\[\{'),
      isTrue,
    );
    expect(
      output.contains(r'\}\)') || output.contains(r'\}\]'),
      isTrue,
    );
  });

  test('wraps polar coordinate set block', () {
    const input = r'D_1 = \{(r,\theta) | 0 \le r \le 2, 0 \le \theta \le \frac{\pi}{2}\}';
    final output = repair.repairInline(input);

    expect(output, contains(r'D_1 = '));
    expect(
      output.contains(r'\(\{') || output.contains(r'\[\{'),
      isTrue,
    );
    expect(output, contains(r'\frac{\pi}{2}'));
  });

  test('does NOT wrap plain escaped braces (no math)', () {
    const input = r'这里的 \{注意事项\} 不是数学公式';
    final output = repair.repairInline(input);

    expect(output, equals(input));
  });

  // ═══════════════════════════════════════════════════════════
  // Step 5-A failure-capture tests for remaining bare-LaTeX gaps.
  // These tests describe desired behaviour that the current
  // repairer does NOT yet implement.  Do NOT modify production
  // code in this step — only lock in the test contracts.
  // ═══════════════════════════════════════════════════════════

  group('Step 5-A — failure capture (known gaps)', () {
    test('bare \'{...}\' Cartesian set block should be wrapped', () {
      const input =
          r'D = {(x,y) | y - 2 \le x \le \sqrt{4-y^2}, 0 \le y \le 2}';
      final output = repair.repairInline(input);

      // keep surrounding text
      expect(output, contains(r'D = '));

      // internal command must not stay bare
      expect(output, contains(r'\sqrt{4-y^2}'));

      // must have been changed (not a no-op)
      expect(output, isNot(equals(input)));

      // the set-block should be delimited with visible LaTeX braces
      expect(
        output.contains(r'\(\{(x,y)') || output.contains(r'\[\{(x,y)'),
        isTrue,
        reason: 'bare {…} math set should be wrapped with visible braces',
      );
      expect(
        output.contains(r'\}\)') || output.contains(r'\}\]'),
        isTrue,
        reason: 'closing visible brace delimiter after the set block',
      );
    });

    test('bare \'{...}\' polar set block should be wrapped', () {
      const input =
          r'D_1 = {(r,\theta) | 0 \le r \le 2, 0 \le \theta \le \frac{\pi}{2}}';
      final output = repair.repairInline(input);

      // keep surrounding text
      expect(output, contains(r'D_1 = '));

      // internal frac must not stay bare
      expect(output, contains(r'\frac{\pi}{2}'));

      // must have been changed
      expect(output, isNot(equals(input)));

      expect(
        output.contains(r'\(\{(r,\theta)') || output.contains(r'\[\{(r,\theta)'),
        isTrue,
        reason: 'bare {…} polar set should be wrapped with visible braces',
      );
    });

    test('bare \'{...}\' with multiple fracs should be whole-wrapped', () {
      const input =
          r'D_2 = {(r,\theta) | 0 \le r \le \frac{2}{\sin\theta - \cos\theta}, \frac{\pi}{2} \le \theta \le \pi}';
      final output = repair.repairInline(input);

      // keep surrounding text
      expect(output, contains(r'D_2 = '));

      // both internal fracs must exist
      expect(output, contains(r'\frac{2}{\sin\theta - \cos\theta}'));
      expect(output, contains(r'\frac{\pi}{2}'));

      // must have been changed
      expect(output, isNot(equals(input)));

      expect(
        output.contains(r'\(\{(r,\theta)') || output.contains(r'\[\{(r,\theta)'),
        isTrue,
        reason: 'bare set with multiple fracs should be whole-wrapped',
      );
    });

    test('plain Chinese bare braces without math must NOT be wrapped', () {
      const input = '这里的 {注意事项} 不是数学公式';
      final output = repair.repairInline(input);

      expect(output, equals(input));
    });

    test('Unicode contour-integral fragment should be wrapped', () {
      const input =
          r'计算 I = ∮_L(yz^2-\cos z)dx+2xz^2dy+(2xyz+x\sin z)dz';
      final output = repair.repairInline(input);

      // ∮ is normalised to \oint, but we assert the result is not the input
      expect(output, contains(r'\oint_L'));
      expect(output, contains(r'\sin z'));

      // must have been changed
      expect(output, isNot(equals(input)));

      // the formula part should be delimited with \oint (normalised)
      expect(
        output.contains(r'\(\oint_L') || output.contains(r'\[\oint_L'),
        isTrue,
        reason: 'Unicode ∮ should be normalised to \\oint and wrapped',
      );
    });

    test('plain-text integral symbol mention must NOT be wrapped', () {
      const input = '符号 ∮ 表示曲线积分，不是具体计算公式';
      final output = repair.repairInline(input);

      // plain explanatory text — no-op
      expect(output, equals(input));
    });
  });
}
