import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_privacy_admission.dart';
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

/// A parenthesized number, e.g. `(1)` / `（15）`. Whether it is a top-level
/// locator or a subquestion depends on the surrounding field evidence.
final _bracketNumberPattern = RegExp(r'^\s*[（(]\s*(\d{1,4})\s*[)）]\s*');

/// Field markers are recognized only inside a bounded leading prefix, so a
/// long part is never flattened just to find one.
const int _markerScanPrefixLength = 24;

/// A PDF text layer may keep one visually continuous answer line as several
/// ordered text runs, so locator and marker recognition may join a bounded run
/// of adjacent content parts. Both bounds are fixed constants: the window never
/// grows with the document and never carries an answer body.
const int _maxLookaheadParts = 8;
const int _maxLookaheadChars = 128;

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

/// A separator that turns a bare number into primary locator evidence.
final _locatorSeparatorPattern = RegExp(r'[.．、:：题]');

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
  contentAdmissionRejected,
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

    final parts = document.parts;
    var partIndex = 0;
    while (partIndex < parts.length) {
      final part = parts[partIndex];
      switch (part) {
        case SourceContentPart(
            :final sourceRef,
            :final content,
            :final role,
          ):
          if (role == SourceContentRole.heading) {
            builder.pushHeading(content);
            partIndex += 1;
          } else {
            partIndex += _projectContentPart(
              partIndex: partIndex,
              parts: parts,
              sourceRef: sourceRef,
              content: content,
              builder: builder,
              fragments: fragments,
              issues: issues,
            );
          }
        case SourceTablePart(:final sourceRef, :final rows):
          _projectTablePart(
            partIndex: partIndex,
            sourceRef: sourceRef,
            rows: rows,
            builder: builder,
            fragments: fragments,
            issues: issues,
          );
          partIndex += 1;
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
          } else if (!builder.hasOpenFragment) {
            issues.add(
              SupplementalProjectionIssue(
                kind: SupplementalProjectionIssueKind
                    .imageWithoutOpenFragmentSkipped,
                partIndex: partIndex,
              ),
            );
          } else {
            builder.appendAnswer(altText, sourceRef);
          }
          partIndex += 1;
        case UnsupportedSourcePart():
          issues.add(
            SupplementalProjectionIssue(
              kind: SupplementalProjectionIssueKind.unsupportedPartSkipped,
              partIndex: partIndex,
            ),
          );
          partIndex += 1;
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
    issues.addAll(
      builder.admissionRejectedPartIndexes.map(
        (partIndex) => SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind.contentAdmissionRejected,
          partIndex: partIndex,
        ),
      ),
    );
    return SupplementalProjectionResult(
      fragments: List<SupplementalAnswerFragment>.unmodifiable(fragments),
      issues: List<SupplementalProjectionIssue>.unmodifiable(issues),
    );
  }

  /// Projects one content part and returns how many consecutive parts that
  /// consumed. A locator or field marker that the source split across adjacent
  /// text runs consumes every part the recognized token covers.
  int _projectContentPart({
    required int partIndex,
    required List<SourcePart> parts,
    required SourceRef sourceRef,
    required RichContent content,
    required _FragmentBuilder builder,
    required List<SupplementalAnswerFragment> fragments,
    required List<SupplementalProjectionIssue> issues,
  }) {
    final locator = _extractLocator(content, builder.openMainNumber);
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
        return 1;
      }
      final closed = builder.start(
        partIndex: partIndex,
        sourceRef: sourceRef,
        normalizedMainNumber: locator.mainNumber,
        normalizedSubquestion: locator.subquestion,
        initialContent: locator.content,
        initialField: locator.field,
        solutionBlock: locator.solutionBlock,
        evidencePartIndex: partIndex,
      );
      fragments.addAll(closed);
      return 1;
    }

    final crossLocator = _recognizeCrossPartLocator(
      parts: parts,
      startIndex: partIndex,
      openMainNumber: builder.openMainNumber,
    );
    if (crossLocator != null) {
      if (crossLocator.ambiguousLine) {
        issues.add(
          SupplementalProjectionIssue(
            kind: SupplementalProjectionIssueKind.ambiguousMultiLocatorLine,
            partIndex: partIndex,
          ),
        );
        return crossLocator.consumedParts;
      }
      final closed = builder.start(
        partIndex: partIndex,
        sourceRef: sourceRef,
        normalizedMainNumber: crossLocator.mainNumber,
        normalizedSubquestion: crossLocator.subquestion,
        initialContent: null,
        initialField: crossLocator.markerKind == _FieldMarkerKind.explicitAnswer
            ? _FragmentField.answer
            : _FragmentField.explanation,
        solutionBlock:
            crossLocator.markerKind == _FieldMarkerKind.solutionBlock,
      );
      fragments.addAll(closed);
      builder.applyMarkerSlices(
        kind: crossLocator.markerKind,
        slices: crossLocator.slices,
      );
      return crossLocator.consumedParts;
    }

    if (!builder.hasOpenFragment) {
      issues.add(
        SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind
              .continuationWithoutFragmentSkipped,
          partIndex: partIndex,
        ),
      );
      return 1;
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
        partIndex: partIndex,
        kind: marker.kind,
      );
      return 1;
    }

    final crossMarker = _recognizeCrossPartMarker(
      parts: parts,
      startIndex: partIndex,
    );
    if (crossMarker != null) {
      builder.applyMarkerSlices(
        kind: crossMarker.kind,
        slices: crossMarker.slices,
      );
      return crossMarker.consumedParts;
    }

    builder.appendContinuation(content, sourceRef, partIndex);
    return 1;
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

_Locator? _extractLocator(RichContent content, String? openMainNumber) {
  final rawText = _plainText(content);
  if (rawText == null) return null;
  final text = _normalizeDigits(rawText);

  final mainMatch = _mainNumberPattern.firstMatch(text);
  if (mainMatch != null) {
    final consumedMarker = mainMatch.group(0)!.trim().isNotEmpty &&
        mainMatch.end > mainMatch.start &&
        _locatorSeparatorPattern.hasMatch(mainMatch.group(0)!);
    // A bare number is never a locator on its own: without a separator, `题`,
    // or a field marker it carries no primary locator evidence, so a document
    // title year such as `2019` or a bare formula value stays ordinary content
    // instead of opening a fragment that swallows the rest of the document.
    if (!consumedMarker) return null;
    var cursor = mainMatch.end;
    final subMatch = cursor >= text.length
        ? null
        : _subNumberPattern.firstMatch(text.substring(cursor));
    if (subMatch != null) cursor += subMatch.end;
    return _locatedAt(
      content: content,
      text: text,
      mainNumber: mainMatch.group(1)!,
      cursor: cursor,
      subquestion: subMatch?.group(1),
    );
  }

  final bracketMatch = _bracketNumberPattern.firstMatch(text);
  if (bracketMatch == null) return null;
  if (!_bracketNumberOpensField(
    text: text,
    cursor: bracketMatch.end,
    candidateNumber: bracketMatch.group(1)!,
    openMainNumber: openMainNumber,
  )) {
    return null;
  }
  return _locatedAt(
    content: content,
    text: text,
    mainNumber: bracketMatch.group(1)!,
    cursor: bracketMatch.end,
    subquestion: null,
  );
}

/// Whether one parenthesized number is proven to be a top-level locator.
///
/// The bracket shape is not evidence by itself: the number must open a
/// recognised field marker, and it must not step backwards inside an already
/// open fragment, which is what a sub-solution line such as `(1)【解】…` under
/// an open `18.` looks like. Anything unproven stays ordinary content.
bool _bracketNumberOpensField({
  required String text,
  required int cursor,
  required String candidateNumber,
  required String? openMainNumber,
}) {
  if (cursor >= text.length) return false;
  if (_leadingFieldMarker(text.substring(cursor)) == null) return false;
  final openMain = openMainNumber;
  if (openMain == null) return true;
  final candidate = int.tryParse(_normalizeDigits(candidateNumber));
  final open = int.tryParse(_normalizeDigits(openMain));
  if (candidate == null || open == null) return false;
  return candidate > open;
}

_Locator _locatedAt({
  required RichContent content,
  required String text,
  required String mainNumber,
  required int cursor,
  required String? subquestion,
}) {
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

/// One adjacent content part inside a bounded recognition window.
///
/// [start] and [end] are offsets into the window's joined text. They stay valid
/// against the digit-normalized join because [_normalizeDigits] maps one code
/// unit to one code unit, so normalization never shifts an offset.
final class _WindowEntry {
  const _WindowEntry({
    required this.partIndex,
    required this.sourceRef,
    required this.content,
    required this.text,
    required this.start,
    required this.end,
  });

  final int partIndex;
  final SourceRef sourceRef;
  final RichContent content;
  final String text;
  final int start;
  final int end;
}

/// One recognized content region, attributed to the part it came from.
final class _ContentSlice {
  const _ContentSlice({
    required this.partIndex,
    required this.content,
    required this.sourceRef,
  });

  final int partIndex;
  final RichContent content;
  final SourceRef sourceRef;
}

/// A locator whose field marker was proven across adjacent parts.
final class _CrossPartLocator {
  const _CrossPartLocator({
    required this.mainNumber,
    required this.subquestion,
    required this.markerKind,
    required this.slices,
    required this.consumedParts,
    required this.ambiguousLine,
  });

  final String mainNumber;
  final String? subquestion;
  final _FieldMarkerKind markerKind;
  final List<_ContentSlice> slices;
  final int consumedParts;
  final bool ambiguousLine;
}

/// A field marker proven at the start of a run of adjacent continuation parts.
final class _CrossPartMarker {
  const _CrossPartMarker({
    required this.kind,
    required this.slices,
    required this.consumedParts,
  });

  final _FieldMarkerKind kind;
  final List<_ContentSlice> slices;
  final int consumedParts;
}

/// Collects the bounded window of adjacent parts one recognition may join.
///
/// The window stops at a structural part, a heading, a part carrying any
/// non-text node, the fixed part/character bounds, and at a part that already
/// proves its own top-level locator. Joining is recognition-only: content is
/// sliced back out of the original text nodes, so no structure is flattened and
/// every slice keeps the [SourceRef] of the part that really contributed it.
List<_WindowEntry> _recognitionWindow(List<SourcePart> parts, int startIndex) {
  final entries = <_WindowEntry>[];
  var length = 0;
  for (var index = startIndex;
      index < parts.length && entries.length < _maxLookaheadParts;
      index++) {
    final part = parts[index];
    if (part is! SourceContentPart) break;
    if (part.role == SourceContentRole.heading) break;
    final text = _plainText(part.content);
    if (text == null) break;
    if (!part.content.nodes.every((node) => node is TextNode)) break;
    if (length + text.length > _maxLookaheadChars) break;
    if (entries.isNotEmpty && _beginsProvenLocator(_normalizeDigits(text))) {
      break;
    }
    entries.add(
      _WindowEntry(
        partIndex: index,
        sourceRef: part.sourceRef,
        content: part.content,
        text: text,
        start: length,
        end: length + text.length,
      ),
    );
    length += text.length;
  }
  return entries;
}

/// Whether one part's own text already proves a top-level locator.
///
/// Used only as a window boundary: such a part starts a new question, so the
/// previous window must not reach across it.
bool _beginsProvenLocator(String normalizedText) {
  final main = _mainNumberPattern.firstMatch(normalizedText);
  if (main != null) {
    final consumedMarker = main.group(0)!.trim().isNotEmpty &&
        main.end > main.start &&
        _locatorSeparatorPattern.hasMatch(main.group(0)!);
    if (consumedMarker &&
        main.end < normalizedText.length &&
        _leadingFieldMarker(normalizedText.substring(main.end)) != null) {
      return true;
    }
  }
  final bracket = _bracketNumberPattern.firstMatch(normalizedText);
  return bracket != null &&
      bracket.end < normalizedText.length &&
      _leadingFieldMarker(normalizedText.substring(bracket.end)) != null;
}

String _joinedWindowText(List<_WindowEntry> window) {
  return _normalizeDigits(window.map((entry) => entry.text).join());
}

/// End of the window entry that contains [offset].
int _windowRegionEnd(List<_WindowEntry> window, int offset) {
  for (final entry in window) {
    if (entry.end > offset) return entry.end;
  }
  return window.last.end;
}

/// How many leading window entries a region ending at [offset] covers.
int _windowConsumedParts(List<_WindowEntry> window, int offset) {
  var count = 0;
  for (final entry in window) {
    if (entry.start < offset) count += 1;
  }
  return count;
}

/// Slices `[from, to)` of the joined window back into per-part content.
List<_ContentSlice> _sliceWindow(List<_WindowEntry> window, int from, int to) {
  final slices = <_ContentSlice>[];
  for (final entry in window) {
    if (entry.end <= from) continue;
    if (entry.start >= to) break;
    final content = _sliceTextContent(
      entry.content,
      (from - entry.start).clamp(0, entry.text.length),
      (to - entry.start).clamp(0, entry.text.length),
    );
    if (content == null) continue;
    slices.add(
      _ContentSlice(
        partIndex: entry.partIndex,
        content: content,
        sourceRef: entry.sourceRef,
      ),
    );
  }
  return slices;
}

/// Cuts `[from, to)` out of one text-only content without reparsing it.
RichContent? _sliceTextContent(RichContent content, int from, int to) {
  if (to <= from) return null;
  final nodes = <ContentNode>[];
  var offset = 0;
  for (final node in content.nodes) {
    final text = (node as TextNode).text;
    final nodeEnd = offset + text.length;
    if (nodeEnd > from && offset < to) {
      final start = (from - offset).clamp(0, text.length);
      final end = (to - offset).clamp(0, text.length);
      if (end > start) nodes.add(TextNode(text.substring(start, end)));
    }
    offset = nodeEnd;
  }
  return nodes.isEmpty ? null : RichContent(nodes: nodes);
}

/// Recovers one locator plus its field marker from a run of adjacent parts.
///
/// Only reached when the part alone proved nothing. The frozen contract
/// recognizes a marker right after a locator or at the start of a continuation
/// part; this joins adjacent runs at those same two boundaries and adds no
/// third recognition point, so a locator is proven only by the marker that
/// immediately follows it inside the window.
_CrossPartLocator? _recognizeCrossPartLocator({
  required List<SourcePart> parts,
  required int startIndex,
  required String? openMainNumber,
}) {
  final window = _recognitionWindow(parts, startIndex);
  if (window.length < 2) return null;
  final text = _joinedWindowText(window);

  final mainMatch = _mainNumberPattern.firstMatch(text);
  if (mainMatch != null) {
    final consumedMarker = mainMatch.group(0)!.trim().isNotEmpty &&
        mainMatch.end > mainMatch.start &&
        _locatorSeparatorPattern.hasMatch(mainMatch.group(0)!);
    // A bare number stays content here exactly as it does inside one part.
    if (!consumedMarker) return null;
    var cursor = mainMatch.end;
    final subMatch = cursor >= text.length
        ? null
        : _subNumberPattern.firstMatch(text.substring(cursor));
    if (subMatch != null) cursor += subMatch.end;
    return _crossPartLocatorAt(
      window: window,
      text: text,
      mainNumber: mainMatch.group(1)!,
      subquestion: subMatch?.group(1),
      cursor: cursor,
    );
  }

  final bracketMatch = _bracketNumberPattern.firstMatch(text);
  if (bracketMatch == null) return null;
  if (!_bracketNumberOpensField(
    text: text,
    cursor: bracketMatch.end,
    candidateNumber: bracketMatch.group(1)!,
    openMainNumber: openMainNumber,
  )) {
    return null;
  }
  return _crossPartLocatorAt(
    window: window,
    text: text,
    mainNumber: bracketMatch.group(1)!,
    subquestion: null,
    cursor: bracketMatch.end,
  );
}

_CrossPartLocator? _crossPartLocatorAt({
  required List<_WindowEntry> window,
  required String text,
  required String mainNumber,
  required String? subquestion,
  required int cursor,
}) {
  if (cursor >= text.length) return null;
  final marker = _leadingFieldMarker(text.substring(cursor));
  if (marker == null) return null;
  final markerEnd = cursor + marker.end;
  final contentEnd = _windowRegionEnd(window, markerEnd);
  return _CrossPartLocator(
    mainNumber: mainNumber,
    subquestion: subquestion,
    markerKind: marker.kind,
    slices: _sliceWindow(window, markerEnd, contentEnd),
    consumedParts: _windowConsumedParts(window, contentEnd),
    ambiguousLine: _hasInlineMainLocator(text.substring(markerEnd, contentEnd)),
  );
}

/// Recovers one field marker that a run of adjacent continuation parts split.
_CrossPartMarker? _recognizeCrossPartMarker({
  required List<SourcePart> parts,
  required int startIndex,
}) {
  final window = _recognitionWindow(parts, startIndex);
  if (window.length < 2) return null;
  final text = _joinedWindowText(window);
  final marker = _leadingFieldMarker(text);
  if (marker == null) return null;
  final contentEnd = _windowRegionEnd(window, marker.end);
  // The answer field never keeps an explicit answer marker; explanation and
  // solution markers stay in their own field verbatim.
  final from = marker.kind == _FieldMarkerKind.explicitAnswer ? marker.end : 0;
  return _CrossPartMarker(
    kind: marker.kind,
    slices: _sliceWindow(window, from, contentEnd),
    consumedParts: _windowConsumedParts(window, contentEnd),
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
  final List<SupplementalAnswerPartSegment> _answerPartEvidence =
      <SupplementalAnswerPartSegment>[];
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

  /// Main number of the fragment still collecting content, when it has one.
  String? get openMainNumber =>
      _fragmentId == null ? null : _normalizedMainNumber;

  final List<int> emptySkippedPartIndexes = <int>[];

  /// Parts whose assembled content failed RichContent admission.
  final List<int> admissionRejectedPartIndexes = <int>[];

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
    int? evidencePartIndex,
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
    _answerPartEvidence.clear();
    _hasAnswerContent = false;
    _hasExplanationContent = false;
    _field = initialField;
    _solutionField = solutionBlock;
    if (initialContent != null && initialContent.nodes.isNotEmpty) {
      if (initialField == _FragmentField.answer) {
        _collectAnswer(initialContent, sourceRef, evidencePartIndex);
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
    required int partIndex,
    required _FieldMarkerKind kind,
  }) {
    applyMarkerSlices(
      kind: kind,
      slices: <_ContentSlice>[
        _ContentSlice(
          partIndex: partIndex,
          content: content,
          sourceRef: sourceRef,
        ),
      ],
    );
  }

  /// Applies one field marker together with the ordered content that followed
  /// it. Each slice stays bound to the part that really contributed it, so a
  /// marker recovered across adjacent parts never invents provenance.
  void applyMarkerSlices({
    required _FieldMarkerKind kind,
    required List<_ContentSlice> slices,
  }) {
    if (!hasOpenFragment) return;
    switch (kind) {
      case _FieldMarkerKind.explicitAnswer:
        _field = _FragmentField.answer;
        _solutionField = false;
        for (final slice in slices) {
          appendAnswer(
            slice.content,
            slice.sourceRef,
            partIndex: slice.partIndex,
          );
        }
      case _FieldMarkerKind.explanation:
        _field = _FragmentField.explanation;
        _solutionField = false;
        for (final slice in slices) {
          appendExplanation(slice.content, slice.sourceRef);
        }
      case _FieldMarkerKind.solutionBlock:
        _field = _FragmentField.explanation;
        _solutionField = true;
        for (final slice in slices) {
          appendExplanation(slice.content, slice.sourceRef);
        }
    }
  }

  /// Appends one marker-less part to the field that is currently open.
  void appendContinuation(
      RichContent content, SourceRef sourceRef, int partIndex) {
    if (!hasOpenFragment) return;
    if (_field == _FragmentField.explanation) {
      appendExplanation(content, sourceRef);
    } else {
      appendAnswer(content, sourceRef, partIndex: partIndex);
    }
  }

  void appendAnswer(RichContent content, SourceRef sourceRef,
      {int? partIndex}) {
    if (!hasOpenFragment) return;
    if (_isStructurallyBlankAnswer(content.nodes)) return;
    _collectAnswer(content, sourceRef, partIndex);
    _continuationOrdinal += 1;
  }

  /// Appends one answer contribution and, when it came from a real content
  /// part, records the part-boundary evidence segment of that contribution.
  ///
  /// A contribution whose provenance is not a text part keeps its ordered
  /// [SourceRef] but never claims part-boundary evidence.
  void _collectAnswer(
      RichContent content, SourceRef sourceRef, int? partIndex) {
    final nodeStart = _answerNodes.length;
    _answerNodes.addAll(content.nodes);
    _answerSourceRefs.add(sourceRef);
    _hasAnswerContent = true;
    if (partIndex == null) return;
    _answerPartEvidence.add(
      SupplementalAnswerPartSegment(
        partIndex: partIndex,
        answerNodeStart: nodeStart,
        answerNodeEnd: _answerNodes.length,
        content: content,
        sourceRef: sourceRef,
      ),
    );
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
      final derivedContent = RichContent(
        nodes: List<ContentNode>.unmodifiable(_explanationNodes),
      );
      if (!_isAdmissible(answer: derivedContent, explanation: null)) {
        admissionRejectedPartIndexes.add(_partIndex);
        return const <SupplementalAnswerFragment>[];
      }
      return <SupplementalAnswerFragment>[
        SupplementalAnswerFragment(
          fragmentId: id,
          normalizedMainNumber: _normalizedMainNumber,
          normalizedSubquestion: _normalizedSubquestion,
          answerContent: derivedContent,
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
    final answerContent = RichContent(
      nodes: List<ContentNode>.unmodifiable(_answerNodes),
    );
    final explanationContent = _hasExplanationContent
        ? RichContent(
            nodes: List<ContentNode>.unmodifiable(_explanationNodes),
          )
        : null;
    if (!_isAdmissible(
      answer: answerContent,
      explanation: explanationContent,
    )) {
      // Content that cannot be admitted is never truncated and never becomes a
      // candidate: the fragment is dropped with one bounded projection issue.
      admissionRejectedPartIndexes.add(_partIndex);
      return const <SupplementalAnswerFragment>[];
    }
    final fragment = SupplementalAnswerFragment(
      fragmentId: id,
      normalizedMainNumber: _normalizedMainNumber,
      normalizedSubquestion: _normalizedSubquestion,
      answerContent: answerContent,
      explanationContent: explanationContent,
      headingContext: List<RichContent>.unmodifiable(_headingContext),
      sourceRefs: List<SourceRef>.unmodifiable(_answerSourceRefs),
      sequencePosition: SupplementalSequencePosition(
        partIndex: _partIndex,
        tableRow: _tableRow,
        tableColumn: _tableColumn,
        continuationOrdinal: _continuationOrdinal,
      ),
      source: SupplementalAnswerSource.explicitAnswer,
      answerPartEvidence: _answerPartEvidence,
    );
    return <SupplementalAnswerFragment>[fragment];
  }

  /// The projector assembles new structure, so it enforces the same admission
  /// bound as any persisted content before a fragment may leave this boundary.
  bool _isAdmissible({
    required RichContent answer,
    required RichContent? explanation,
  }) {
    const admission = RichContentPrivacyAdmission();
    try {
      admission.validate(answer);
      final explanationContent = explanation;
      if (explanationContent != null) {
        admission.validate(explanationContent);
      }
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// Mirrors the typed assembler's structural-emptiness rule: a contribution
/// made only of blank text nodes carries no answer content, so it is treated
/// exactly like an empty part; any non-text node is always preserved.
bool _isStructurallyBlankAnswer(List<ContentNode> nodes) {
  return nodes.isEmpty ||
      nodes.every((node) => node is TextNode && node.text.trim().isEmpty);
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
