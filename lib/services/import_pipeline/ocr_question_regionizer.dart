import 'ocr_document.dart';
import 'text_question_region.dart';

enum OcrRegionField { stem, answer, explanation }

class OcrQuestionNumberKindRange {
  const OcrQuestionNumberKindRange({
    required this.start,
    required this.end,
    required this.kind,
  });

  final int start;
  final int? end;
  final TextQuestionKind kind;

  bool contains(int number) {
    return number >= start && (end == null || number <= end!);
  }
}

class OcrQuestionRegionizerResult {
  const OcrQuestionRegionizerResult({
    required this.regions,
    required this.diagnostics,
  });

  final List<OcrQuestionRegion> regions;
  final Map<String, dynamic> diagnostics;
}

class OcrQuestionRegion {
  const OcrQuestionRegion({
    required this.number,
    required this.stemParts,
    required this.answerParts,
    required this.explanationParts,
    required this.sourcePageIndices,
    required this.sourceBlockIds,
    required this.diagnostics,
    this.declaredKind = TextQuestionKind.unknown,
  });

  final int number;
  final List<String> stemParts;
  final List<String> answerParts;
  final List<String> explanationParts;
  final List<int> sourcePageIndices;
  final List<String> sourceBlockIds;
  final List<String> diagnostics;
  final TextQuestionKind declaredKind;

  String get stemText => _joinParts(stemParts);
  String get answerText => _joinParts(answerParts);
  String get explanationText => _joinParts(explanationParts);

  bool get isCrossPage => sourcePageIndices.toSet().length > 1;

  bool get isRisky =>
      diagnostics.isNotEmpty ||
      stemText.trim().isEmpty ||
      (answerText.trim().isEmpty && explanationText.trim().isEmpty);

  String get rawText {
    final buffer = StringBuffer();
    buffer.writeln('$number ${stemText.trim()}');
    if (answerText.trim().isNotEmpty) {
      buffer.writeln('答案: ${answerText.trim()}');
    }
    if (explanationText.trim().isNotEmpty) {
      buffer.writeln('解析: ${explanationText.trim()}');
    }
    return buffer.toString().trim();
  }

  TextQuestionRegion toTextQuestionRegion() {
    final kind = effectiveKind;
    final repairText = _repairTextForKind(kind);
    return TextQuestionRegion(
      number: number,
      rawText: repairText,
      startOffset: 0,
      endOffset: repairText.length,
      answerText: answerText.trim().isEmpty ? null : answerText.trim(),
      kind: kind,
      health: isRisky ? RegionHealth.repairable : RegionHealth.clean,
      diagnostics: diagnostics,
    );
  }

  TextQuestionKind get effectiveKind {
    if (declaredKind != TextQuestionKind.unknown) return declaredKind;
    return _detectKind();
  }

  TextQuestionKind _detectKind() {
    final text = stemText;
    final optionCount =
        RegExp(r'(^|\n)\s*(?:\([A-D]\)|[A-D][\.、．])', multiLine: true)
            .allMatches(text)
            .length;
    if (optionCount >= 2) return TextQuestionKind.choice;
    if (RegExp(r'[_＿—–－﹏]{2,}|（\s*）|\(\s*\)|填空|应填').hasMatch(text)) {
      return TextQuestionKind.fillBlank;
    }
    return TextQuestionKind.subjective;
  }

  String _repairTextForKind(TextQuestionKind kind) {
    final buffer = StringBuffer();
    buffer.writeln('$number ${stemText.trim()}');
    if (answerText.trim().isNotEmpty) {
      buffer.writeln('答案: ${answerText.trim()}');
    }
    final shouldExposeExplanation = kind == TextQuestionKind.subjective ||
        (answerText.trim().isEmpty && explanationText.trim().isNotEmpty);
    if (shouldExposeExplanation && explanationText.trim().isNotEmpty) {
      buffer.writeln('解析: ${explanationText.trim()}');
    }
    return buffer.toString().trim();
  }

  static String _joinParts(List<String> parts) {
    return parts
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('\n')
        .trim();
  }
}

class OcrQuestionRegionizer {
  const OcrQuestionRegionizer({
    this.questionNumberKindRanges = const [],
  });

  final List<OcrQuestionNumberKindRange> questionNumberKindRanges;

  static final RegExp _lineQuestionRegex = RegExp(
    r'(^|\n)\s*(?:第\s*)?(\d{1,3})\s*(?:题|[\.、．])?\s*(?=(?:设|已知|若|求|证明|计算|下列|关于|函数|随机|令|讨论|判断|选择|填空|设随机|设函数|[（(]?[ⅠⅡⅢIVX]))',
    multiLine: true,
  );

  static final RegExp _answerLabelRegex = RegExp(
    r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*',
    caseSensitive: false,
  );

  static final RegExp _explanationLabelRegex = RegExp(
    r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*',
    caseSensitive: false,
  );

  static final RegExp _sectionHeadingRegex = RegExp(
    r'(^|\n)\s*#{0,6}\s*(?:第\s*)?[一二三四五六七八九十]+[、,，.．]?\s*(?:单项选择题|选择题|填空题|解答题|证明题|计算题)\s*(?=\n|$)',
    multiLine: true,
  );

  static final RegExp _numberedFieldRegex = RegExp(
    r'^\s*(?:第\s*)?(\d{1,3})\s*(?:题|[\.、．])?\s*(答案解析|标准答案|参考答案|答案|解析|分析|详解|解|证明)\s*[:：]?\s*([\s\S]*)$',
    caseSensitive: false,
  );

  OcrQuestionRegionizerResult regionize(OcrDocument document) {
    final units = <_OcrTextUnit>[];
    for (final block in document.flattenedBlocks) {
      units.addAll(_splitBlock(block));
    }

    final regions = <OcrQuestionRegion>[];
    final ignoredBlocks = <String>[];
    final rejectedQuestionStarts = <String>[];
    final numberedFieldCandidates = <_NumberedFieldCandidate>[];
    final sectionHeadings = <String>[];
    var splitCount = 0;

    _MutableRegion? current;
    var currentField = OcrRegionField.stem;
    var currentSectionKind = TextQuestionKind.unknown;

    void finishCurrent() {
      if (current == null) return;
      final region = current!.build();
      if (region.stemText.trim().isNotEmpty ||
          region.answerText.trim().isNotEmpty ||
          region.explanationText.trim().isNotEmpty) {
        regions.add(region);
      }
      current = null;
      currentField = OcrRegionField.stem;
    }

    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit.wasSplit) splitCount++;

      final text = _normalizeText(unit.text);
      if (text.isEmpty) continue;

      final sectionKind = _readSectionHeadingKind(text);
      if (sectionKind != null) {
        finishCurrent();
        currentSectionKind = sectionKind;
        sectionHeadings.add(text);
        ignoredBlocks.add(unit.block.blockId);
        continue;
      }

      final numberedField = _readNumberedFieldTransition(text);
      if (numberedField != null) {
        if (current != null && current!.number == numberedField.number) {
          current!.addSource(unit.block);
          current!.addPart(numberedField.field, numberedField.remainingText);
          current!.diagnostics.add('attached_numbered_field_in_current_region');
        } else {
          numberedFieldCandidates.add(
            _NumberedFieldCandidate(
              number: numberedField.number,
              field: numberedField.field,
              text: numberedField.remainingText,
              block: unit.block,
            ),
          );
        }
        continue;
      }

      final questionNumber = _detectQuestionNumber(
        text,
        nextText: i + 1 < units.length ? units[i + 1].text : null,
      );

      if (questionNumber != null) {
        if (_looksLikeOption(text)) {
          rejectedQuestionStarts.add(unit.block.blockId);
        } else {
          finishCurrent();
          final kindInfo = _kindForQuestionNumber(
            questionNumber,
            currentSectionKind: currentSectionKind,
          );
          current = _MutableRegion(
            questionNumber,
            declaredKind: kindInfo.kind,
            initialDiagnostics: kindInfo.diagnostics,
          );
          currentField = OcrRegionField.stem;
          current!.addSource(unit.block);
          final remaining = _stripQuestionPrefix(text);
          if (remaining.isNotEmpty && remaining != questionNumber.toString()) {
            current!.addPart(currentField, remaining);
          }
          continue;
        }
      }

      if (current == null) {
        ignoredBlocks.add(unit.block.blockId);
        continue;
      }

      current!.addSource(unit.block);
      final transition = _readFieldTransition(text);
      if (transition != null) {
        currentField = transition.field;
        if (transition.remainingText.isNotEmpty) {
          current!.addPart(currentField, transition.remainingText);
        }
      } else {
        current!.addPart(currentField, text);
      }
    }

    finishCurrent();

    final patchedRegions = _attachNumberedFieldCandidates(
      regions,
      numberedFieldCandidates,
    );

    final acceptedNumbers =
        patchedRegions.map((region) => region.number).toList();
    final missingNumbers = _missingNumbers(acceptedNumbers);

    return OcrQuestionRegionizerResult(
      regions: patchedRegions,
      diagnostics: {
        'sourceName': document.sourceName,
        'unitCount': units.length,
        'regionCount': patchedRegions.length,
        'ignoredBlockCount': ignoredBlocks.length,
        'ignoredBlockIds': ignoredBlocks.take(40).toList(),
        'rejectedQuestionStarts': rejectedQuestionStarts,
        'numberedFieldCandidateCount': numberedFieldCandidates.length,
        'sectionHeadingCount': sectionHeadings.length,
        if (sectionHeadings.isNotEmpty)
          'sectionHeadings': sectionHeadings.take(20).toList(),
        'splitUnitCount': splitCount,
        'acceptedNumbers': acceptedNumbers,
        'missingNumbers': missingNumbers,
      },
    );
  }

  List<_OcrTextUnit> _splitBlock(OcrBlock block) {
    final text = block.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final boundaries = <int>{0, text.length};

    for (final match in _lineQuestionRegex.allMatches(text)) {
      final start = _contentStart(match);
      if (start > 0 && start < text.length) {
        boundaries.add(start);
      }
    }

    for (final match in _sectionHeadingRegex.allMatches(text)) {
      final start = _contentStart(match);
      if (start >= 0 && start < text.length) {
        boundaries.add(start);
      }
      if (match.end > 0 && match.end < text.length) {
        boundaries.add(match.end);
      }
    }

    final sortedBoundaries = boundaries.toList()..sort();
    if (sortedBoundaries.length <= 2) {
      return [_OcrTextUnit(block: block, text: text, wasSplit: false)];
    }

    final units = <_OcrTextUnit>[];
    for (var i = 0; i < sortedBoundaries.length - 1; i++) {
      final start = sortedBoundaries[i];
      final end = sortedBoundaries[i + 1];
      if (end <= start) continue;
      final part = text.substring(start, end).trim();
      if (part.isNotEmpty) {
        units.add(
          _OcrTextUnit(
            block: block.copyWith(
                blockId: '${block.blockId}#s${units.length + 1}'),
            text: part,
            wasSplit: true,
          ),
        );
      }
    }

    return units;
  }

  int _contentStart(RegExpMatch match) {
    final prefix = match.group(1) ?? '';
    return match.start + prefix.length;
  }

  int? _detectQuestionNumber(String text, {String? nextText}) {
    final direct = _lineQuestionRegex.firstMatch(text);
    if (direct != null && direct.start == 0) {
      return int.tryParse(direct.group(2) ?? '');
    }

    final numericOnly = RegExp(r'^\s*(\d{1,3})\s*$').firstMatch(text);
    if (numericOnly != null &&
        nextText != null &&
        _looksLikeStemStart(nextText)) {
      return int.tryParse(numericOnly.group(1) ?? '');
    }

    return null;
  }

  String _stripQuestionPrefix(String text) {
    return text
        .replaceFirst(
          RegExp(r'^\s*(?:第\s*)?\d{1,3}\s*(?:题|[\.、．])?\s*'),
          '',
        )
        .trim();
  }

  _FieldTransition? _readFieldTransition(String text) {
    final answerMatch = _answerLabelRegex.firstMatch(text);
    if (answerMatch != null) {
      return _FieldTransition(
        OcrRegionField.answer,
        text.substring(answerMatch.end).trim(),
      );
    }

    final explanationMatch = _explanationLabelRegex.firstMatch(text);
    if (explanationMatch != null) {
      return _FieldTransition(
        OcrRegionField.explanation,
        text.substring(explanationMatch.end).trim(),
      );
    }

    return null;
  }

  _NumberedFieldTransition? _readNumberedFieldTransition(String text) {
    final match = _numberedFieldRegex.firstMatch(text);
    if (match == null) return null;

    final number = int.tryParse(match.group(1) ?? '');
    if (number == null) return null;

    final label = match.group(2) ?? '';
    final field = _labelToField(label);
    final remaining = (match.group(3) ?? '').trim();
    if (remaining.isEmpty) return null;

    return _NumberedFieldTransition(
      number: number,
      field: field,
      remainingText: remaining,
    );
  }

  OcrRegionField _labelToField(String label) {
    if (RegExp(r'答案|标准答案|参考答案').hasMatch(label)) {
      return OcrRegionField.answer;
    }
    return OcrRegionField.explanation;
  }

  String _normalizeText(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  TextQuestionKind? _readSectionHeadingKind(String text) {
    final normalized = text
        .trim()
        .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
        .replaceFirst(RegExp(r'^第\s*'), '')
        .replaceAll(RegExp(r'\s+'), '');
    final match = RegExp(r'^[一二三四五六七八九十]+[、,，.．]?(单项选择题|选择题|填空题|解答题|证明题|计算题)$')
        .firstMatch(normalized);
    if (match == null) return null;

    final label = match.group(1) ?? '';
    if (label.contains('选择')) return TextQuestionKind.choice;
    if (label.contains('填空')) return TextQuestionKind.fillBlank;
    return TextQuestionKind.subjective;
  }

  bool _looksLikeOption(String text) {
    return RegExp(r'^\s*(?:\([A-D]\)|[A-D][\.、．])').hasMatch(text);
  }

  bool _looksLikeStemStart(String text) {
    return RegExp(r'^\s*(?:设|已知|若|求|证明|计算|下列|关于|函数|随机|令|讨论|判断|选择|填空|设随机|设函数)')
        .hasMatch(text);
  }

  List<int> _missingNumbers(List<int> acceptedNumbers) {
    if (acceptedNumbers.length < 2) return const [];
    final sorted = acceptedNumbers.toSet().toList()..sort();
    final missing = <int>[];
    for (var i = sorted.first; i <= sorted.last; i++) {
      if (!sorted.contains(i)) missing.add(i);
    }
    return missing;
  }

  _KindInfo _kindForQuestionNumber(
    int questionNumber, {
    required TextQuestionKind currentSectionKind,
  }) {
    if (currentSectionKind != TextQuestionKind.unknown) {
      return _KindInfo(
        currentSectionKind,
        ['kind_declared_from_section:${currentSectionKind.name}'],
      );
    }

    for (final range in questionNumberKindRanges) {
      if (range.contains(questionNumber)) {
        return _KindInfo(
          range.kind,
          ['kind_inferred_from_question_number_range:${range.kind.name}'],
        );
      }
    }

    return const _KindInfo(TextQuestionKind.unknown, []);
  }

  List<OcrQuestionRegion> _attachNumberedFieldCandidates(
    List<OcrQuestionRegion> regions,
    List<_NumberedFieldCandidate> candidates,
  ) {
    if (regions.isEmpty || candidates.isEmpty) return regions;

    final byNumber = <int, List<_NumberedFieldCandidate>>{};
    for (final candidate in candidates) {
      byNumber.putIfAbsent(candidate.number, () => []).add(candidate);
    }

    return regions.map((region) {
      final matches = byNumber[region.number];
      if (matches == null || matches.isEmpty) return region;

      final answerParts = [...region.answerParts];
      final explanationParts = [...region.explanationParts];
      final pageIndices = {...region.sourcePageIndices};
      final blockIds = {...region.sourceBlockIds};
      final diagnostics = [...region.diagnostics];

      for (final candidate in matches) {
        if (candidate.field == OcrRegionField.answer) {
          answerParts.add(candidate.text);
        } else {
          explanationParts.add(candidate.text);
        }
        pageIndices.add(candidate.block.pageIndex);
        blockIds.add(candidate.block.blockId);
      }
      diagnostics.add('attached_numbered_field_candidate');

      final sortedPages = pageIndices.toList()..sort();
      return OcrQuestionRegion(
        number: region.number,
        stemParts: region.stemParts,
        answerParts: List.unmodifiable(answerParts),
        explanationParts: List.unmodifiable(explanationParts),
        sourcePageIndices: List.unmodifiable(sortedPages),
        sourceBlockIds: List.unmodifiable(blockIds),
        diagnostics: List.unmodifiable(diagnostics.toSet()),
        declaredKind: region.declaredKind,
      );
    }).toList(growable: false);
  }
}

class _MutableRegion {
  _MutableRegion(
    this.number, {
    this.declaredKind = TextQuestionKind.unknown,
    List<String> initialDiagnostics = const [],
  }) {
    diagnostics.addAll(initialDiagnostics);
  }

  final int number;
  final TextQuestionKind declaredKind;
  final stemParts = <String>[];
  final answerParts = <String>[];
  final explanationParts = <String>[];
  final sourcePageIndices = <int>{};
  final sourceBlockIds = <String>{};
  final diagnostics = <String>[];

  void addSource(OcrBlock block) {
    sourcePageIndices.add(block.pageIndex);
    sourceBlockIds.add(block.blockId);
    if (block.type == 'formula') {
      diagnostics.add('contains_formula_block');
    }
    if (block.type == 'table') {
      diagnostics.add('contains_table_block');
    }
  }

  void addPart(OcrRegionField field, String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    switch (field) {
      case OcrRegionField.stem:
        stemParts.add(normalized);
      case OcrRegionField.answer:
        answerParts.add(normalized);
      case OcrRegionField.explanation:
        explanationParts.add(normalized);
    }
  }

  OcrQuestionRegion build() {
    final sortedPages = sourcePageIndices.toList()..sort();
    if (sortedPages.length > 1) diagnostics.add('cross_page_region');
    if (stemParts.isEmpty) diagnostics.add('missing_stem');
    if (answerParts.isEmpty) diagnostics.add('missing_answer');

    return OcrQuestionRegion(
      number: number,
      stemParts: List.unmodifiable(stemParts),
      answerParts: List.unmodifiable(answerParts),
      explanationParts: List.unmodifiable(explanationParts),
      sourcePageIndices: List.unmodifiable(sortedPages),
      sourceBlockIds: List.unmodifiable(sourceBlockIds),
      diagnostics: List.unmodifiable(diagnostics.toSet()),
      declaredKind: declaredKind,
    );
  }
}

class _OcrTextUnit {
  const _OcrTextUnit({
    required this.block,
    required this.text,
    required this.wasSplit,
  });

  final OcrBlock block;
  final String text;
  final bool wasSplit;
}

class _FieldTransition {
  const _FieldTransition(this.field, this.remainingText);

  final OcrRegionField field;
  final String remainingText;
}

class _NumberedFieldTransition {
  const _NumberedFieldTransition({
    required this.number,
    required this.field,
    required this.remainingText,
  });

  final int number;
  final OcrRegionField field;
  final String remainingText;
}

class _NumberedFieldCandidate {
  const _NumberedFieldCandidate({
    required this.number,
    required this.field,
    required this.text,
    required this.block,
  });

  final int number;
  final OcrRegionField field;
  final String text;
  final OcrBlock block;
}

class _KindInfo {
  const _KindInfo(this.kind, this.diagnostics);

  final TextQuestionKind kind;
  final List<String> diagnostics;
}
