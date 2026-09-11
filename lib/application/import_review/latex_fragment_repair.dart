import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../utils/content_tokenizer.dart';
import 'typed_review_snapshot.dart';

enum LatexFragmentField { stem, options, contentAnswer, explanation }

enum LatexFragmentNodeKind {
  inlineMath('inline_math'),
  blockMath('block_math');

  const LatexFragmentNodeKind(this.wireName);

  final String wireName;

  static LatexFragmentNodeKind? fromWireName(Object? value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

final class LatexFragmentLegacyView {
  LatexFragmentLegacyView({
    required this.content,
    required List<String> options,
    required this.standardAnswer,
    required this.explanation,
  }) : options = List<String>.unmodifiable(options);

  final String content;
  final List<String> options;
  final String standardAnswer;
  final String explanation;
}

final class LatexFragmentTarget {
  LatexFragmentTarget({
    required this.reviewItemId,
    required this.expectedRevision,
    required this.field,
    required this.optionId,
    required this.nodeIndex,
    required this.nodeKind,
    required this.originalFieldDigest,
    required this.originalLatexDigest,
    required this.legacyStart,
    required this.legacyEnd,
    required this.originalLatex,
    required this.precedingContext,
    required this.followingContext,
  }) {
    if (reviewItemId.isEmpty ||
        nodeIndex < 0 ||
        legacyStart < 0 ||
        legacyEnd < legacyStart ||
        originalLatex.isEmpty) {
      throw const FormatException('Invalid LaTeX fragment target.');
    }
    if ((field == LatexFragmentField.options) != (optionId != null)) {
      throw const FormatException('Invalid LaTeX option target.');
    }
  }

  final String reviewItemId;
  final int? expectedRevision;
  final LatexFragmentField field;
  final String? optionId;
  final int nodeIndex;
  final LatexFragmentNodeKind nodeKind;
  final String originalFieldDigest;
  final String originalLatexDigest;
  final int legacyStart;
  final int legacyEnd;
  final String originalLatex;
  final String precedingContext;
  final String followingContext;
}

typedef LatexRenderablePredicate = bool Function(String latex);
typedef LatexDigest = String Function(String value);

/// Pure, renderer-independent alignment of a frozen typed review snapshot with
/// its lossless legacy math spans.
final class LatexFragmentLocator {
  const LatexFragmentLocator();

  static const int maximumContextScalars = 256;

  LatexFragmentTarget? locate({
    required String reviewItemId,
    required int? expectedRevision,
    required TypedReviewSnapshot snapshot,
    required LatexFragmentLegacyView current,
    required Set<LatexFragmentField> fields,
    required LatexRenderablePredicate isRenderable,
    required LatexDigest digest,
  }) {
    if (snapshot.reviewItemId != reviewItemId || fields.isEmpty) return null;
    final baseline = snapshot.baselineLegacy;
    if (current.content != baseline.content ||
        !_sameStrings(current.options, baseline.options) ||
        current.standardAnswer != baseline.standardAnswer ||
        current.explanation != baseline.explanation) {
      return null;
    }

    final candidates = <_Candidate>[];
    if (fields.contains(LatexFragmentField.stem)) {
      final aligned = _align(
        field: LatexFragmentField.stem,
        optionId: null,
        content: snapshot.draft.stem,
        legacy: baseline.content,
        fieldDigest: digest(baseline.content),
        isRenderable: isRenderable,
      );
      if (aligned == null) return null;
      candidates.addAll(aligned);
    }
    if (fields.contains(LatexFragmentField.explanation)) {
      final explanation = snapshot.draft.explanation;
      if (explanation == null) return null;
      final aligned = _align(
        field: LatexFragmentField.explanation,
        optionId: null,
        content: explanation,
        legacy: baseline.explanation,
        fieldDigest: digest(baseline.explanation),
        isRenderable: isRenderable,
      );
      if (aligned == null) return null;
      candidates.addAll(aligned);
    }
    if (fields.contains(LatexFragmentField.contentAnswer)) {
      final answer = snapshot.draft.answer;
      if (answer is! ContentAnswer) return null;
      final aligned = _align(
        field: LatexFragmentField.contentAnswer,
        optionId: null,
        content: answer.content,
        legacy: baseline.standardAnswer,
        fieldDigest: digest(baseline.standardAnswer),
        isRenderable: isRenderable,
      );
      if (aligned == null) return null;
      candidates.addAll(aligned);
    }
    if (fields.contains(LatexFragmentField.options)) {
      if (snapshot.draft.options.length != baseline.options.length) return null;
      final fieldDigest = digest(baseline.options.join('\u0000'));
      for (var index = 0; index < baseline.options.length; index++) {
        final parsed = _parseLegacyOption(baseline.options[index]);
        final typed = snapshot.draft.options[index];
        if (parsed == null || parsed.label != typed.label) return null;
        final aligned = _align(
          field: LatexFragmentField.options,
          optionId: typed.optionId,
          content: typed.content,
          legacy: parsed.body,
          fieldDigest: fieldDigest,
          isRenderable: isRenderable,
        );
        if (aligned == null) return null;
        candidates.addAll(aligned);
      }
    }

    if (candidates.length != 1) return null;
    final candidate = candidates.single;
    return LatexFragmentTarget(
      reviewItemId: reviewItemId,
      expectedRevision: expectedRevision,
      field: candidate.field,
      optionId: candidate.optionId,
      nodeIndex: candidate.nodeIndex,
      nodeKind: candidate.nodeKind,
      originalFieldDigest: candidate.fieldDigest,
      originalLatexDigest: digest(candidate.latex),
      legacyStart: candidate.legacyStart,
      legacyEnd: candidate.legacyEnd,
      originalLatex: candidate.latex,
      precedingContext: candidate.precedingContext,
      followingContext: candidate.followingContext,
    );
  }

  List<_Candidate>? _align({
    required LatexFragmentField field,
    required String? optionId,
    required RichContent content,
    required String legacy,
    required String fieldDigest,
    required LatexRenderablePredicate isRenderable,
  }) {
    if (content.nodes.any(
      (node) =>
          node is! TextNode &&
          node is! InlineMathNode &&
          node is! BlockMathNode,
    )) {
      return null;
    }
    final spans = ContentTokenizer.tokenizeMathSpans(legacy);
    if (spans.length != content.nodes.length) return null;
    final failures = <_Candidate>[];
    for (var index = 0; index < content.nodes.length; index++) {
      final node = content.nodes[index];
      final span = spans[index];
      switch ((node, span.token)) {
        case (TextNode(:final text), TextToken(text: final tokenText)):
          if (text != tokenText) return null;
        case (
            InlineMathNode(:final latex),
            InlineMathToken(:final tex, :final raw)
          ):
          if (latex != tex) return null;
          if (!isRenderable(latex)) {
            failures.add(_candidate(
              field: field,
              optionId: optionId,
              content: content,
              nodeIndex: index,
              nodeKind: LatexFragmentNodeKind.inlineMath,
              fieldDigest: fieldDigest,
              latex: latex,
              raw: raw,
              spanStart: span.start,
            ));
          }
        case (
            BlockMathNode(:final latex),
            BlockMathToken(:final tex, :final raw)
          ):
          if (latex != tex) return null;
          if (!isRenderable(latex)) {
            failures.add(_candidate(
              field: field,
              optionId: optionId,
              content: content,
              nodeIndex: index,
              nodeKind: LatexFragmentNodeKind.blockMath,
              fieldDigest: fieldDigest,
              latex: latex,
              raw: raw,
              spanStart: span.start,
            ));
          }
        default:
          return null;
      }
    }
    return failures;
  }

  _Candidate _candidate({
    required LatexFragmentField field,
    required String? optionId,
    required RichContent content,
    required int nodeIndex,
    required LatexFragmentNodeKind nodeKind,
    required String fieldDigest,
    required String latex,
    required String raw,
    required int spanStart,
  }) {
    final delimiterLength =
        raw.startsWith(r'$$') || raw.startsWith(r'\(') || raw.startsWith(r'\[')
            ? 2
            : 1;
    final previous = nodeIndex > 0 ? content.nodes[nodeIndex - 1] : null;
    final next = nodeIndex + 1 < content.nodes.length
        ? content.nodes[nodeIndex + 1]
        : null;
    return _Candidate(
      field: field,
      optionId: optionId,
      nodeIndex: nodeIndex,
      nodeKind: nodeKind,
      fieldDigest: fieldDigest,
      latex: latex,
      legacyStart: spanStart + delimiterLength,
      legacyEnd: spanStart + delimiterLength + latex.length,
      precedingContext: previous is TextNode ? _suffix(previous.text) : '',
      followingContext: next is TextNode ? _prefix(next.text) : '',
    );
  }

  String _prefix(String value) {
    final runes = value.runes.toList(growable: false);
    return String.fromCharCodes(
      runes.take(maximumContextScalars),
    );
  }

  String _suffix(String value) {
    final runes = value.runes.toList(growable: false);
    final start = runes.length > maximumContextScalars
        ? runes.length - maximumContextScalars
        : 0;
    return String.fromCharCodes(runes.skip(start));
  }
}

final class _Candidate {
  const _Candidate({
    required this.field,
    required this.optionId,
    required this.nodeIndex,
    required this.nodeKind,
    required this.fieldDigest,
    required this.latex,
    required this.legacyStart,
    required this.legacyEnd,
    required this.precedingContext,
    required this.followingContext,
  });

  final LatexFragmentField field;
  final String? optionId;
  final int nodeIndex;
  final LatexFragmentNodeKind nodeKind;
  final String fieldDigest;
  final String latex;
  final int legacyStart;
  final int legacyEnd;
  final String precedingContext;
  final String followingContext;
}

final _legacyOptionPattern = RegExp(
  r'^([A-Za-z])\s*[.．、]\s*(.*)$',
  dotAll: true,
);

({String label, String body})? _parseLegacyOption(String value) {
  final match = _legacyOptionPattern.firstMatch(value);
  if (match == null) return null;
  return (label: match.group(1)!, body: match.group(2)!);
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
