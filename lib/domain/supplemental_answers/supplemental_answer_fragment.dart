import '../content/rich_content.dart';
import '../source/source_ref.dart';
import 'rich_content_equality.dart';

final _fragmentIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Transient provenance of one fragment's answer content.
///
/// The distinction exists only inside one matching session. An explicit answer
/// marker (or an explicit table answer) is a formal answer statement for every
/// supported target type, while a solution/`证明` block that never carried an
/// explicit answer is derived content and stays usable only where the target
/// accepts composed content.
enum SupplementalAnswerSource {
  /// The source stated this content as the answer itself.
  explicitAnswer,

  /// Only a solution (`解` / `证明`) block produced this content; the source
  /// carried no explicit answer statement.
  solutionBlock,
}

/// One projected answer fragment from the supplemental document.
///
/// Transient only: never persisted. The fragment keeps the ordered source
/// provenance and structural [RichContent] of the supplemental answer so a
/// later confirmation can reuse the existing typed mutation authority.
final class SupplementalAnswerFragment {
  factory SupplementalAnswerFragment({
    required String fragmentId,
    String? normalizedMainNumber,
    String? normalizedSubquestion,
    required RichContent answerContent,
    RichContent? explanationContent,
    Iterable<RichContent> headingContext = const <RichContent>[],
    required Iterable<SourceRef> sourceRefs,
    required SupplementalSequencePosition sequencePosition,
    RichContent? stemContext,
    SupplementalAnswerSource source = SupplementalAnswerSource.explicitAnswer,
    Iterable<SupplementalAnswerPartSegment> answerPartEvidence =
        const <SupplementalAnswerPartSegment>[],
  }) {
    if (!_fragmentIdPattern.hasMatch(fragmentId)) {
      throw const FormatException(
        'Supplemental fragment ids must use the bounded opaque token format.',
      );
    }
    if (answerContent.nodes.isEmpty) {
      throw const FormatException(
        'Supplemental answer fragments require non-empty answer content.',
      );
    }
    final copiedSourceRefs = List<SourceRef>.unmodifiable(sourceRefs);
    if (copiedSourceRefs.isEmpty) {
      throw const FormatException(
        'Supplemental answer fragments require ordered source refs.',
      );
    }
    final sourceIds = copiedSourceRefs.map((ref) => ref.sourceId).toSet();
    if (sourceIds.length != 1) {
      throw const FormatException(
        'Supplemental answer fragment refs must share one artifact source.',
      );
    }
    final copiedPartEvidence =
        List<SupplementalAnswerPartSegment>.unmodifiable(answerPartEvidence);
    var previousNodeEnd = 0;
    int? previousPartIndex;
    for (final segment in copiedPartEvidence) {
      if (!copiedSourceRefs.contains(segment.sourceRef)) {
        throw const FormatException(
          'Answer part evidence must stay bound to the fragment source refs.',
        );
      }
      final openPartIndex = previousPartIndex;
      if (openPartIndex != null && segment.partIndex <= openPartIndex) {
        throw const FormatException(
          'Answer part evidence must follow the source part order.',
        );
      }
      if (segment.answerNodeStart < previousNodeEnd) {
        throw const FormatException(
          'Answer part evidence must stay ordered and non-overlapping.',
        );
      }
      if (segment.answerNodeEnd > answerContent.nodes.length) {
        throw const FormatException(
          'Answer part evidence must stay inside the answer content.',
        );
      }
      final rangeContent = RichContent(
        nodes: answerContent.nodes.sublist(
          segment.answerNodeStart,
          segment.answerNodeEnd,
        ),
      );
      if (!richContentEquals(rangeContent, segment.content)) {
        throw const FormatException(
          'Answer part evidence content must match the answer content range.',
        );
      }
      previousNodeEnd = segment.answerNodeEnd;
      previousPartIndex = segment.partIndex;
    }
    return SupplementalAnswerFragment._(
      fragmentId: fragmentId,
      normalizedMainNumber: _boundedFeature(normalizedMainNumber),
      normalizedSubquestion: _boundedFeature(normalizedSubquestion),
      answerContent: answerContent,
      explanationContent: explanationContent,
      headingContext: List<RichContent>.unmodifiable(headingContext),
      sourceRefs: copiedSourceRefs,
      sequencePosition: sequencePosition,
      stemContext: stemContext,
      source: source,
      answerPartEvidence: copiedPartEvidence,
    );
  }

  const SupplementalAnswerFragment._({
    required this.fragmentId,
    required this.normalizedMainNumber,
    required this.normalizedSubquestion,
    required this.answerContent,
    required this.explanationContent,
    required this.headingContext,
    required this.sourceRefs,
    required this.sequencePosition,
    required this.stemContext,
    required this.source,
    required this.answerPartEvidence,
  });

  final String fragmentId;
  final String? normalizedMainNumber;
  final String? normalizedSubquestion;
  final RichContent answerContent;
  final RichContent? explanationContent;
  final List<RichContent> headingContext;
  final List<SourceRef> sourceRefs;
  final SupplementalSequencePosition sequencePosition;
  final RichContent? stemContext;
  final SupplementalAnswerSource source;

  /// Ordered transient part-boundary evidence of [answerContent].
  ///
  /// Every entry records one real content part's contribution; an empty list
  /// means the answer content carries no provable part boundary. The evidence
  /// is a source fact only: it never identifies an answer boundary by itself,
  /// and it is never persisted.
  final List<SupplementalAnswerPartSegment> answerPartEvidence;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalAnswerFragment &&
            fragmentId == other.fragmentId &&
            normalizedMainNumber == other.normalizedMainNumber &&
            normalizedSubquestion == other.normalizedSubquestion &&
            richContentEquals(answerContent, other.answerContent) &&
            _nullableRichContentEquals(
              explanationContent,
              other.explanationContent,
            ) &&
            _richContentListEquals(headingContext, other.headingContext) &&
            _orderedEquals(sourceRefs, other.sourceRefs) &&
            sequencePosition == other.sequencePosition &&
            _nullableRichContentEquals(stemContext, other.stemContext) &&
            source == other.source &&
            _orderedEquals(answerPartEvidence, other.answerPartEvidence);
  }

  @override
  int get hashCode => Object.hash(
        fragmentId,
        normalizedMainNumber,
        normalizedSubquestion,
        richContentHash(answerContent),
        explanationContent == null
            ? null
            : richContentHash(explanationContent!),
        Object.hashAll(headingContext.map(richContentHash)),
        Object.hashAll(sourceRefs),
        sequencePosition,
        stemContext == null ? null : richContentHash(stemContext!),
        source,
        Object.hashAll(answerPartEvidence),
      );
}

/// One contiguous answer segment contributed by exactly one source part.
///
/// Transient source fact only: the segment binds a real source part to the
/// exact [RichContent] it contributed and to that contribution's node range
/// inside [SupplementalAnswerFragment.answerContent]. It lets a later consumer
/// prove that a chosen answer offset really sits on a source-part boundary. It
/// never identifies an answer boundary by itself, never carries target
/// knowledge, and is never persisted.
///
/// A fragment accepts a segment only after proving that the segment content
/// really is the answer content of its own range, that its [sourceRef] is one
/// of the fragment refs, and that part indexes strictly increase, so an
/// accepted segment is verified evidence rather than a claim.
final class SupplementalAnswerPartSegment {
  SupplementalAnswerPartSegment({
    required this.partIndex,
    required this.answerNodeStart,
    required this.answerNodeEnd,
    required this.content,
    required this.sourceRef,
  }) {
    if (partIndex < 0) {
      throw const FormatException(
        'Answer part segments require a non-negative source part index.',
      );
    }
    if (answerNodeStart < 0 || answerNodeEnd <= answerNodeStart) {
      throw const FormatException(
        'Answer part segments require one non-empty answer node range.',
      );
    }
    if (content.nodes.length != answerNodeEnd - answerNodeStart) {
      throw const FormatException(
        'Answer part segment content must match its answer node range.',
      );
    }
  }

  /// Index of the source part that really produced this segment.
  final int partIndex;

  /// Inclusive start of the segment inside the answer node list.
  final int answerNodeStart;

  /// Exclusive end of the segment inside the answer node list.
  final int answerNodeEnd;

  /// Exactly the content that part contributed, in answer node order.
  final RichContent content;

  /// Source ref of that same part.
  final SourceRef sourceRef;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalAnswerPartSegment &&
            partIndex == other.partIndex &&
            answerNodeStart == other.answerNodeStart &&
            answerNodeEnd == other.answerNodeEnd &&
            richContentEquals(content, other.content) &&
            sourceRef == other.sourceRef;
  }

  @override
  int get hashCode => Object.hash(
        partIndex,
        answerNodeStart,
        answerNodeEnd,
        richContentHash(content),
        sourceRef,
      );
}

/// Ordered position of one fragment inside the supplemental document:
/// part index plus optional table row/column and continuation ordinal.
final class SupplementalSequencePosition {
  const SupplementalSequencePosition({
    required this.partIndex,
    this.tableRow,
    this.tableColumn,
    required this.continuationOrdinal,
  });

  final int partIndex;
  final int? tableRow;
  final int? tableColumn;
  final int continuationOrdinal;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalSequencePosition &&
            partIndex == other.partIndex &&
            tableRow == other.tableRow &&
            tableColumn == other.tableColumn &&
            continuationOrdinal == other.continuationOrdinal;
  }

  @override
  int get hashCode =>
      Object.hash(partIndex, tableRow, tableColumn, continuationOrdinal);
}

String? _boundedFeature(String? value) {
  if (value == null) return null;
  if (value.isEmpty ||
      value.length > 64 ||
      value != value.trim() ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f-\u009f]'))) {
    throw const FormatException(
      'Supplemental number features must be bounded trimmed tokens.',
    );
  }
  return value;
}

bool _nullableRichContentEquals(RichContent? left, RichContent? right) {
  if (left == null || right == null) return left == right;
  return richContentEquals(left, right);
}

bool _richContentListEquals(List<RichContent> left, List<RichContent> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!richContentEquals(left[index], right[index])) return false;
  }
  return true;
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
