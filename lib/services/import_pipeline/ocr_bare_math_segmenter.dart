import 'latex_renderability_checker.dart';

/// One maximal run of a bare OCR table-cell text.
///
/// Runs produced by [OcrBareMathSegmenter.segment] always tile the whole
/// input: `runs.first.start` is 0, `runs.last.end` is `text.length`, and every
/// run starts exactly where the previous one ends.
final class OcrBareMathRun {
  const OcrBareMathRun({
    required this.start,
    required this.end,
    required this.isMath,
  });

  final int start;
  final int end;
  final bool isMath;

  @override
  String toString() => 'OcrBareMathRun($start, $end, isMath: $isMath)';
}

/// Deterministic structural segmentation of undelimited OCR table-cell text.
///
/// OCR table cells frequently carry LaTeX that has no `$` / `\(` / `\[`
/// delimiter, and a single cell may mix an expression with natural language
/// (for example a distribution law followed by `其中 …`). This scanner
/// classifies every code unit as a math atom, a prose atom, or a separator,
/// groups maximal runs, and admits a run as math only when the run is
/// structurally an expression:
///
/// * the input contains no math delimiter, so delimited math keeps the
///   `ContentTokenizer` path owned by `OcrMathSourceMap.parse`;
/// * the run begins with a primary atom (variable, digit, group opener,
///   control sequence, or math symbol) rather than a relation or binary
///   operator, so a trailing `=…` fragment stays prose;
/// * the run contains a LaTeX control sequence or a structural operator
///   (`^`, `_`, `=`), so prose that merely contains a hyphen, a comma, or a
///   parenthesized number is never promoted to math;
/// * the run's group braces are balanced and [LatexRenderabilityChecker]
///   accepts it in math context.
///
/// A rejected run is folded back into the surrounding prose, so an ambiguous
/// cell keeps its exact literal text instead of being forced into math.
abstract final class OcrBareMathSegmenter {
  static const List<String> _mathDelimiters = <String>[
    r'$',
    r'\(',
    r'\)',
    r'\[',
    r'\]',
  ];

  /// Segments [text] into alternating prose and math runs.
  static List<OcrBareMathRun> segment(String text) {
    if (text.isEmpty) return const <OcrBareMathRun>[];
    if (_mathDelimiters.any(text.contains)) {
      return <OcrBareMathRun>[
        OcrBareMathRun(start: 0, end: text.length, isMath: false),
      ];
    }

    final grouped = <OcrBareMathRun>[];
    var runStart = 0;
    var runIsMath = false;
    var started = false;
    var index = 0;
    while (index < text.length) {
      final atom = _readAtom(text, index);
      if (!atom.isSeparator) {
        if (!started) {
          started = true;
          runIsMath = atom.isMath;
        } else if (atom.isMath != runIsMath) {
          grouped.add(
            OcrBareMathRun(start: runStart, end: index, isMath: runIsMath),
          );
          runStart = index;
          runIsMath = atom.isMath;
        }
      }
      index = atom.end;
    }
    if (!started) {
      return <OcrBareMathRun>[
        OcrBareMathRun(start: 0, end: text.length, isMath: false),
      ];
    }
    grouped.add(
      OcrBareMathRun(start: runStart, end: text.length, isMath: runIsMath),
    );

    final admitted = <OcrBareMathRun>[];
    for (final run in grouped) {
      final isMath = run.isMath && _admits(text.substring(run.start, run.end));
      if (!isMath && admitted.isNotEmpty && !admitted.last.isMath) {
        admitted[admitted.length - 1] = OcrBareMathRun(
          start: admitted.last.start,
          end: run.end,
          isMath: false,
        );
      } else {
        admitted.add(
          OcrBareMathRun(start: run.start, end: run.end, isMath: isMath),
        );
      }
    }
    return List<OcrBareMathRun>.unmodifiable(admitted);
  }

  static bool _admits(String run) {
    final expression = run.trim();
    if (expression.isEmpty) return false;
    if (_mathDelimiters.any(expression.contains)) return false;
    if (!_isPrimaryStart(expression.codeUnitAt(0))) return false;
    if (!_hasMathEvidence(expression)) return false;
    if (!_hasValueAtom(expression)) return false;
    if (!_isGroupBalanced(expression)) return false;
    return const LatexRenderabilityChecker()
        .check(expression, assumeMathContext: true)
        .isRenderable;
  }

  /// A run made only of control sequences and separators is a truncated
  /// command (`\frac` cut off from its operands), never an expression.
  static bool _hasValueAtom(String expression) {
    var index = 0;
    while (index < expression.length) {
      final codeUnit = expression.codeUnitAt(index);
      if (_isSeparator(codeUnit)) {
        index++;
        continue;
      }
      if (codeUnit != 92 /* \ */) return true;
      index++;
      if (index < expression.length &&
          _isAsciiLetter(expression.codeUnitAt(index))) {
        while (index < expression.length &&
            _isAsciiLetter(expression.codeUnitAt(index))) {
          index++;
        }
      } else if (index < expression.length) {
        index++;
      }
    }
    return false;
  }

  /// A math run must contain a LaTeX control sequence or a structural operator.
  static bool _hasMathEvidence(String expression) {
    for (var index = 0; index < expression.length; index++) {
      final codeUnit = expression.codeUnitAt(index);
      if (codeUnit == 92 /* \ */ ||
          codeUnit == 94 /* ^ */ ||
          codeUnit == 95 /* _ */ ||
          codeUnit == 61 /* = */) {
        return true;
      }
    }
    return false;
  }

  static bool _isGroupBalanced(String expression) {
    var depth = 0;
    for (var index = 0; index < expression.length; index++) {
      final codeUnit = expression.codeUnitAt(index);
      if (codeUnit == 92 /* \ */) {
        index++;
        continue;
      }
      if (codeUnit == 123 /* { */) {
        depth++;
      } else if (codeUnit == 125 /* } */) {
        depth--;
        if (depth < 0) return false;
      }
    }
    return depth == 0;
  }

  static _OcrBareAtom _readAtom(String text, int start) {
    final codeUnit = text.codeUnitAt(start);
    if (_isSeparator(codeUnit)) {
      var end = start + 1;
      while (end < text.length && _isSeparator(text.codeUnitAt(end))) {
        end++;
      }
      return _OcrBareAtom(end: end, kind: _OcrBareAtomKind.separator);
    }

    if (codeUnit == 92 /* \ */) {
      var end = start + 1;
      if (end < text.length && _isAsciiLetter(text.codeUnitAt(end))) {
        while (end < text.length && _isAsciiLetter(text.codeUnitAt(end))) {
          end++;
        }
      } else if (end < text.length) {
        end++;
      }
      return _OcrBareAtom(end: end, kind: _OcrBareAtomKind.math);
    }

    if (_isAsciiLetter(codeUnit)) {
      var end = start + 1;
      while (end < text.length && _isAsciiLetter(text.codeUnitAt(end))) {
        end++;
      }
      // A single latin letter is an OCR variable; a longer latin run is a word.
      return _OcrBareAtom(
        end: end,
        kind: end - start == 1 ? _OcrBareAtomKind.math : _OcrBareAtomKind.prose,
      );
    }

    if (_isAsciiDigit(codeUnit)) {
      var end = start + 1;
      while (end < text.length && _isAsciiDigit(text.codeUnitAt(end))) {
        end++;
      }
      return _OcrBareAtom(end: end, kind: _OcrBareAtomKind.math);
    }

    if (_isProseSymbol(codeUnit)) {
      return _OcrBareAtom(end: start + 1, kind: _OcrBareAtomKind.prose);
    }
    if (_isMathAtom(codeUnit)) {
      return _OcrBareAtom(end: start + 1, kind: _OcrBareAtomKind.math);
    }
    return _OcrBareAtom(end: start + 1, kind: _OcrBareAtomKind.prose);
  }

  static bool _isPrimaryStart(int codeUnit) {
    if (_isAsciiLetter(codeUnit) || _isAsciiDigit(codeUnit)) return true;
    return codeUnit == 92 /* \ */ ||
        codeUnit == 40 /* ( */ ||
        codeUnit == 91 /* [ */ ||
        codeUnit == 123 /* { */ ||
        codeUnit == 124 /* | */ ||
        _isMathSymbol(codeUnit);
  }

  static bool _isSeparator(int codeUnit) =>
      codeUnit == 32 ||
      codeUnit == 9 ||
      codeUnit == 10 ||
      codeUnit == 13 ||
      codeUnit == 12 ||
      codeUnit == 0x3000;

  static bool _isAsciiLetter(int codeUnit) =>
      (codeUnit >= 65 && codeUnit <= 90) || (codeUnit >= 97 && codeUnit <= 122);

  static bool _isAsciiDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

  /// Scripts that carry natural language in OCR output. Their punctuation and
  /// full-width forms are prose as well, so a `（0，1）` interval never becomes
  /// a math run on its own.
  static bool _isProseSymbol(int codeUnit) =>
      (codeUnit >= 0x3000 && codeUnit <= 0x30ff) ||
      (codeUnit >= 0x3400 && codeUnit <= 0x4dbf) ||
      (codeUnit >= 0x4e00 && codeUnit <= 0x9fff) ||
      (codeUnit >= 0xf900 && codeUnit <= 0xfaff) ||
      (codeUnit >= 0xff00 && codeUnit <= 0xffef);

  static bool _isMathSymbol(int codeUnit) =>
      (codeUnit >= 0x0370 && codeUnit <= 0x03ff) ||
      (codeUnit >= 0x2200 && codeUnit <= 0x22ff) ||
      (codeUnit >= 0x2a00 && codeUnit <= 0x2aff) ||
      codeUnit == 0x00b1 ||
      codeUnit == 0x00d7 ||
      codeUnit == 0x00f7;

  /// ASCII and symbol atoms that may appear inside a bare expression.
  static bool _isMathAtom(int codeUnit) {
    if (_isAsciiDigit(codeUnit)) return true;
    if (_isMathSymbol(codeUnit)) return true;
    const atoms = <int>[
      43, // +
      45, // -
      42, // *
      47, // /
      40, // (
      41, // )
      91, // [
      93, // ]
      123, // {
      125, // }
      124, // |
      60, // <
      62, // >
      46, // .
      44, // ,
      59, // ;
      58, // :
      33, // !
      63, // ?
      39, // '
      34, // "
      126, // ~
      38, // &
      37, // %
      64, // @
      61, // =
      94, // ^
      95, // _
    ];
    return atoms.contains(codeUnit);
  }
}

enum _OcrBareAtomKind { math, prose, separator }

final class _OcrBareAtom {
  const _OcrBareAtom({required this.end, required this.kind});

  final int end;
  final _OcrBareAtomKind kind;

  bool get isMath => kind == _OcrBareAtomKind.math;
  bool get isSeparator => kind == _OcrBareAtomKind.separator;
}
