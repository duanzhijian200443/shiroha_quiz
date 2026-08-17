import '../../../domain/content/content_node.dart';
import '../../../domain/content/rich_content.dart';
import '../../../domain/import/import_issue.dart';
import '../../../domain/question/question_region.dart';
import '../../../domain/source/source_document.dart';
import '../../../domain/source/source_part.dart';
import '../../../domain/source/source_ref.dart';
import '../ocr_question_regionizer.dart';
import '../text_question_region.dart';

const _ocrKnownDiagnostics = <String>{
  'attached_numbered_field_in_current_region',
  'attached_numbered_field_candidate',
  'contains_formula_block',
  'contains_table_block',
  'cross_page_region',
  'missing_stem',
  'missing_answer',
  'reference_answer_attached',
  'reference_answer_confirmed',
  'reference_answer_conflict',
  'reference_answer_duplicate_conflict',
};

final class OcrQuestionRegionBridge {
  const OcrQuestionRegionBridge();

  QuestionRegion convert(
    OcrQuestionRegion region, {
    required SourceDocument sourceDocument,
  }) {
    final provenance = _resolveProvenance(
      sourceDocument,
      region.sourceBlockIds,
      region.sourcePageIndices,
    );
    final ref = provenance.ref;
    final builtFragments = _buildFragments(region, provenance);
    final fragments = builtFragments.fragments;
    final issues = <ImportIssue>{};

    if (provenance.isCoarse) {
      issues.add(
        ImportIssue(
          code: 'legacy_provenance_coarse',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.source,
          sourceRef: ref,
        ),
      );
    }
    if (builtFragments.typedDegraded) {
      issues.add(
        ImportIssue(
          code: 'legacy_provenance_coarse',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.source,
          sourceRef: ref,
        ),
      );
    }

    final hasStemFragment = fragments.any(
      (fragment) => fragment.field == QuestionRegionField.stem,
    );
    final hasAnswerFragment = fragments.any(
      (fragment) => fragment.field == QuestionRegionField.answer,
    );

    final mappedDiagnostics = <String>{};
    for (final diagnostic in region.diagnostics) {
      final code = _mapOcrDiagnostic(diagnostic);
      if (!mappedDiagnostics.add(code)) continue;
      issues.add(
        ImportIssue(
          code: code,
          severity: _severityForOcrDiagnostic(code),
          field: _fieldForOcrDiagnostic(code),
          sourceRef: ref,
        ),
      );
    }

    if (!hasStemFragment) {
      issues.add(
        ImportIssue(
          code: 'missing_stem',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.stem,
          sourceRef: ref,
        ),
      );
    }
    if (!hasAnswerFragment) {
      issues.add(
        ImportIssue(
          code: 'missing_answer',
          severity: ImportIssueSeverity.warning,
          field: ImportIssueField.answer,
          sourceRef: ref,
        ),
      );
    }

    if (fragments.isEmpty) {
      fragments.add(
        QuestionRegionFragment(
          field: QuestionRegionField.stem,
          part: SourceContentPart(
            sourceRef: ref,
            content: RichContent(nodes: const <ContentNode>[]),
          ),
        ),
      );
    }

    return QuestionRegion(
      questionNumber: region.number,
      fragments: fragments,
      kindHint: _mapKind(region.effectiveKind),
      issues: issues,
    );
  }
}

({List<QuestionRegionFragment> fragments, bool typedDegraded}) _buildFragments(
  OcrQuestionRegion region,
  ({
    SourceRef ref,
    bool isCoarse,
    List<SourcePart> matchedParts,
  }) provenance,
) {
  final entries = <({QuestionRegionField field, String text})>[];

  void addEntries(QuestionRegionField field, Iterable<String> values) {
    for (final value in values) {
      final text = value.trim();
      if (text.isNotEmpty) entries.add((field: field, text: text));
    }
  }

  addEntries(QuestionRegionField.stem, region.stemParts);
  addEntries(QuestionRegionField.answer, region.answerParts);
  addEntries(QuestionRegionField.explanation, region.explanationParts);

  final bindings = List<_PartBinding?>.filled(entries.length, null);
  final usedPartIndexes = <int>{};
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    final candidates = <_PartBinding>[];
    for (var partIndex = 0;
        partIndex < provenance.matchedParts.length;
        partIndex++) {
      if (usedPartIndexes.contains(partIndex)) continue;
      final binding = _textBinding(
        provenance.matchedParts[partIndex],
        partIndex,
        entries[entryIndex].text,
      );
      if (binding != null) candidates.add(binding);
    }

    if (candidates.length == 1) {
      final binding = candidates.single;
      bindings[entryIndex] = binding;
      usedPartIndexes.add(binding.partIndex);
    }
  }

  final unmatchedTypedParts = <int>[
    for (var index = 0; index < provenance.matchedParts.length; index++)
      if (!usedPartIndexes.contains(index) &&
          _requiresTypedPreservation(provenance.matchedParts[index]))
        index,
  ];
  final unresolvedEntries = <int>[
    for (var index = 0; index < bindings.length; index++)
      if (bindings[index] == null) index,
  ];
  final pairsSingleTypedPart =
      unmatchedTypedParts.length == 1 && unresolvedEntries.length == 1;
  if (pairsSingleTypedPart) {
    final partIndex = unmatchedTypedParts.single;
    bindings[unresolvedEntries.single] = _PartBinding(
      partIndex: partIndex,
      part: provenance.matchedParts[partIndex],
    );
  }
  final typedDegraded = !pairsSingleTypedPart && unmatchedTypedParts.isNotEmpty;

  return (
    typedDegraded: typedDegraded,
    fragments: <QuestionRegionFragment>[
      for (var index = 0; index < entries.length; index++)
        if (bindings[index] case final binding?)
          QuestionRegionFragment(
            field: entries[index].field,
            part: binding.part,
            slice: binding.slice,
          )
        else
          _fragment(entries[index].field, entries[index].text, provenance.ref),
    ],
  );
}

_PartBinding? _textBinding(
  SourcePart part,
  int partIndex,
  String text,
) {
  final sourceText = _singleTextForPart(part);
  if (sourceText == null) return null;
  final start = sourceText.indexOf(text);
  if (start < 0 || sourceText.indexOf(text, start + 1) >= 0) return null;

  if (part is SourceContentPart) {
    final end = start + text.length;
    final slice = start == 0 && end == sourceText.length
        ? null
        : SourceSlice(
            startNodeIndex: 0,
            startCodeUnitOffset: start,
            endNodeIndex: end == sourceText.length ? 1 : 0,
            endCodeUnitOffset: end == sourceText.length ? 0 : end,
          );
    return _PartBinding(partIndex: partIndex, part: part, slice: slice);
  }
  return _PartBinding(partIndex: partIndex, part: part);
}

String? _singleTextForPart(SourcePart part) {
  if (part is SourceAssetPart) {
    if (part.alternativeText != null &&
        part.alternativeText!.nodes.length == 1) {
      final node = part.alternativeText!.nodes.single;
      if (node is TextNode) return node.text;
    }
    return '[图片]';
  }
  final content = switch (part) {
    SourceContentPart(:final content) => content,
    SourceAssetPart(:final alternativeText) => alternativeText,
    UnsupportedSourcePart(:final fallbackContent) => fallbackContent,
    SourceTablePart() => null,
  };
  if (content == null || content.nodes.length != 1) return null;
  final node = content.nodes.single;
  return node is TextNode ? node.text : null;
}

bool _requiresTypedPreservation(SourcePart part) {
  return part is SourceTablePart ||
      part is SourceAssetPart ||
      part is UnsupportedSourcePart ||
      (part is SourceContentPart && part.role == SourceContentRole.formula);
}

final class _PartBinding {
  const _PartBinding({
    required this.partIndex,
    required this.part,
    this.slice,
  });

  final int partIndex;
  final SourcePart part;
  final SourceSlice? slice;
}

QuestionRegionFragment _fragment(
  QuestionRegionField field,
  String text,
  SourceRef ref,
) {
  return QuestionRegionFragment(
    field: field,
    part: SourceContentPart(
      sourceRef: ref,
      content: RichContent(nodes: <ContentNode>[TextNode(text)]),
    ),
  );
}

({SourceRef ref, bool isCoarse, List<SourcePart> matchedParts})
    _resolveProvenance(
  SourceDocument document,
  List<String> regionBlockIds,
  List<int> regionPageIndices,
) {
  final documentRef = document.documentRef;
  final matchesByBlockId = <String, List<SourceRef>>{};
  final encounterOrder = <SourceRef>[];
  final matchedParts = <SourcePart>[];

  for (final part in document.parts) {
    final point = part.sourceRef.start;
    final blockId = point?.blockId;
    if (blockId == null) continue;
    if (!regionBlockIds.contains(blockId)) continue;
    matchedParts.add(part);
    encounterOrder.add(part.sourceRef);
    matchesByBlockId
        .putIfAbsent(blockId, () => <SourceRef>[])
        .add(part.sourceRef);
  }

  for (final blockId in regionBlockIds) {
    if (!matchesByBlockId.containsKey(blockId)) {
      return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
    }
  }
  for (final matches in matchesByBlockId.values) {
    if (matches.length != 1) {
      return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
    }
  }

  if (regionBlockIds.toSet().length != regionBlockIds.length) {
    return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
  }

  if (encounterOrder.isEmpty) {
    return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
  }
  final declaredPages = regionPageIndices.toSet();
  final matchedPages =
      encounterOrder.map((sourceRef) => sourceRef.start!.pageNumber).toSet();
  if (!_setEquals(declaredPages, matchedPages)) {
    return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
  }
  if (encounterOrder.length == 1) {
    return (
      ref: encounterOrder.single,
      isCoarse: false,
      matchedParts: matchedParts,
    );
  }

  final ordered = [...encounterOrder]..sort(_compareBlockRefs);
  for (var index = 1; index < ordered.length; index++) {
    if (_compareBlockRefs(ordered[index - 1], ordered[index]) == 0) {
      return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
    }
  }

  try {
    final range = SourceRef.range(
      sourceId: documentRef.sourceId,
      displayLabel: documentRef.displayLabel,
      start: ordered.first.start!,
      end: ordered.last.start!,
    );
    return (ref: range, isCoarse: true, matchedParts: matchedParts);
  } on FormatException {
    return (ref: documentRef, isCoarse: true, matchedParts: matchedParts);
  }
}

bool _setEquals<T>(Set<T> left, Set<T> right) {
  return left.length == right.length && left.containsAll(right);
}

int _compareBlockRefs(SourceRef left, SourceRef right) {
  final leftPoint = left.start!;
  final rightPoint = right.start!;
  final pageComparison = leftPoint.pageNumber.compareTo(rightPoint.pageNumber);
  if (pageComparison != 0) return pageComparison;
  return leftPoint.readingOrder!.compareTo(rightPoint.readingOrder!);
}

String _mapOcrDiagnostic(String diagnostic) {
  if (diagnostic.startsWith('reference_answer_pattern:')) {
    return 'reference_answer_pattern';
  }
  if (_ocrKnownDiagnostics.contains(diagnostic)) return diagnostic;
  if (diagnostic.startsWith('kind_declared_from_section:')) {
    return 'kind_declared_from_section';
  }
  if (diagnostic.startsWith('kind_inferred_from_question_number_range:')) {
    return 'kind_inferred_from_question_number_range';
  }
  return 'legacy_region_diagnostic';
}

ImportIssueSeverity _severityForOcrDiagnostic(String code) {
  return switch (code) {
    'reference_answer_attached' ||
    'reference_answer_confirmed' ||
    'reference_answer_pattern' =>
      ImportIssueSeverity.info,
    _ => ImportIssueSeverity.warning,
  };
}

ImportIssueField? _fieldForOcrDiagnostic(String code) {
  return switch (code) {
    'missing_stem' => ImportIssueField.stem,
    'missing_answer' ||
    'reference_answer_attached' ||
    'reference_answer_confirmed' ||
    'reference_answer_conflict' ||
    'reference_answer_duplicate_conflict' ||
    'reference_answer_pattern' =>
      ImportIssueField.answer,
    'contains_formula_block' || 'contains_table_block' => ImportIssueField.stem,
    'cross_page_region' => ImportIssueField.source,
    'kind_declared_from_section' ||
    'kind_inferred_from_question_number_range' =>
      ImportIssueField.question,
    _ => null,
  };
}

QuestionRegionKindHint _mapKind(TextQuestionKind kind) {
  return switch (kind) {
    TextQuestionKind.choice => QuestionRegionKindHint.singleChoice,
    TextQuestionKind.multiChoice => QuestionRegionKindHint.multipleChoice,
    TextQuestionKind.trueFalse => QuestionRegionKindHint.trueFalse,
    TextQuestionKind.fillBlank => QuestionRegionKindHint.fillBlank,
    TextQuestionKind.subjective => QuestionRegionKindHint.shortAnswer,
    TextQuestionKind.unknown => QuestionRegionKindHint.unknown,
  };
}
