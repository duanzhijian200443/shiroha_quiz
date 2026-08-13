import '../content/rich_content.dart';
import '../source/source_ref.dart';
import 'rich_content_equality.dart';

final _fragmentIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

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
            _nullableRichContentEquals(stemContext, other.stemContext);
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
