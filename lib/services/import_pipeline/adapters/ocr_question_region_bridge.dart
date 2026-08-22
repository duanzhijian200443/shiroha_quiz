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
      region,
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
  _Provenance provenance,
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

  if (region.ownedSources.isNotEmpty) {
    final fragments = <QuestionRegionFragment>[];
    final ownedCounts = <QuestionRegionField, int>{};
    var typedDegraded = provenance.ambiguousBlockIds.isNotEmpty;

    for (final owned in region.ownedSources) {
      final part = provenance.uniquePartByBlockId[owned.blockId];
      if (part == null) {
        typedDegraded = true;
        continue;
      }
      final field = _mapField(owned.field);
      ownedCounts[field] = (ownedCounts[field] ?? 0) + 1;
      fragments.add(
        QuestionRegionFragment(
          field: field,
          part: part,
          slice: _sliceForOwnership(part, owned),
        ),
      );
    }

    final expectedCounts = <QuestionRegionField, int>{};
    for (final entry in entries) {
      expectedCounts[entry.field] = (expectedCounts[entry.field] ?? 0) + 1;
    }
    final syntheticCounts = <QuestionRegionField, int>{};
    for (final field in QuestionRegionField.values) {
      final expected = expectedCounts[field] ?? 0;
      final ownedCount = ownedCounts[field] ?? 0;
      syntheticCounts[field] =
          expected > ownedCount ? expected - ownedCount : 0;
    }
    for (final entry in entries) {
      final remaining = syntheticCounts[entry.field] ?? 0;
      if (remaining == 0) continue;
      syntheticCounts[entry.field] = remaining - 1;
      fragments.add(_fragment(entry.field, entry.text, provenance.ref));
    }

    return (typedDegraded: typedDegraded, fragments: fragments);
  }

  final hasStructuralPart = provenance.matchedParts.any(_hasTypedStructure);
  if (hasStructuralPart) {
    final fragments = <QuestionRegionFragment>[];
    for (var index = 0; index < provenance.matchedParts.length; index++) {
      final field = entries.isEmpty
          ? QuestionRegionField.stem
          : entries[index < entries.length ? index : entries.length - 1].field;
      fragments.add(
        QuestionRegionFragment(
          field: field,
          part: provenance.matchedParts[index],
        ),
      );
    }
    for (var index = provenance.matchedParts.length;
        index < entries.length;
        index++) {
      fragments.add(
          _fragment(entries[index].field, entries[index].text, provenance.ref));
    }
    return (
      typedDegraded: !provenance.canBindLegacyParts ||
          provenance.ambiguousBlockIds.isNotEmpty,
      fragments: fragments,
    );
  }

  final canPairByEncounter = provenance.canBindLegacyParts &&
      provenance.matchedParts.length == entries.length;
  if (canPairByEncounter) {
    return (
      typedDegraded: false,
      fragments: [
        for (var index = 0; index < entries.length; index++)
          QuestionRegionFragment(
            field: entries[index].field,
            part: provenance.matchedParts[index],
          ),
      ],
    );
  }

  return (
    typedDegraded: provenance.matchedParts.any(_hasTypedStructure) ||
        provenance.ambiguousBlockIds.isNotEmpty,
    fragments: [
      for (final entry in entries)
        _fragment(entry.field, entry.text, provenance.ref),
    ],
  );
}

bool _hasTypedStructure(SourcePart part) {
  return switch (part) {
    SourceAssetPart() || SourceTablePart() || UnsupportedSourcePart() => true,
    SourceContentPart(:final content, :final role) =>
      role == SourceContentRole.formula ||
          content.nodes.any((node) => node is! TextNode),
  };
}

QuestionRegionField _mapField(OcrRegionField field) {
  return switch (field) {
    OcrRegionField.stem => QuestionRegionField.stem,
    OcrRegionField.answer => QuestionRegionField.answer,
    OcrRegionField.explanation => QuestionRegionField.explanation,
  };
}

SourceSlice? _sliceForOwnership(
  SourcePart part,
  OcrQuestionRegionSource owned,
) {
  if (part is! SourceContentPart) {
    return null;
  }
  if (part.content.nodes.length != 1 ||
      part.content.nodes.single is! TextNode) {
    return null;
  }
  final text = (part.content.nodes.single as TextNode).text;
  var start = owned.startCodeUnitOffset;
  var end = owned.endCodeUnitOffset;
  if (start == null || end == null) {
    final boundaryText = owned.text?.trim();
    if (boundaryText == null || boundaryText.isEmpty) return null;
    final matches = RegExp(RegExp.escape(boundaryText)).allMatches(text);
    final match = matches.length == 1 ? matches.single : null;
    if (match == null) return null;
    start = match.start;
    end = match.end;
  }
  if (start == 0 && end == text.length) return null;
  try {
    return SourceSlice(
      startNodeIndex: 0,
      startCodeUnitOffset: start,
      endNodeIndex: end == text.length ? 1 : 0,
      endCodeUnitOffset: end == text.length ? 0 : end,
    );
  } on FormatException {
    return null;
  }
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

final class _Provenance {
  const _Provenance({
    required this.ref,
    required this.isCoarse,
    required this.matchedParts,
    required this.uniquePartByBlockId,
    required this.ambiguousBlockIds,
    required this.canBindLegacyParts,
  });

  final SourceRef ref;
  final bool isCoarse;
  final List<SourcePart> matchedParts;
  final Map<String, SourcePart> uniquePartByBlockId;
  final Set<String> ambiguousBlockIds;
  final bool canBindLegacyParts;
}

_Provenance _resolveProvenance(
  SourceDocument document,
  OcrQuestionRegion region,
  List<int> regionPageIndices,
) {
  final documentRef = document.documentRef;
  final ownedBlockIds = region.ownedSources
      .map((source) => source.blockId)
      .toList(growable: false);
  final regionBlockIds = ownedBlockIds.isNotEmpty
      ? ownedBlockIds
      : List<String>.unmodifiable(region.sourceBlockIds);
  final requested = regionBlockIds.toSet();
  final partsByBlockId = <String, List<SourcePart>>{};

  for (final part in document.parts) {
    final blockId = part.sourceRef.start?.blockId;
    if (blockId == null || !requested.contains(blockId)) continue;
    partsByBlockId.putIfAbsent(blockId, () => <SourcePart>[]).add(part);
  }

  final uniquePartByBlockId = <String, SourcePart>{};
  final ambiguousBlockIds = <String>{};
  for (final blockId in requested) {
    final matches = partsByBlockId[blockId] ?? const <SourcePart>[];
    if (matches.length == 1) {
      uniquePartByBlockId[blockId] = matches.single;
    } else {
      ambiguousBlockIds.add(blockId);
    }
  }

  final matchedParts = <SourcePart>[];
  if (region.ownedSources.isNotEmpty) {
    for (final owned in region.ownedSources) {
      final part = uniquePartByBlockId[owned.blockId];
      if (part != null) matchedParts.add(part);
    }
  } else {
    final orderedIds = [...regionBlockIds];
    orderedIds.sort((left, right) {
      final leftPart = uniquePartByBlockId[left];
      final rightPart = uniquePartByBlockId[right];
      if (leftPart == null && rightPart == null) return 0;
      if (leftPart == null) return 1;
      if (rightPart == null) return -1;
      return _compareBlockRefs(leftPart.sourceRef, rightPart.sourceRef);
    });
    for (final blockId in orderedIds) {
      final part = uniquePartByBlockId[blockId];
      if (part != null) matchedParts.add(part);
    }
  }

  var isCoarse = ambiguousBlockIds.isNotEmpty;
  if (region.ownedSources.isEmpty &&
      regionBlockIds.toSet().length != regionBlockIds.length) {
    isCoarse = true;
  }

  final refsByBlockId = <String, SourceRef>{};
  for (final blockId in regionBlockIds) {
    final part = uniquePartByBlockId[blockId];
    if (part == null) {
      isCoarse = true;
      continue;
    }
    refsByBlockId[blockId] = part.sourceRef;
  }

  final encounterOrder = <SourceRef>[];
  final seenRefs = <SourceRef>{};
  for (final blockId in regionBlockIds) {
    final ref = refsByBlockId[blockId];
    if (ref != null && seenRefs.add(ref)) encounterOrder.add(ref);
  }
  if (encounterOrder.isEmpty) {
    return _Provenance(
      ref: documentRef,
      isCoarse: true,
      matchedParts: matchedParts,
      uniquePartByBlockId: uniquePartByBlockId,
      ambiguousBlockIds: ambiguousBlockIds,
      canBindLegacyParts: false,
    );
  }

  final declaredPages = regionPageIndices.toSet();
  final matchedPages =
      encounterOrder.map((sourceRef) => sourceRef.start!.pageNumber).toSet();
  if (!_setEquals(declaredPages, matchedPages)) isCoarse = true;

  if (encounterOrder.length == 1) {
    return _Provenance(
      ref: isCoarse ? documentRef : encounterOrder.single,
      isCoarse: isCoarse,
      matchedParts: matchedParts,
      uniquePartByBlockId: uniquePartByBlockId,
      ambiguousBlockIds: ambiguousBlockIds,
      canBindLegacyParts: !isCoarse,
    );
  }

  final ordered = [...encounterOrder]..sort(_compareBlockRefs);
  for (var index = 1; index < ordered.length; index++) {
    if (_compareBlockRefs(ordered[index - 1], ordered[index]) == 0) {
      isCoarse = true;
    }
  }
  if (isCoarse) {
    return _Provenance(
      ref: documentRef,
      isCoarse: true,
      matchedParts: matchedParts,
      uniquePartByBlockId: uniquePartByBlockId,
      ambiguousBlockIds: ambiguousBlockIds,
      canBindLegacyParts: false,
    );
  }

  try {
    final range = SourceRef.range(
      sourceId: documentRef.sourceId,
      displayLabel: documentRef.displayLabel,
      start: ordered.first.start!,
      end: ordered.last.start!,
    );
    return _Provenance(
      ref: range,
      isCoarse: true,
      matchedParts: matchedParts,
      uniquePartByBlockId: uniquePartByBlockId,
      ambiguousBlockIds: ambiguousBlockIds,
      canBindLegacyParts: true,
    );
  } on FormatException {
    return _Provenance(
      ref: documentRef,
      isCoarse: true,
      matchedParts: matchedParts,
      uniquePartByBlockId: uniquePartByBlockId,
      ambiguousBlockIds: ambiguousBlockIds,
      canBindLegacyParts: false,
    );
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
