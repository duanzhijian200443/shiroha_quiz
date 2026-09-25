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

/// Field markers are recognized only inside a bounded leading prefix, so a
/// long part is never flattened just to find one.
const int _markerScanPrefixLength = 24;

/// Paired `【】` / `[]` wrappers delimit a marker on their own.
final _wrappedFieldMarkerPattern = RegExp(
  r'^\s*[【\[]\s*(参考答案|答案|解析|详解|分析|说明|证明|解)\s*[】\]]\s*[:：]?\s*',
);

/// An unwrapped marker must be delimited by a colon or whitespace.
final _bareFieldMarkerPattern = RegExp(
  r'^\s*(参考答案|答案|解析|详解|分析|说明|证明|解)(?:[:：]\s*|\s+)',
);

/// A part that consists of nothing but one marker.
final _trailingFieldMarkerPattern = RegExp(
  r'^\s*(参考答案|答案|解析|详解|分析|说明|证明|解)\s*[:：]?\s*$',
);

/// A parenthesized context label such as `(I)` / `(II)` that may precede a
/// marker while staying part of the content.
final _contextLabelPattern = RegExp(
  r'^\s*[（(]\s*[A-Za-zⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹ]{1,4}\s*[)）]\s*',
);

/// A second main locator appearing after the first one on the same line.
final _inlineMainLocatorPattern = RegExp(r'\s+\d{1,4}\s*[.．、](?!\d)\s*\S');

/// Field a fragment is currently collecting.
enum _FragmentField { answer, explanation }

/// Kind of one recognized field marker.
enum _FieldMarkerKind { explicitAnswer, explanation, solutionBlock }

final class _FieldMarkerMatch {
  const _FieldMarkerMatch({
    required this.kind,
    required this.start,
    required this.end,
  });

  final _FieldMarkerKind kind;

  /// Offset where the marker itself starts inside the scanned text.
  final int start;

  /// Offset just past the marker inside the scanned text.
  final int end;
}

/// Recognizes one leading answer/explanation/solution marker.
///
/// Frozen vocabulary: `答案` / `参考答案` state an answer; `解析` / `详解` /
/// `分析` / `说明` open a study explanation; `解` / `证明` open a solution body
/// that is derived content rather than an answer statement. A parenthesized
/// context label such as `(I)` may precede the marker and stays content.
_FieldMarkerMatch? _leadingFieldMarker(String text) {
  final prefix = text.length > _markerScanPrefixLength
      ? text.substring(0, _markerScanPrefixLength)
      : text;
  var offset = 0;
  final label = _contextLabelPattern.firstMatch(prefix);
  if (label != null) offset = label.end;
  if (offset >= prefix.length) return null;
  final scan = prefix.substring(offset);

  final wrapped = _wrappedFieldMarkerPattern.firstMatch(scan);
  if (wrapped != null) {
    return _FieldMarkerMatch(
      kind: _fieldMarkerKind(wrapped.group(1)!),
      start: offset + wrapped.start,
      end: offset + wrapped.end,
    );
  }
  final bare = _bareFieldMarkerPattern.firstMatch(scan);
  if (bare != null) {
    return _FieldMarkerMatch(
      kind: _fieldMarkerKind(bare.group(1)!),
      start: offset + bare.start,
      end: offset + bare.end,
    );
  }
  if (prefix.length == text.length) {
    final trailing = _trailingFieldMarkerPattern.firstMatch(scan);
    if (trailing != null) {
      return _FieldMarkerMatch(
        kind: _fieldMarkerKind(trailing.group(1)!),
        start: offset + trailing.start,
        end: offset + trailing.end,
      );
    }
  }
  return null;
}

_FieldMarkerKind _fieldMarkerKind(String token) {
  return switch (token) {
    '答案' || '参考答案' => _FieldMarkerKind.explicitAnswer,
    '解' || '证明' => _FieldMarkerKind.solutionBlock,
    _ => _FieldMarkerKind.explanation,
  };
}

/// Safe typed projection issue; retains no raw source text or paths.
enum SupplementalProjectionIssueKind {
  unsupportedPartSkipped,
  imageWithoutAltTextSkipped,
  imageWithoutOpenFragmentSkipped,
  tableUnrecognized,
  continuationWithoutFragmentSkipped,
  emptyAnswerSkipped,
  ambiguousMultiLocatorLine,
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
      if (locator.ambiguousLine) {
        // A second main locator on the same line is only split when the syntax
        // is unambiguous; here the line stays unwritable and, critically, none
        // of it may be swallowed into the previous question's answer.
        issues.add(
          SupplementalProjectionIssue(
            kind: SupplementalProjectionIssueKind.ambiguousMultiLocatorLine,
            partIndex: partIndex,
          ),
        );
        return;
      }
      final closed = builder.start(
        partIndex: partIndex,
        sourceRef: sourceRef,
        normalizedMainNumber: locator.mainNumber,
        normalizedSubquestion: locator.subquestion,
        initialContent: locator.content,
        initialField: locator.field,
        solutionBlock: locator.solutionBlock,
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

    final marker = _leadingFieldMarker(_plainText(content) ?? '');
    if (marker != null) {
      builder.applyMarker(
        // The answer field never keeps an explicit answer marker, matching the
        // located-remainder behavior; explanation and solution markers stay in
        // their own field verbatim.
        content: marker.kind == _FieldMarkerKind.explicitAnswer
            ? _withoutMarkerSpan(content, marker)
            : content,
        sourceRef: sourceRef,
        kind: marker.kind,
      );
      return;
    }
    builder.appendContinuation(content, sourceRef);
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
        initialContent: answerContent,
        initialField: _FragmentField.answer,
        solutionBlock: false,
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
    required this.content,
    required this.field,
    required this.solutionBlock,
    required this.ambiguousLine,
  });

  final String mainNumber;
  final String? subquestion;

  /// Remainder of the same part after the locator and any leading marker.
  final RichContent? content;

  /// Field the remainder belongs to once its marker is applied.
  final _FragmentField field;

  /// Whether the remainder was opened by a `解` / `证明` marker.
  final bool solutionBlock;

  /// Whether a second main locator makes this line unwritable.
  final bool ambiguousLine;
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

  final remainderText = cursor >= text.length ? '' : text.substring(cursor);
  final scan = _scanRemainder(content, cursor, text);
  return _Locator(
    mainNumber: mainNumber,
    subquestion: subquestion,
    content: scan.content,
    field: scan.field,
    solutionBlock: scan.solutionBlock,
    ambiguousLine: _hasInlineMainLocator(remainderText),
  );
}

/// Whether one line carries a second main locator after the first one.
bool _hasInlineMainLocator(String remainderText) {
  return _inlineMainLocatorPattern.hasMatch(remainderText);
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

/// Remainder of one located part together with its marker classification.
final class _RemainderScan {
  const _RemainderScan({
    required this.content,
    required this.field,
    required this.solutionBlock,
  });

  final RichContent? content;
  final _FragmentField field;
  final bool solutionBlock;
}

_RemainderScan _scanRemainder(
  RichContent content,
  int characterOffset,
  String normalizedText,
) {
  const empty = _RemainderScan(
    content: null,
    field: _FragmentField.answer,
    solutionBlock: false,
  );
  if (content.nodes.isEmpty) return empty;
  final first = content.nodes.first;
  if (first is! TextNode) return empty;
  if (characterOffset >= normalizedText.length) return empty;

  var remainderText = normalizedText.substring(characterOffset);
  var field = _FragmentField.answer;
  var solutionBlock = false;
  final marker = _leadingFieldMarker(remainderText);
  if (marker != null) {
    field = switch (marker.kind) {
      _FieldMarkerKind.explicitAnswer => _FragmentField.answer,
      _FieldMarkerKind.explanation ||
      _FieldMarkerKind.solutionBlock =>
        _FragmentField.explanation,
    };
    solutionBlock = marker.kind == _FieldMarkerKind.solutionBlock;
    if (marker.kind == _FieldMarkerKind.explicitAnswer) {
      // Answer markers are stripped from the answer body while any content
      // before the marker (for example an `(I)` context label) is preserved;
      // explanation and solution markers stay in their own field verbatim.
      remainderText = remainderText.substring(0, marker.start) +
          remainderText.substring(marker.end);
    }
  }

  if (remainderText.trim().isEmpty) {
    return _RemainderScan(
      content: null,
      field: field,
      solutionBlock: solutionBlock,
    );
  }
  final nodes = <ContentNode>[
    TextNode(remainderText),
    ...content.nodes.skip(1),
  ];
  return _RemainderScan(
    content: RichContent(nodes: nodes),
    field: field,
    solutionBlock: solutionBlock,
  );
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

/// Removes one recognized marker span from the leading text node.
///
/// A marker that does not fit inside that node is left in place: content is
/// never rewritten across node boundaries.
RichContent _withoutMarkerSpan(RichContent content, _FieldMarkerMatch marker) {
  if (content.nodes.isEmpty) return content;
  final first = content.nodes.first;
  if (first is! TextNode || marker.end > first.text.length) return content;
  final text =
      first.text.substring(0, marker.start) + first.text.substring(marker.end);
  if (text.isEmpty) {
    return RichContent(nodes: content.nodes.skip(1).toList(growable: false));
  }
  return RichContent(
    nodes: <ContentNode>[
      TextNode(text),
      ...content.nodes.skip(1),
    ],
  );
}

/// Mutable transient fragment builder. Combines multi-part answers
/// structurally, tracks the current answer/explanation field, and closes
/// fragments when a new locator starts.
final class _FragmentBuilder {
  final List<RichContent> _headingContext = <RichContent>[];
  String? _fragmentId;
  int _partIndex = 0;
  String? _normalizedMainNumber;
  String? _normalizedSubquestion;
  final List<ContentNode> _answerNodes = <ContentNode>[];
  final List<ContentNode> _explanationNodes = <ContentNode>[];
  final List<SourceRef> _answerSourceRefs = <SourceRef>[];
  final List<SourceRef> _solutionSourceRefs = <SourceRef>[];
  int? _tableRow;
  int? _tableColumn;
  int _continuationOrdinal = 0;
  bool _hasAnswerContent = false;
  bool _hasExplanationContent = false;
  int _fragmentOrdinal = 0;
  _FragmentField _field = _FragmentField.answer;
  bool _solutionField = false;

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
    required RichContent? initialContent,
    required _FragmentField initialField,
    required bool solutionBlock,
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
    _solutionSourceRefs.clear();
    _hasAnswerContent = false;
    _hasExplanationContent = false;
    _field = initialField;
    _solutionField = solutionBlock;
    if (initialContent != null && initialContent.nodes.isNotEmpty) {
      if (initialField == _FragmentField.answer) {
        _answerNodes.addAll(initialContent.nodes);
        _answerSourceRefs.add(sourceRef);
        _hasAnswerContent = true;
      } else {
        _explanationNodes.addAll(initialContent.nodes);
        if (solutionBlock) _solutionSourceRefs.add(sourceRef);
        _hasExplanationContent = true;
      }
    }
    return closed;
  }

  /// Applies one recognized field marker found at a field boundary.
  ///
  /// Entering the explanation field is sticky: later marker-less parts keep
  /// belonging to the explanation instead of falling back into the answer.
  void applyMarker({
    required RichContent content,
    required SourceRef sourceRef,
    required _FieldMarkerKind kind,
  }) {
    if (!hasOpenFragment) return;
    switch (kind) {
      case _FieldMarkerKind.explicitAnswer:
        _field = _FragmentField.answer;
        _solutionField = false;
        if (content.nodes.isNotEmpty) appendAnswer(content, sourceRef);
      case _FieldMarkerKind.explanation:
        _field = _FragmentField.explanation;
        _solutionField = false;
        if (content.nodes.isNotEmpty) appendExplanation(content, sourceRef);
      case _FieldMarkerKind.solutionBlock:
        _field = _FragmentField.explanation;
        _solutionField = true;
        if (content.nodes.isNotEmpty) appendExplanation(content, sourceRef);
    }
  }

  /// Appends one marker-less part to the field that is currently open.
  void appendContinuation(RichContent content, SourceRef sourceRef) {
    if (!hasOpenFragment) return;
    if (_field == _FragmentField.explanation) {
      appendExplanation(content, sourceRef);
    } else {
      appendAnswer(content, sourceRef);
    }
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
    if (_solutionField) _solutionSourceRefs.add(sourceRef);
    _hasExplanationContent = true;
    _continuationOrdinal += 1;
  }

  List<SupplementalAnswerFragment> close() {
    final id = _fragmentId;
    if (id == null) return const <SupplementalAnswerFragment>[];
    _fragmentId = null;
    if (!_hasAnswerContent) {
      if (!_solutionField || !_hasExplanationContent) {
        emptySkippedPartIndexes.add(_partIndex);
        return const <SupplementalAnswerFragment>[];
      }
      // A solution/证明 block that never carried an explicit answer stays
      // derived content: it becomes the fragment's answer body with a
      // solutionBlock source, and the matcher decides which targets accept it.
      return <SupplementalAnswerFragment>[
        SupplementalAnswerFragment(
          fragmentId: id,
          normalizedMainNumber: _normalizedMainNumber,
          normalizedSubquestion: _normalizedSubquestion,
          answerContent: RichContent(
            nodes: List<ContentNode>.unmodifiable(_explanationNodes),
          ),
          explanationContent: null,
          headingContext: List<RichContent>.unmodifiable(_headingContext),
          sourceRefs: List<SourceRef>.unmodifiable(
            _solutionSourceRefs.isEmpty
                ? _answerSourceRefs
                : _solutionSourceRefs,
          ),
          sequencePosition: SupplementalSequencePosition(
            partIndex: _partIndex,
            tableRow: _tableRow,
            tableColumn: _tableColumn,
            continuationOrdinal: _continuationOrdinal,
          ),
          source: SupplementalAnswerSource.solutionBlock,
        ),
      ];
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
      source: SupplementalAnswerSource.explicitAnswer,
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
