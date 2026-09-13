import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_bare_math_segmenter.dart';

/// Real OCR table cells from the 2022 mathematics paper remain the acceptance
/// shape: a bare distribution law carries no LaTeX command, and a
/// hypergeometric law mixes its formula with natural language.
const String _bareZeroOneLaw = r'P{X=k}=p^{k}(1-p)^{1-k},k=0,1';
const String _bareHypergeometricLaw =
    r'P{X=k}=\frac{C_{M}^{k}C_{N-M}^{n-k}}{C_{N}^{n}},k=0,1,\cdots,l,'
    '其中'
    r'l=\min\{n,M\},n\leqslant N';

void main() {
  group('OcrBareMathSegmenter', () {
    test('segments a command-free law as one whole-cell expression', () {
      final runs = OcrBareMathSegmenter.segment(_bareZeroOneLaw);

      expect(runs, hasLength(1));
      expect(runs.single.isMath, isTrue);
      expect(runs.single.start, 0);
      expect(runs.single.end, _bareZeroOneLaw.length);
    });

    test('keeps the prose of a mixed cell between two expressions', () {
      final runs = OcrBareMathSegmenter.segment(_bareHypergeometricLaw);

      expect(runs.map((run) => run.isMath).toList(), [true, false, true]);
      expect(
        _bareHypergeometricLaw.substring(runs[1].start, runs[1].end),
        '其中',
      );
      expect(
        _bareHypergeometricLaw.substring(runs[0].start, runs[0].end),
        r'P{X=k}=\frac{C_{M}^{k}C_{N-M}^{n-k}}{C_{N}^{n}},k=0,1,\cdots,l,',
      );
      expect(
        _bareHypergeometricLaw.substring(runs[2].start, runs[2].end),
        r'l=\min\{n,M\},n\leqslant N',
      );
    });

    test('leaves prose-only OCR cells literal', () {
      for (final text in const [
        '数学期望',
        '分布律或概率密度',
        '(0-1)分布',
        'np(1-p)',
        'p',
        'λ',
        'A有n个不同的特征值',
        'A的每个特征值对应的线性无关的特征向量的个数等于该特征值的重数',
        '价格',
      ]) {
        final runs = OcrBareMathSegmenter.segment(text);

        expect(runs.every((run) => !run.isMath), isTrue, reason: text);
      }
    });

    test('rejects ambiguous or truncated expression fragments', () {
      for (final text in const [
        r'ordinary \frac label = prose',
        r'价格=\frac{1}{p}',
        r'\frac',
        r'P{X=k',
        r'x+1',
        r'cost $5',
      ]) {
        final runs = OcrBareMathSegmenter.segment(text);

        expect(runs.every((run) => !run.isMath), isTrue, reason: text);
      }
    });

    test('admits a complete command-led expression next to prose', () {
      const text = r'概率为 \frac{1}{p} 时取到';

      final runs = OcrBareMathSegmenter.segment(text);

      expect(runs.map((run) => run.isMath).toList(), [false, true, false]);
      expect(text.substring(runs[1].start, runs[1].end).trim(), r'\frac{1}{p}');
    });

    test('delegates delimited math to the tokenizer path', () {
      for (final text in const [
        r'$x$ 与 $y$',
        r'公式 \(\frac{1}{p}\) 与 P{X=k}=p^{k}',
      ]) {
        final runs = OcrBareMathSegmenter.segment(text);

        expect(runs, hasLength(1), reason: text);
        expect(runs.single.isMath, isFalse, reason: text);
      }
    });

    test('runs always tile the input exactly', () {
      for (final text in const [
        _bareZeroOneLaw,
        _bareHypergeometricLaw,
        r'  前导空格 x=1 与 l=\min\{n,M\}',
        '数学期望',
        '分布律或概率密度',
        '',
        '  ',
      ]) {
        final runs = OcrBareMathSegmenter.segment(text);
        if (text.isEmpty) {
          expect(runs, isEmpty);
          continue;
        }

        expect(runs.first.start, 0, reason: text);
        expect(runs.last.end, text.length, reason: text);
        for (var index = 1; index < runs.length; index++) {
          expect(runs[index].start, runs[index - 1].end, reason: text);
        }
      }
    });
  });
}
