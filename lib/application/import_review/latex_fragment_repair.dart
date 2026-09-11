import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../utils/content_tokenizer.dart';
import 'typed_review_snapshot.dart';

enum LatexFragmentField { stem, options, contentAnswer, explanation }

extension LatexFragmentFieldWireName on LatexFragmentField {
  String get wireName => switch (this) {
        LatexFragmentField.stem => 'stem',
        LatexFragmentField.options => 'options',
        LatexFragmentField.contentAnswer => 'content_answer',
        LatexFragmentField.explanation => 'explanation',
      };
}

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

enum LatexFragmentLocateClassification {
  targetAvailable('target_available'),
  invalidRequest('invalid_request'),
  reviewItemMismatch('review_item_mismatch'),
  baselineDrift('baseline_drift'),
  fieldUnavailable('field_unavailable'),
  optionCountMismatch('option_count_mismatch'),
  optionIdentityMismatch('option_identity_mismatch'),
  unsupportedNodeKind('unsupported_node_kind'),
  typedLegacyNodeCountMismatch('typed_legacy_node_count_mismatch'),
  typedLegacyNodeKindMismatch('typed_legacy_node_kind_mismatch'),
  targetLegacyRenderabilityMismatch(
    'target_legacy_renderability_mismatch',
  ),
  candidateZero('candidate_zero'),
  candidateMultiple('candidate_multiple');

  const LatexFragmentLocateClassification(this.wireName);

  final String wireName;
}

final class LatexFragmentNodeShape {
  const LatexFragmentNodeShape({
    required this.field,
    required this.optionIndex,
    required this.nodeIndex,
    required this.nodeKind,
    required this.renderable,
  });

  final LatexFragmentField field;
  final int? optionIndex;
  final int nodeIndex;
  final LatexFragmentNodeKind nodeKind;
  final bool renderable;

  Map<String, Object?> get diagnosticData => <String, Object?>{
        'field': field.wireName,
        if (optionIndex != null) 'optionIndex': optionIndex,
        'nodeIndex': nodeIndex,
        'nodeKind': nodeKind.wireName,
        'renderable': renderable,
      };
}

final class LatexFragmentLocateDiagnostic {
  LatexFragmentLocateDiagnostic({
    required this.classification,
    required this.requestedFieldCount,
    this.field,
    this.typedNodeCount = 0,
    this.legacySpanCount = 0,
    this.mathNodeCount = 0,
    this.unrenderableMathNodeCount = 0,
    this.unsupportedNodeCount = 0,
    this.candidateCount = 0,
    List<LatexFragmentNodeShape> nodeShapes = const <LatexFragmentNodeShape>[],
    this.nodeShapesTruncated = false,
    this.uniqueUnrenderableField,
    this.uniqueUnrenderableOptionIndex,
    this.uniqueUnrenderableNodeIndex,
    this.uniqueUnrenderableNodeKind,
    this.mismatchField,
    this.mismatchOptionIndex,
    this.mismatchNodeIndex,
    this.mismatchTypedKind,
    this.mismatchLegacyKind,
    this.mismatchTypedCharacterLength,
    this.mismatchLegacyCharacterLength,
    this.mismatchAtUnrenderableMathNode,
  }) : nodeShapes = List<LatexFragmentNodeShape>.unmodifiable(nodeShapes);

  final LatexFragmentLocateClassification classification;
  final int requestedFieldCount;
  final LatexFragmentField? field;
  final int typedNodeCount;
  final int legacySpanCount;
  final int mathNodeCount;
  final int unrenderableMathNodeCount;
  final int unsupportedNodeCount;
  final int candidateCount;
  final List<LatexFragmentNodeShape> nodeShapes;
  final bool nodeShapesTruncated;
  final LatexFragmentField? uniqueUnrenderableField;
  final int? uniqueUnrenderableOptionIndex;
  final int? uniqueUnrenderableNodeIndex;
  final LatexFragmentNodeKind? uniqueUnrenderableNodeKind;
  final LatexFragmentField? mismatchField;
  final int? mismatchOptionIndex;
  final int? mismatchNodeIndex;
  final String? mismatchTypedKind;
  final String? mismatchLegacyKind;
  final int? mismatchTypedCharacterLength;
  final int? mismatchLegacyCharacterLength;
  final bool? mismatchAtUnrenderableMathNode;

  Map<String, Object?> get diagnosticData => <String, Object?>{
        'failureClassification': classification.wireName,
        'requestedFieldCount': requestedFieldCount,
        if (field != null) 'field': field!.wireName,
        'typedNodeCount': typedNodeCount,
        'legacySpanCount': legacySpanCount,
        'mathNodeCount': mathNodeCount,
        'unrenderableMathNodeCount': unrenderableMathNodeCount,
        'unsupportedNodeCount': unsupportedNodeCount,
        'candidateCount': candidateCount,
        'nodeShapes': <Object?>[
          for (final shape in nodeShapes) shape.diagnosticData,
        ],
        'nodeShapesTruncated': nodeShapesTruncated,
        if (uniqueUnrenderableField != null)
          'uniqueUnrenderableField': uniqueUnrenderableField!.wireName,
        if (uniqueUnrenderableOptionIndex != null)
          'uniqueUnrenderableOptionIndex': uniqueUnrenderableOptionIndex,
        if (uniqueUnrenderableNodeIndex != null)
          'uniqueUnrenderableNodeIndex': uniqueUnrenderableNodeIndex,
        if (uniqueUnrenderableNodeKind != null)
          'uniqueUnrenderableNodeKind': uniqueUnrenderableNodeKind!.wireName,
        if (mismatchField != null) 'mismatchField': mismatchField!.wireName,
        if (mismatchOptionIndex != null)
          'mismatchOptionIndex': mismatchOptionIndex,
        if (mismatchNodeIndex != null) 'mismatchNodeIndex': mismatchNodeIndex,
        if (mismatchTypedKind != null) 'mismatchTypedKind': mismatchTypedKind,
        if (mismatchLegacyKind != null)
          'mismatchLegacyKind': mismatchLegacyKind,
        if (mismatchTypedCharacterLength != null)
          'mismatchTypedCharacterLength': mismatchTypedCharacterLength,
        if (mismatchLegacyCharacterLength != null)
          'mismatchLegacyCharacterLength': mismatchLegacyCharacterLength,
        if (mismatchAtUnrenderableMathNode != null)
          'mismatchAtUnrenderableMathNode': mismatchAtUnrenderableMathNode,
      };

  @override
  String toString() =>
      'LatexFragmentLocateDiagnostic(${classification.wireName}, [REDACTED])';
}

final class LatexFragmentLocateResult {
  const LatexFragmentLocateResult(
      {required this.target, required this.diagnostic});

  final LatexFragmentTarget? target;
  final LatexFragmentLocateDiagnostic diagnostic;
}

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
  }) =>
      inspect(
        reviewItemId: reviewItemId,
        expectedRevision: expectedRevision,
        snapshot: snapshot,
        current: current,
        fields: fields,
        isRenderable: isRenderable,
        digest: digest,
      ).target;

  LatexFragmentLocateResult inspect({
    required String reviewItemId,
    required int? expectedRevision,
    required TypedReviewSnapshot snapshot,
    required LatexFragmentLegacyView current,
    required Set<LatexFragmentField> fields,
    required LatexRenderablePredicate isRenderable,
    required LatexDigest digest,
  }) {
    final metrics = _LocateMetrics(requestedFieldCount: fields.length);
    if (fields.isEmpty) {
      return metrics.failure(LatexFragmentLocateClassification.invalidRequest);
    }
    if (snapshot.reviewItemId != reviewItemId) {
      return metrics.failure(
        LatexFragmentLocateClassification.reviewItemMismatch,
      );
    }
    final baseline = snapshot.baselineLegacy;
    if (current.content != baseline.content ||
        !_sameStrings(current.options, baseline.options) ||
        current.standardAnswer != baseline.standardAnswer ||
        current.explanation != baseline.explanation) {
      return metrics.failure(LatexFragmentLocateClassification.baselineDrift);
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
        metrics: metrics,
      );
      if (aligned.failure != null) return aligned.failure!;
      candidates.addAll(aligned.candidates);
    }
    if (fields.contains(LatexFragmentField.explanation)) {
      final explanation = snapshot.draft.explanation;
      if (explanation == null) {
        return metrics.failure(
          LatexFragmentLocateClassification.fieldUnavailable,
          field: LatexFragmentField.explanation,
        );
      }
      final aligned = _align(
        field: LatexFragmentField.explanation,
        optionId: null,
        content: explanation,
        legacy: baseline.explanation,
        fieldDigest: digest(baseline.explanation),
        isRenderable: isRenderable,
        metrics: metrics,
      );
      if (aligned.failure != null) return aligned.failure!;
      candidates.addAll(aligned.candidates);
    }
    if (fields.contains(LatexFragmentField.contentAnswer)) {
      final answer = snapshot.draft.answer;
      if (answer is! ContentAnswer) {
        return metrics.failure(
          LatexFragmentLocateClassification.fieldUnavailable,
          field: LatexFragmentField.contentAnswer,
        );
      }
      final aligned = _align(
        field: LatexFragmentField.contentAnswer,
        optionId: null,
        content: answer.content,
        legacy: baseline.standardAnswer,
        fieldDigest: digest(baseline.standardAnswer),
        isRenderable: isRenderable,
        metrics: metrics,
      );
      if (aligned.failure != null) return aligned.failure!;
      candidates.addAll(aligned.candidates);
    }
    if (fields.contains(LatexFragmentField.options)) {
      if (snapshot.draft.options.length != baseline.options.length) {
        return metrics.failure(
          LatexFragmentLocateClassification.optionCountMismatch,
          field: LatexFragmentField.options,
        );
      }
      final fieldDigest = digest(baseline.options.join('\u0000'));
      for (var index = 0; index < baseline.options.length; index++) {
        final parsed = _parseLegacyOption(baseline.options[index]);
        final typed = snapshot.draft.options[index];
        if (parsed == null || parsed.label != typed.label) {
          return metrics.failure(
            LatexFragmentLocateClassification.optionIdentityMismatch,
            field: LatexFragmentField.options,
          );
        }
        final aligned = _align(
          field: LatexFragmentField.options,
          optionId: typed.optionId,
          content: typed.content,
          legacy: parsed.body,
          fieldDigest: fieldDigest,
          isRenderable: isRenderable,
          metrics: metrics,
          optionIndex: index,
        );
        if (aligned.failure != null) return aligned.failure!;
        candidates.addAll(aligned.candidates);
      }
    }

    metrics.candidateCount = candidates.length;
    if (candidates.isEmpty) {
      return metrics.failure(LatexFragmentLocateClassification.candidateZero);
    }
    if (candidates.length != 1) {
      return metrics.failure(
        LatexFragmentLocateClassification.candidateMultiple,
      );
    }
    final candidate = candidates.single;
    final target = LatexFragmentTarget(
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
    return LatexFragmentLocateResult(
      target: target,
      diagnostic: metrics.diagnostic(
        LatexFragmentLocateClassification.targetAvailable,
        field: target.field,
      ),
    );
  }

  _AlignmentResult _align({
    required LatexFragmentField field,
    required String? optionId,
    required RichContent content,
    required String legacy,
    required String fieldDigest,
    required LatexRenderablePredicate isRenderable,
    required _LocateMetrics metrics,
    int? optionIndex,
  }) {
    final spans = ContentTokenizer.tokenizeMathSpans(legacy);
    metrics.typedNodeCount += content.nodes.length;
    metrics.legacySpanCount += spans.length;
    for (var index = 0; index < content.nodes.length; index++) {
      final node = content.nodes[index];
      final kind = switch (node) {
        InlineMathNode() => LatexFragmentNodeKind.inlineMath,
        BlockMathNode() => LatexFragmentNodeKind.blockMath,
        _ => null,
      };
      if (kind != null) {
        final latex = switch (node) {
          InlineMathNode(:final latex) => latex,
          BlockMathNode(:final latex) => latex,
          _ => throw StateError('Unreachable math node.'),
        };
        final renderable = isRenderable(latex);
        metrics.mathNodeCount++;
        if (!renderable) {
          metrics.recordUnrenderable(
            field: field,
            optionIndex: optionIndex,
            nodeIndex: index,
            nodeKind: kind,
          );
        }
        metrics.addNodeShape(
          LatexFragmentNodeShape(
            field: field,
            optionIndex: optionIndex,
            nodeIndex: index,
            nodeKind: kind,
            renderable: renderable,
          ),
        );
      } else if (node is! TextNode) {
        metrics.unsupportedNodeCount++;
      }
    }
    if (metrics.unsupportedNodeCount > 0) {
      return _AlignmentResult.failure(
        metrics.failure(
          LatexFragmentLocateClassification.unsupportedNodeKind,
          field: field,
        ),
      );
    }
    if (spans.length != content.nodes.length) {
      return _AlignmentResult.failure(
        metrics.failure(
          LatexFragmentLocateClassification.typedLegacyNodeCountMismatch,
          field: field,
        ),
      );
    }
    final failures = <_Candidate>[];
    for (var index = 0; index < content.nodes.length; index++) {
      final node = content.nodes[index];
      final span = spans[index];
      switch ((node, span.token)) {
        case (TextNode(:final text), TextToken(text: final tokenText)):
          if (text != tokenText) {
            metrics.recordMismatch(
              field: field,
              optionIndex: optionIndex,
              nodeIndex: index,
              typedKind: 'text',
              legacyKind: 'text',
              typedCharacterLength: text.runes.length,
              legacyCharacterLength: tokenText.runes.length,
            );
          }
        case (
            InlineMathNode(:final latex),
            InlineMathToken(:final tex, :final raw)
          ):
          if (latex != tex) {
            metrics.recordMismatch(
              field: field,
              optionIndex: optionIndex,
              nodeIndex: index,
              typedKind: LatexFragmentNodeKind.inlineMath.wireName,
              legacyKind: LatexFragmentNodeKind.inlineMath.wireName,
              typedCharacterLength: latex.runes.length,
              legacyCharacterLength: tex.runes.length,
            );
          }
          if (!isRenderable(latex)) {
            if (isRenderable(tex)) {
              return _AlignmentResult.failure(
                metrics.failure(
                  LatexFragmentLocateClassification
                      .targetLegacyRenderabilityMismatch,
                  field: field,
                ),
              );
            }
            failures.add(_candidate(
              field: field,
              optionId: optionId,
              content: content,
              nodeIndex: index,
              nodeKind: LatexFragmentNodeKind.inlineMath,
              fieldDigest: fieldDigest,
              latex: tex,
              raw: raw,
              spanStart: span.start,
            ));
          }
        case (
            BlockMathNode(:final latex),
            BlockMathToken(:final tex, :final raw)
          ):
          if (latex != tex) {
            metrics.recordMismatch(
              field: field,
              optionIndex: optionIndex,
              nodeIndex: index,
              typedKind: LatexFragmentNodeKind.blockMath.wireName,
              legacyKind: LatexFragmentNodeKind.blockMath.wireName,
              typedCharacterLength: latex.runes.length,
              legacyCharacterLength: tex.runes.length,
            );
          }
          if (!isRenderable(latex)) {
            if (isRenderable(tex)) {
              return _AlignmentResult.failure(
                metrics.failure(
                  LatexFragmentLocateClassification
                      .targetLegacyRenderabilityMismatch,
                  field: field,
                ),
              );
            }
            failures.add(_candidate(
              field: field,
              optionId: optionId,
              content: content,
              nodeIndex: index,
              nodeKind: LatexFragmentNodeKind.blockMath,
              fieldDigest: fieldDigest,
              latex: tex,
              raw: raw,
              spanStart: span.start,
            ));
          }
        default:
          metrics.recordMismatch(
            field: field,
            optionIndex: optionIndex,
            nodeIndex: index,
            typedKind: _contentNodeKind(node),
            legacyKind: _contentTokenKind(span.token),
            typedCharacterLength: _contentNodeCharacterLength(node),
            legacyCharacterLength: _contentTokenCharacterLength(span.token),
          );
          return _AlignmentResult.failure(
            metrics.failure(
              LatexFragmentLocateClassification.typedLegacyNodeKindMismatch,
              field: field,
            ),
          );
      }
    }
    return _AlignmentResult.success(failures);
  }

  /// Verifies that a proposed fragment still tokenizes as the same typed node
  /// topology. This is the proposal-time twin of the final typed commit gate.
  bool replacementPreservesTopology({
    required String baselineLegacy,
    required String patchedLegacy,
    required LatexFragmentTarget target,
    required String replacement,
  }) {
    final baselineSpans = ContentTokenizer.tokenizeMathSpans(baselineLegacy);
    final patchedSpans = ContentTokenizer.tokenizeMathSpans(patchedLegacy);
    if (target.nodeIndex >= baselineSpans.length ||
        patchedSpans.length != baselineSpans.length) {
      return false;
    }
    for (var index = 0; index < baselineSpans.length; index++) {
      final baselineToken = baselineSpans[index].token;
      final patchedToken = patchedSpans[index].token;
      if (index == target.nodeIndex) {
        final targetMatches =
            switch ((target.nodeKind, baselineToken, patchedToken)) {
          (
            LatexFragmentNodeKind.inlineMath,
            InlineMathToken(tex: final original),
            InlineMathToken(tex: final patched),
          ) =>
            original == target.originalLatex && patched == replacement,
          (
            LatexFragmentNodeKind.blockMath,
            BlockMathToken(tex: final original),
            BlockMathToken(tex: final patched),
          ) =>
            original == target.originalLatex && patched == replacement,
          _ => false,
        };
        if (!targetMatches) return false;
        continue;
      }
      final unchanged = switch ((baselineToken, patchedToken)) {
        (TextToken(text: final before), TextToken(text: final after)) =>
          before == after,
        (
          InlineMathToken(tex: final before),
          InlineMathToken(tex: final after)
        ) =>
          before == after,
        (BlockMathToken(tex: final before), BlockMathToken(tex: final after)) =>
          before == after,
        _ => false,
      };
      if (!unchanged) return false;
    }
    return true;
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

final class _AlignmentResult {
  const _AlignmentResult.success(this.candidates) : failure = null;

  const _AlignmentResult.failure(this.failure)
      : candidates = const <_Candidate>[];

  final List<_Candidate> candidates;
  final LatexFragmentLocateResult? failure;
}

final class _LocateMetrics {
  _LocateMetrics({required this.requestedFieldCount});

  static const int maximumNodeShapes = 32;

  final int requestedFieldCount;
  int typedNodeCount = 0;
  int legacySpanCount = 0;
  int mathNodeCount = 0;
  int unrenderableMathNodeCount = 0;
  int unsupportedNodeCount = 0;
  int candidateCount = 0;
  bool nodeShapesTruncated = false;
  final List<LatexFragmentNodeShape> nodeShapes = <LatexFragmentNodeShape>[];
  _NodeIdentity? _firstUnrenderable;
  LatexFragmentField? mismatchField;
  int? mismatchOptionIndex;
  int? mismatchNodeIndex;
  String? mismatchTypedKind;
  String? mismatchLegacyKind;
  int? mismatchTypedCharacterLength;
  int? mismatchLegacyCharacterLength;

  void addNodeShape(LatexFragmentNodeShape value) {
    if (nodeShapes.length >= maximumNodeShapes) {
      nodeShapesTruncated = true;
      return;
    }
    nodeShapes.add(value);
  }

  void recordUnrenderable({
    required LatexFragmentField field,
    required int? optionIndex,
    required int nodeIndex,
    required LatexFragmentNodeKind nodeKind,
  }) {
    unrenderableMathNodeCount++;
    _firstUnrenderable ??= _NodeIdentity(
      field: field,
      optionIndex: optionIndex,
      nodeIndex: nodeIndex,
      nodeKind: nodeKind,
    );
  }

  void recordMismatch({
    required LatexFragmentField field,
    required int? optionIndex,
    required int nodeIndex,
    required String typedKind,
    required String legacyKind,
    required int typedCharacterLength,
    required int legacyCharacterLength,
  }) {
    mismatchField ??= field;
    mismatchOptionIndex ??= optionIndex;
    mismatchNodeIndex ??= nodeIndex;
    mismatchTypedKind ??= typedKind;
    mismatchLegacyKind ??= legacyKind;
    mismatchTypedCharacterLength ??= typedCharacterLength;
    mismatchLegacyCharacterLength ??= legacyCharacterLength;
  }

  LatexFragmentLocateDiagnostic diagnostic(
    LatexFragmentLocateClassification classification, {
    LatexFragmentField? field,
  }) {
    final uniqueUnrenderable =
        unrenderableMathNodeCount == 1 ? _firstUnrenderable : null;
    final mismatchAtUnrenderable = mismatchNodeIndex == null
        ? null
        : uniqueUnrenderable != null &&
            mismatchField == uniqueUnrenderable.field &&
            mismatchOptionIndex == uniqueUnrenderable.optionIndex &&
            mismatchNodeIndex == uniqueUnrenderable.nodeIndex;
    return LatexFragmentLocateDiagnostic(
      classification: classification,
      requestedFieldCount: requestedFieldCount,
      field: field,
      typedNodeCount: typedNodeCount,
      legacySpanCount: legacySpanCount,
      mathNodeCount: mathNodeCount,
      unrenderableMathNodeCount: unrenderableMathNodeCount,
      unsupportedNodeCount: unsupportedNodeCount,
      candidateCount: candidateCount,
      nodeShapes: nodeShapes,
      nodeShapesTruncated: nodeShapesTruncated,
      uniqueUnrenderableField: uniqueUnrenderable?.field,
      uniqueUnrenderableOptionIndex: uniqueUnrenderable?.optionIndex,
      uniqueUnrenderableNodeIndex: uniqueUnrenderable?.nodeIndex,
      uniqueUnrenderableNodeKind: uniqueUnrenderable?.nodeKind,
      mismatchField: mismatchField,
      mismatchOptionIndex: mismatchOptionIndex,
      mismatchNodeIndex: mismatchNodeIndex,
      mismatchTypedKind: mismatchTypedKind,
      mismatchLegacyKind: mismatchLegacyKind,
      mismatchTypedCharacterLength: mismatchTypedCharacterLength,
      mismatchLegacyCharacterLength: mismatchLegacyCharacterLength,
      mismatchAtUnrenderableMathNode: mismatchAtUnrenderable,
    );
  }

  LatexFragmentLocateResult failure(
    LatexFragmentLocateClassification classification, {
    LatexFragmentField? field,
  }) {
    return LatexFragmentLocateResult(
      target: null,
      diagnostic: diagnostic(classification, field: field),
    );
  }
}

final class _NodeIdentity {
  const _NodeIdentity({
    required this.field,
    required this.optionIndex,
    required this.nodeIndex,
    required this.nodeKind,
  });

  final LatexFragmentField field;
  final int? optionIndex;
  final int nodeIndex;
  final LatexFragmentNodeKind nodeKind;
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

String _contentNodeKind(ContentNode node) => switch (node) {
      TextNode() => 'text',
      InlineMathNode() => LatexFragmentNodeKind.inlineMath.wireName,
      BlockMathNode() => LatexFragmentNodeKind.blockMath.wireName,
      _ => 'unsupported',
    };

String _contentTokenKind(ContentToken token) => switch (token) {
      TextToken() => 'text',
      InlineMathToken() => LatexFragmentNodeKind.inlineMath.wireName,
      BlockMathToken() => LatexFragmentNodeKind.blockMath.wireName,
      _ => 'unsupported',
    };

int _contentNodeCharacterLength(ContentNode node) => switch (node) {
      TextNode(:final text) => text.runes.length,
      InlineMathNode(:final latex) => latex.runes.length,
      BlockMathNode(:final latex) => latex.runes.length,
      _ => 0,
    };

int _contentTokenCharacterLength(ContentToken token) => switch (token) {
      TextToken(:final text) => text.runes.length,
      InlineMathToken(:final tex) => tex.runes.length,
      BlockMathToken(:final tex) => tex.runes.length,
      _ => 0,
    };
