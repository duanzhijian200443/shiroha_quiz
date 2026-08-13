import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_document.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';
import '../../domain/supplemental_answers/supplemental_answer_fragment.dart';

final _fullWidthDigits = <String, String>{
  '０': '0',
  '１': '1',
  '２': '2',
  '３': '3',
  '４': '4',
  '５': '5',
  '６': '6',
  '７': '7',
  '８': '8',
  '９': '9',
};

final _mainNumberPattern = RegExp(
  r'^\s*(?:第\s*)?(\d{1,4})\s*(?:题)?\s*[.．、:：]?\s*',
);
final _subNumberPattern = RegExp(r'^[（(]\s*(\d{1,4})\s*[)）]\s*');
final _explanationMarkerPattern = RegExp(
  r'^\s*(?:解析|详解|分析|说明)[:：]?\s*',
);
final _answerMarkerPattern = RegExp(r'^\s*(?:参考答案?|答案?)[:：]?\s*');

/// Safe typed projection issue; retains no raw source text or paths.
enum SupplementalProjectionIssueKind {
  unsupportedPartSkipped,
  imageWithoutAltTextSkipped,
  imageWithoutOpenFragmentSkipped,
  tableUnrecognized,
  continuationWithoutFragmentSkipped,
  emptyAnswerSkipped,
}

final class SupplementalProjectionIssue {
  const SupplementalProjectionIssue({
    required this.kind,
    required this.partIndex,
  });

  final SupplementalProjectionIssueKind kind;
  final int partIndex;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalProjectionIssue &&
            kind == other.kind &&
            partIndex == other.partIndex;
  }

  @override
  int get hashCode => Object.hash(kind, partIndex);
}

final class SupplementalProjectionResult {
  const SupplementalProjectionResult({
    required this.fragments,
    required this.issues,
  });

  final List<SupplementalAnswerFragment> fragments;
  final List<SupplementalProjectionIssue> issues;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalProjectionResult &&
            _orderedEquals(fragments, other.fragments) &&
            _orderedEquals(issues, other.issues);
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(fragments), Object.hashAll(issues));
}

/// Deterministic projection of one current F1 [SourceDocument] into
/// transient [SupplementalAnswerFragment] values.
///
/// Consumes only the F1 Application `SourceDocument`; it never reads
/// sidecars, SQLite rows, or managed paths and never triggers ensure,
/// reparse, or OCR. Paragraph/heading/formula/table/continuation parts are
/// projectable; tables support the explicit "question-number row + answer
/// row" layout; image parts participate only when typed alternative text
/// already exists; unsupported/image-only/raw-unsafe parts never produce a
/// writable answer. Multi-part answers combine [RichContent] nodes
/// structurally (never flatten -> string -> reparse).
final class SupplementalAnswerProjector {
  const SupplementalAnswerProjector();

  SupplementalProjectionResult project(SourceDocument document) {
    final fragments = <SupplementalAnswerFragment>[];
    final issues = <SupplementalProjectionIssue>[];
    final builder = _FragmentBuilder();

    for (var partIndex = 0; partIndex < document.parts.length; partIndex++) {
      final part = document.parts[partIndex];
      switch (part) {
        case SourceContentPart(
            :final sourceRef,
            :final content,
            :final role,
          ):
          if (role == SourceContentRole.heading) {
            builder.pushHeading(content);
            continue;
          }
          _projectContentPart(
            partIndex: partIndex,
            sourceRef: sourceRef,
            content: content,
            builder: builder,
            fragments: fragments,
            issues: issues,
          );
        case SourceTablePart(:final sourceRef, :final rows):
          _projectTablePart(
            partIndex: partIndex,
            sourceRef: sourceRef,
            rows: rows,
            builder: builder,
            fragments: fragments,
            issues: issues,
          );
        case SourceAssetPart(
            :final sourceRef,
            :final alternativeText,
          ):
          final altText = alternativeText;
          if (altText == null) {
            issues.add(
              SupplementalProjectionIssue(
                kind:
                    SupplementalProjectionIssueKind.imageWithoutAltTextSkipped,
                partIndex: partIndex,
              ),
            );
            continue;
          }
          if (!builder.hasOpenFragment) {
            issues.add(
              SupplementalProjectionIssue(
                kind: SupplementalProjectionIssueKind
                    .imageWithoutOpenFragmentSkipped,
                partIndex: partIndex,
              ),
            );
            continue;
          }
          builder.appendAnswer(altText, sourceRef);
        case UnsupportedSourcePart():
          issues.add(
            SupplementalProjectionIssue(
              kind: SupplementalProjectionIssueKind.unsupportedPartSkipped,
              partIndex: partIndex,
            ),
          );
      }
    }

    final closed = builder.close();
    fragments.addAll(closed);
    issues.addAll(
      builder.emptySkippedPartIndexes.map(
        (partIndex) => SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind.emptyAnswerSkipped,
          partIndex: partIndex,
        ),
      ),
    );
    return SupplementalProjectionResult(
      fragments: List<SupplementalAnswerFragment>.unmodifiable(fragments),
      issues: List<SupplementalProjectionIssue>.unmodifiable(issues),
    );
  }

  void _projectContentPart({
    required int partIndex,
    required SourceRef sourceRef,
    required RichContent content,
    required _FragmentBuilder builder,
    required List<SupplementalAnswerFragment> fragments,
    required List<SupplementalProjectionIssue> issues,
  }) {
    final locator = _extractLocator(content, builder.hasOpenFragment);
    if (locator != null) {
      final closed = builder.start(
        partIndex: partIndex,
        sourceRef: sourceRef,
        normalizedMainNumber: locator.mainNumber,
        normalizedSubquestion: locator.subquestion,
        initialAnswer: locator.remainder,
        initialExplanation: null,
      );
      fragments.addAll(closed);
      return;
    }

    if (!builder.hasOpenFragment) {
      issues.add(
        SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind
              .continuationWithoutFragmentSkipped,
          partIndex: partIndex,
        ),
      );
      return;
    }

    final text = _plainText(content);
    if (text != null && _explanationMarkerPattern.hasMatch(text)) {
      builder.appendExplanation(content, sourceRef);
    } else {
      builder.appendAnswer(content, sourceRef);
    }
  }

  void _projectTablePart({
    required int partIndex,
    required SourceRef sourceRef,
    required List<List<RichContent>> rows,
    required _FragmentBuilder builder,
    required List<SupplementalAnswerFragment> fragments,
    required List<SupplementalProjectionIssue> issues,
  }) {
    int? numberRowIndex;
    int? answerRowIndex;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final cells = row.map(_plainText).toList(growable: false);
      final body = cells.skip(1).toList(growable: false);
      final isNumberRow = body.isNotEmpty &&
          body.every((cell) => cell != null && _parseNumber(cell) != null);
      if (isNumberRow) {
        if (numberRowIndex != null) {
          issues.add(
            SupplementalProjectionIssue(
              kind: SupplementalProjectionIssueKind.tableUnrecognized,
              partIndex: partIndex,
            ),
          );
          return;
        }
        numberRowIndex = index;
        continue;
      }
      final isAnswerRow = body.isNotEmpty &&
          body.every((cell) => cell != null && cell.trim().isNotEmpty);
      if (isAnswerRow &&
          numberRowIndex != null &&
          index > numberRowIndex &&
          answerRowIndex == null) {
        answerRowIndex = index;
      }
    }

    if (numberRowIndex == null ||
        answerRowIndex == null ||
        answerRowIndex <= numberRowIndex) {
      issues.add(
        SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind.tableUnrecognized,
          partIndex: partIndex,
        ),
      );
      return;
    }

    final numberRow = rows[numberRowIndex];
    final answerRow = rows[answerRowIndex];
    final columnCount = numberRow.length < answerRow.length
        ? numberRow.length
        : answerRow.length;
    for (var column = 0; column < columnCount; column++) {
      final numberText = _plainText(numberRow[column]);
      final number = numberText == null ? null : _parseNumber(numberText);
      if (number == null) continue;
      final answerContent = answerRow[column];
      if (answerContent.nodes.isEmpty) continue;
      final closed = builder.start(
        partIndex: partIndex,
        sourceRef: sourceRef,
        normalizedMainNumber: number,
        normalizedSubquestion: null,
        initialAnswer: answerContent,
        initialExplanation: null,
        tableRow: answerRowIndex,
        tableColumn: column,
      );
      fragments.addAll(closed);
    }
  }
}

/// One leading locator extracted from a supplemental answer part.
final class _Locator {
  const _Locator({
    required this.mainNumber,
    required this.subquestion,
    required this.remainder,
  });

  final String mainNumber;
  final String? subquestion;
  final RichContent? remainder;
}

_Locator? _extractLocator(
  RichContent content,
  bool hasOpenFragment,
) {
  final rawText = _plainText(content);
  if (rawText == null) return null;
  final text = _normalizeDigits(rawText);

  final mainMatch = _mainNumberPattern.firstMatch(text);
  if (mainMatch == null) return null;
  final consumedMarker = mainMatch.group(0)!.trim().isNotEmpty &&
      mainMatch.end > mainMatch.start &&
      RegExp(r'[.．、:：题]').hasMatch(mainMatch.group(0)!);
  // A bare number while a fragment is already open is treated as a
  // continuation, never as a new locator: in real answer documents a bare
  // continuation like a second line of a math answer is far more common
  // than a new question consisting of one bare digit.
  if (!consumedMarker && hasOpenFragment) return null;
  final mainNumber = mainMatch.group(1)!;
  var cursor = mainMatch.end;

  String? subquestion;
  final subMatch = _subNumberPattern.firstMatch(text.substring(cursor));
  if (subMatch != null) {
    subquestion = subMatch.group(1)!;
    cursor += subMatch.end;
  }

  final remainder = _remainderContent(content, cursor, text);
  return _Locator(
    mainNumber: mainNumber,
    subquestion: subquestion,
    remainder: remainder,
  );
}

String? _parseNumber(String text) {
  final normalized = _normalizeDigits(text);
  final match = _mainNumberPattern.firstMatch(normalized);
  if (match == null) return null;
  if (match.end < normalized.length &&
      !_isTrailingPunctuation(normalized[match.end])) {
    return null;
  }
  return match.group(1);
}

String _normalizeDigits(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_fullWidthDigits[char] ?? char);
  }
  return buffer.toString();
}

bool _isTrailingPunctuation(String value) {
  return value == '.' || value == '．' || value == '、' || value == ':';
}

RichContent? _remainderContent(
  RichContent content,
  int characterOffset,
  String normalizedText,
) {
  if (content.nodes.isEmpty) return null;
  final first = content.nodes.first;
  if (first is! TextNode) return null;
  if (characterOffset >= normalizedText.length) return null;
  var remainderText = normalizedText.substring(characterOffset);
  remainderText = remainderText.replaceFirst(_answerMarkerPattern, '');
  if (remainderText.trim().isEmpty) return null;
  final nodes = <ContentNode>[
    TextNode(remainderText),
    ...content.nodes.skip(1),
  ];
  return RichContent(nodes: nodes);
}

String? _plainText(RichContent content) {
  if (content.nodes.isEmpty) return null;
  final buffer = StringBuffer();
  for (final node in content.nodes) {
    if (node is TextNode) buffer.write(node.text);
  }
  final value = buffer.toString();
  return value.isEmpty ? null : value;
}

/// Mutable transient fragment builder. Combines multi-part answers
/// structurally and closes fragments when a new locator starts.
final class _FragmentBuilder {
  final List<RichContent> _headingContext = <RichContent>[];
  String? _fragmentId;
  int _partIndex = 0;
  String? _normalizedMainNumber;
  String? _normalizedSubquestion;
  final List<ContentNode> _answerNodes = <ContentNode>[];
  final List<ContentNode> _explanationNodes = <ContentNode>[];
  final List<SourceRef> _answerSourceRefs = <SourceRef>[];
  int? _tableRow;
  int? _tableColumn;
  int _continuationOrdinal = 0;
  bool _hasAnswerContent = false;
  bool _hasExplanationContent = false;
  int _fragmentOrdinal = 0;

  bool get hasOpenFragment => _fragmentId != null;

  final List<int> emptySkippedPartIndexes = <int>[];

  void pushHeading(RichContent heading) {
    _headingContext.add(heading);
    if (_headingContext.length > 4) {
      _headingContext.removeAt(0);
    }
  }

  List<SupplementalAnswerFragment> start({
    required int partIndex,
    required SourceRef sourceRef,
    required String normalizedMainNumber,
    required String? normalizedSubquestion,
    required RichContent? initialAnswer,
    required RichContent? initialExplanation,
    int? tableRow,
    int? tableColumn,
  }) {
    final closed = close();
    _fragmentId = 'frag_${partIndex}_$_fragmentOrdinal';
    _fragmentOrdinal += 1;
    _partIndex = partIndex;
    _normalizedMainNumber = normalizedMainNumber;
    _normalizedSubquestion = normalizedSubquestion;
    _tableRow = tableRow;
    _tableColumn = tableColumn;
    _continuationOrdinal = 0;
    _answerNodes.clear();
    _explanationNodes.clear();
    _answerSourceRefs.clear();
    _hasAnswerContent = false;
    _hasExplanationContent = false;
    if (initialAnswer != null && initialAnswer.nodes.isNotEmpty) {
      _answerNodes.addAll(initialAnswer.nodes);
      _answerSourceRefs.add(sourceRef);
      _hasAnswerContent = true;
    }
    if (initialExplanation != null && initialExplanation.nodes.isNotEmpty) {
      _explanationNodes.addAll(initialExplanation.nodes);
      _hasExplanationContent = true;
    }
    return closed;
  }

  void appendAnswer(RichContent content, SourceRef sourceRef) {
    if (!hasOpenFragment) return;
    if (content.nodes.isEmpty) return;
    _answerNodes.addAll(content.nodes);
    _answerSourceRefs.add(sourceRef);
    _hasAnswerContent = true;
    _continuationOrdinal += 1;
  }

  void appendExplanation(RichContent content, SourceRef sourceRef) {
    if (!hasOpenFragment) return;
    if (content.nodes.isEmpty) return;
    _explanationNodes.addAll(content.nodes);
    _hasExplanationContent = true;
    _continuationOrdinal += 1;
  }

  List<SupplementalAnswerFragment> close() {
    final id = _fragmentId;
    if (id == null) return const <SupplementalAnswerFragment>[];
    _fragmentId = null;
    if (!_hasAnswerContent) {
      emptySkippedPartIndexes.add(_partIndex);
      return const <SupplementalAnswerFragment>[];
    }
    final fragment = SupplementalAnswerFragment(
      fragmentId: id,
      normalizedMainNumber: _normalizedMainNumber,
      normalizedSubquestion: _normalizedSubquestion,
      answerContent: RichContent(
        nodes: List<ContentNode>.unmodifiable(_answerNodes),
      ),
      explanationContent: _hasExplanationContent
          ? RichContent(
              nodes: List<ContentNode>.unmodifiable(_explanationNodes),
            )
          : null,
      headingContext: List<RichContent>.unmodifiable(_headingContext),
      sourceRefs: List<SourceRef>.unmodifiable(_answerSourceRefs),
      sequencePosition: SupplementalSequencePosition(
        partIndex: _partIndex,
        tableRow: _tableRow,
        tableColumn: _tableColumn,
        continuationOrdinal: _continuationOrdinal,
      ),
    );
    return <SupplementalAnswerFragment>[fragment];
  }
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
