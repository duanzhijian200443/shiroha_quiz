import 'ocr_document.dart';
import 'reference_answer_section.dart';
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

  static final RegExp _explicitQuestionMarkerRegex = RegExp(
    r'^\s*([0-9０-９]{1,3})\s*([\.、．])\s*([\s\S]*)$',
  );

  static final RegExp _bareQuestionMarkerRegex = RegExp(
    r'^\s*(?:第\s*)?([0-9０-９]{1,3})(?:\s*题\s*|\s+)([\s\S]+)$',
  );

  static final RegExp _standaloneQuestionMarkerRegex = RegExp(
    r'^\s*([0-9０-９]{1,3})\s*[\.、．]\s*$',
  );

  static final RegExp _numericOnlyQuestionMarkerRegex = RegExp(
    r'^\s*([0-9０-９]{1,3})\s*$',
  );

  static final RegExp _leadingDigitProbeRegex = RegExp(
    r'^\s*(?:第\s*)?([0-9０-９]{1,3})(?![0-9０-９])([\s\S]*)$',
  );

  static final RegExp _parenthesizedArabicMarkerRegex = RegExp(
    r'^\s*(?:（([0-9０-９]{1,3})）|\(([0-9０-９]{1,3})\))\s*([\s\S]*)$',
  );

  static final RegExp _romanSubquestionRegex = RegExp(
    r'^\s*(?:（[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+）|\([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+\))',
  );

  static final RegExp _answerLabelRegex = RegExp(
    r'^\s*(?:标准答案|参考答案|答案)\s*[:：]?\s*',
    caseSensitive: false,
  );

  static final RegExp _explanationLabelRegex = RegExp(
    r'^\s*(?:答案解析|解析|分析|详解|解|证明)\s*[:：]?\s*',
    caseSensitive: false,
  );

  static final RegExp _numberedFieldRegex = RegExp(
    r'^\s*(?:第\s*)?(\d{1,3})\s*(?:题|[\.、．])?\s*(答案解析|标准答案|参考答案|答案|解析|分析|详解|解|证明)\s*[:：]?\s*([\s\S]*)$',
    caseSensitive: false,
  );

  static final RegExp _markdownQuotePrefixRegex = RegExp(
    r'^[ \t]{0,3}>[ \t]+',
  );

  static final RegExp _markdownHeadingPrefixRegex = RegExp(
    r'^[ \t]{0,3}#{1,6}[ \t]+',
  );

  static final RegExp _sectionQuestionCountRegex = RegExp(
    r'(?:本题\s*)?共\s*([0-9０-９]{1,3})\s*(?:小题|题)',
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
    final sections = <_SectionHeadingInfo>[];
    final officialSections = <_SectionHeadingInfo>[];
    final pageCandidateCounts = <String, int>{};
    var splitCount = 0;
    var markdownPrefixedCandidateCount = 0;
    var blockStartCandidateCount = 0;
    var internalLineCandidateCount = 0;
    var parenthesizedArabicCandidateCount = 0;
    var parenthesizedArabicAcceptedCount = 0;
    var parenthesizedArabicRejectedCount = 0;
    var romanSubquestionCount = 0;
    var sequenceAcceptedCount = 0;
    var sequenceRejectedCount = 0;

    _MutableRegion? current;
    var currentField = OcrRegionField.stem;
    var currentSectionKind = TextQuestionKind.unknown;
    final confirmedAcceptedNumbers = <int>[];
    var highestOfficialSectionOrdinal = 0;
    var currentSectionIsReference = false;
    var referenceSectionDetected = false;
    var referenceSectionCandidateCount = 0;

    final questionCandidateTrace = <Map<String, dynamic>>[];
    var questionCandidateTraceTruncated = false;
    final markerProbeTrace = <Map<String, dynamic>>[];
    var markerProbeTraceTruncated = false;
    var currentSectionIndex = 0;

    void addTrace({
      required int number,
      required _OcrTextUnit unit,
      required String markerKind,
      required String decision,
      required String reason,
      required int? previousAcceptedNumber,
      required int sectionIndex,
    }) {
      if (questionCandidateTrace.length >= 100) {
        questionCandidateTraceTruncated = true;
        return;
      }
      questionCandidateTrace.add({
        'number': number,
        'pageIndex': unit.block.pageIndex,
        'markerKind': markerKind,
        'decision': decision,
        'reason': reason,
        'previousAcceptedNumber': previousAcceptedNumber,
        'sectionIndex': sectionIndex,
        'blockOrder': unit.block.readingOrder,
      });
    }

    void addMarkerProbe({
      required _OcrTextUnit unit,
      required String text,
      required bool startsAtBlockStart,
      required String probeReason,
      bool onlyUnrecognizedShape = false,
    }) {
      if (currentSectionKind == TextQuestionKind.unknown ||
          currentSectionIsReference) {
        return;
      }
      final probe = _readMarkerProbe(text);
      if (probe == null ||
          (onlyUnrecognizedShape &&
              probe.markerShape != 'digit_prefix_unrecognized')) {
        return;
      }
      if (markerProbeTrace.length >= 100) {
        markerProbeTraceTruncated = true;
        return;
      }
      markerProbeTrace.add({
        'pageIndex': unit.block.pageIndex,
        'blockOrder': unit.block.readingOrder,
        'sectionIndex': currentSectionIndex,
        'startsAtBlockStart': startsAtBlockStart,
        'startsAtLineBoundary': true,
        'markerShape': probe.markerShape,
        'parsedNumber': probe.parsedNumber,
        'followerClass': probe.followerClass,
        'probeReason': probeReason,
      });
    }

    void addUnmatchedInternalMarkerProbes(_OcrTextUnit unit) {
      final lines =
          unit.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
      for (var lineIndex = 1; lineIndex < lines.length; lineIndex++) {
        addMarkerProbe(
          unit: unit,
          text: lines[lineIndex],
          startsAtBlockStart: false,
          probeReason: 'internal_line_not_split',
        );
      }
    }

    void recordQuestionCandidate(_OcrTextUnit unit) {
      final pageKey = unit.block.pageIndex.toString();
      pageCandidateCounts[pageKey] = (pageCandidateCounts[pageKey] ?? 0) + 1;
      if (_hasLeadingMarkdownStructure(unit.text)) {
        markdownPrefixedCandidateCount++;
      }
      if (unit.startsAtBlockStart) {
        blockStartCandidateCount++;
      } else {
        internalLineCandidateCount++;
      }
    }

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

    int? previousAcceptedNumber() =>
        confirmedAcceptedNumbers.isEmpty ? null : confirmedAcceptedNumbers.last;

    String? candidateRejectionReason({
      required int number,
      required bool requiresSectionContext,
    }) {
      if (currentSectionIsReference) return 'reference_section';
      if (requiresSectionContext &&
          currentSectionKind == TextQuestionKind.unknown) {
        return 'missing_section_context';
      }

      final previous = previousAcceptedNumber();
      if (previous != null && number != previous + 1) {
        return 'sequence_mismatch';
      }
      return null;
    }

    void startQuestion({
      required int number,
      required _OcrTextUnit unit,
      required String markerKind,
      required String remainingText,
    }) {
      final previous = previousAcceptedNumber();
      finishCurrent();
      final kindInfo = _kindForQuestionNumber(
        number,
        currentSectionKind: currentSectionKind,
      );
      current = _MutableRegion(
        number,
        declaredKind: kindInfo.kind,
        initialDiagnostics: kindInfo.diagnostics,
      );
      currentField = OcrRegionField.stem;
      current!.addSource(unit.block);
      if (remainingText.isNotEmpty && remainingText != number.toString()) {
        current!.addPart(currentField, remainingText);
      }
      addTrace(
        number: number,
        unit: unit,
        markerKind: markerKind,
        decision: 'accepted',
        reason: 'valid_question_start',
        previousAcceptedNumber: previous,
        sectionIndex: currentSectionIndex,
      );
      confirmedAcceptedNumbers.add(number);
    }

    void rejectQuestionCandidate({
      required int number,
      required _OcrTextUnit unit,
      required String markerKind,
      required String reason,
      required String text,
    }) {
      if (reason == 'reference_section') {
        referenceSectionCandidateCount++;
      }
      addTrace(
        number: number,
        unit: unit,
        markerKind: markerKind,
        decision: 'rejected',
        reason: reason,
        previousAcceptedNumber: previousAcceptedNumber(),
        sectionIndex: currentSectionIndex,
      );
      if (current == null) {
        ignoredBlocks.add(unit.block.blockId);
      } else {
        current!.addSource(unit.block);
        current!.addPart(currentField, text);
      }
    }

    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit.wasSplit) splitCount++;

      final text = _normalizeText(unit.text);
      if (text.isEmpty) continue;

      if (confirmedAcceptedNumbers.isNotEmpty &&
          _isReferenceSummaryHeading(text)) {
        finishCurrent();
        currentSectionIsReference = true;
        referenceSectionDetected = true;
        ignoredBlocks.add(unit.block.blockId);
        continue;
      }

      final section = _readSectionHeading(text);
      if (section != null) {
        finishCurrent();
        currentSectionIndex++;
        if (!currentSectionIsReference &&
            section.ordinal == 1 &&
            highestOfficialSectionOrdinal >= 3 &&
            confirmedAcceptedNumbers.isNotEmpty) {
          currentSectionIsReference = true;
          referenceSectionDetected = true;
        }
        if (!currentSectionIsReference &&
            section.ordinal != null &&
            section.ordinal! > highestOfficialSectionOrdinal) {
          highestOfficialSectionOrdinal = section.ordinal!;
        }
        currentSectionKind = section.kind;
        sections.add(section);
        if (!currentSectionIsReference) {
          officialSections.add(section);
        }
        ignoredBlocks.add(unit.block.blockId);
        continue;
      }

      addUnmatchedInternalMarkerProbes(unit);

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

      if (_isRomanSubquestion(text)) {
        romanSubquestionCount++;
      }

      final parenthesizedMarker = _readParenthesizedArabicMarker(text);
      if (parenthesizedMarker != null) {
        recordQuestionCandidate(unit);
        parenthesizedArabicCandidateCount++;
        final rejectionReason = candidateRejectionReason(
          number: parenthesizedMarker.number,
          requiresSectionContext: true,
        );

        if (rejectionReason == null) {
          parenthesizedArabicAcceptedCount++;
          sequenceAcceptedCount++;
          startQuestion(
            number: parenthesizedMarker.number,
            unit: unit,
            markerKind: 'parenthesized_arabic',
            remainingText: parenthesizedMarker.remainingText,
          );
          continue;
        }

        parenthesizedArabicRejectedCount++;
        if (rejectionReason == 'sequence_mismatch') {
          sequenceRejectedCount++;
        }
        rejectQuestionCandidate(
          number: parenthesizedMarker.number,
          unit: unit,
          markerKind: 'parenthesized_arabic',
          reason: rejectionReason,
          text: text,
        );
        continue;
      }

      final questionNumber = _detectQuestionNumber(
        unit,
        nextUnit: i + 1 < units.length ? units[i + 1] : null,
      );

      if (questionNumber != null) {
        final markerKind = _determineMarkerKind(text);
        if (_looksLikeOption(text)) {
          rejectedQuestionStarts.add(unit.block.blockId);
          addTrace(
            number: questionNumber,
            unit: unit,
            markerKind: markerKind,
            decision: 'rejected',
            reason: 'looks_like_option',
            previousAcceptedNumber: previousAcceptedNumber(),
            sectionIndex: currentSectionIndex,
          );
        } else {
          recordQuestionCandidate(unit);
          final rejectionReason = candidateRejectionReason(
            number: questionNumber,
            requiresSectionContext: false,
          );

          if (rejectionReason == null) {
            sequenceAcceptedCount++;
            startQuestion(
              number: questionNumber,
              unit: unit,
              markerKind: markerKind,
              remainingText: _stripQuestionPrefix(text),
            );
            continue;
          }

          if (rejectionReason == 'sequence_mismatch') {
            sequenceRejectedCount++;
          }
          rejectQuestionCandidate(
            number: questionNumber,
            unit: unit,
            markerKind: markerKind,
            reason: rejectionReason,
            text: text,
          );
          continue;
        }
      } else {
        if (_looksLikeOption(text)) {
          final match =
              RegExp(r'^\s*(?:[（(]\s*([A-D])\s*[）)]|([A-D])\s*[\.．、])')
                  .firstMatch(_normalizeQuestionCandidateText(text));
          final letter =
              (match?.group(1) ?? match?.group(2) ?? 'A').toUpperCase();
          final numVal = letter.codeUnitAt(0) - 'A'.codeUnitAt(0) + 1;

          addTrace(
            number: numVal,
            unit: unit,
            markerKind: 'unknown',
            decision: 'rejected',
            reason: 'looks_like_option',
            previousAcceptedNumber: previousAcceptedNumber(),
            sectionIndex: currentSectionIndex,
          );
        } else {
          final info = _parseMarkerInfo(text);
          if (info != null) {
            final parsedNum = info.number;
            final remainingText = _stripQuestionPrefix(text);
            final canPromoteFormulaLeadingMarker = parsedNum != null &&
                unit.startsAtBlockStart &&
                currentSectionKind != TextQuestionKind.unknown &&
                _looksLikeFormulaLeadingStem(remainingText);
            final previous = previousAcceptedNumber();
            final canPromoteSequentialBareMarker = parsedNum != null &&
                info.markerKind == 'explicit_question' &&
                unit.startsAtBlockStart &&
                currentSectionKind != TextQuestionKind.unknown &&
                !currentSectionIsReference &&
                previous != null &&
                parsedNum == previous + 1;

            if (canPromoteFormulaLeadingMarker ||
                canPromoteSequentialBareMarker) {
              recordQuestionCandidate(unit);
              final rejectionReason = candidateRejectionReason(
                number: parsedNum,
                requiresSectionContext: true,
              );
              if (rejectionReason == null) {
                sequenceAcceptedCount++;
                startQuestion(
                  number: parsedNum,
                  unit: unit,
                  markerKind: info.markerKind,
                  remainingText: remainingText,
                );
                continue;
              }

              if (rejectionReason == 'sequence_mismatch') {
                sequenceRejectedCount++;
              }
              rejectQuestionCandidate(
                number: parsedNum,
                unit: unit,
                markerKind: info.markerKind,
                reason: rejectionReason,
                text: text,
              );
              continue;
            }

            String reason = 'other';
            if (parsedNum == null) {
              reason = 'invalid_number_range';
            } else if (_looksLikeOption(text)) {
              reason = 'looks_like_option';
            } else if (previousAcceptedNumber() != null &&
                parsedNum <= previousAcceptedNumber()!) {
              reason = 'duplicate_or_reset';
            }

            final numberVal = parsedNum ??
                int.tryParse(
                    _normalizeQuestionMarkerText(info.rawNumberString ?? '')) ??
                0;

            addTrace(
              number: numberVal,
              unit: unit,
              markerKind: info.markerKind,
              decision: 'rejected',
              reason: reason,
              previousAcceptedNumber: previousAcceptedNumber(),
              sectionIndex: currentSectionIndex,
            );
          }
        }
      }

      final recoveryProbe = _readMarkerProbe(text);
      final recoveryNumber = recoveryProbe?.parsedNumber;
      final previous = previousAcceptedNumber();
      final canRecoverSequentialDigitPrefix = recoveryProbe != null &&
          recoveryProbe.markerShape == 'digit_prefix_unrecognized' &&
          recoveryProbe.followerClass == 'stem_keyword' &&
          unit.startsAtBlockStart &&
          currentSectionKind != TextQuestionKind.unknown &&
          !currentSectionIsReference &&
          recoveryNumber != null &&
          previous != null &&
          recoveryNumber == previous + 1;
      if (canRecoverSequentialDigitPrefix) {
        final recoveredProbe = recoveryProbe;
        final recoveredNumber = recoveryNumber;
        recordQuestionCandidate(unit);
        final rejectionReason = candidateRejectionReason(
          number: recoveredNumber,
          requiresSectionContext: true,
        );
        if (rejectionReason == null) {
          sequenceAcceptedCount++;
          startQuestion(
            number: recoveredNumber,
            unit: unit,
            markerKind: recoveredProbe.markerShape,
            remainingText: recoveredProbe.remainingText,
          );
          continue;
        }

        if (rejectionReason == 'sequence_mismatch') {
          sequenceRejectedCount++;
        }
        rejectQuestionCandidate(
          number: recoveredNumber,
          unit: unit,
          markerKind: recoveredProbe.markerShape,
          reason: rejectionReason,
          text: text,
        );
        continue;
      }

      addMarkerProbe(
        unit: unit,
        text: text,
        startsAtBlockStart: unit.startsAtBlockStart,
        probeReason: 'block_start_not_candidate',
        onlyUnrecognizedShape: true,
      );

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
    final expectedQuestionCount = _expectedQuestionCount(officialSections);
    final tailMissingNumbers = _tailMissingNumbers(
      acceptedNumbers,
      expectedQuestionCount,
    );
    final missingQuestionCount = _missingQuestionCount(
      acceptedNumbers,
      expectedQuestionCount,
    );

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
        'sectionHeadingCount': sections.length,
        if (sections.isNotEmpty)
          'sections': [
            for (var index = 0; index < sections.length; index++)
              sections[index].toDiagnostics(index + 1),
          ],
        'splitUnitCount': splitCount,
        'acceptedNumbers': acceptedNumbers,
        'missingNumbers': missingNumbers,
        'pageCandidateCounts': pageCandidateCounts,
        'markdownPrefixedCandidateCount': markdownPrefixedCandidateCount,
        'blockStartCandidateCount': blockStartCandidateCount,
        'internalLineCandidateCount': internalLineCandidateCount,
        'parenthesizedArabicCandidateCount': parenthesizedArabicCandidateCount,
        'acceptedQuestionCount': acceptedNumbers.length,
        'expectedQuestionCount': expectedQuestionCount,
        'tailMissingNumbers': tailMissingNumbers,
        'missingQuestionCount': missingQuestionCount,
        'parenthesizedArabicAcceptedCount': parenthesizedArabicAcceptedCount,
        'parenthesizedArabicRejectedCount': parenthesizedArabicRejectedCount,
        'romanSubquestionCount': romanSubquestionCount,
        'sequenceAcceptedCount': sequenceAcceptedCount,
        'sequenceRejectedCount': sequenceRejectedCount,
        'referenceSectionDetected': referenceSectionDetected,
        'referenceSectionCandidateCount': referenceSectionCandidateCount,
        'questionCandidateTrace': questionCandidateTrace,
        if (questionCandidateTraceTruncated)
          'questionCandidateTraceTruncated': true,
        'markerProbeTrace': markerProbeTrace,
        'markerProbeTraceTruncated': markerProbeTraceTruncated,
      },
    );
  }

  List<_OcrTextUnit> _splitBlock(OcrBlock block) {
    final text = block.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final boundaries = <int>{0, text.length};

    var lineStart = 0;
    while (lineStart < text.length) {
      final newline = text.indexOf('\n', lineStart);
      final lineEnd = newline < 0 ? text.length : newline;
      final nextLineStart = newline < 0 ? text.length : newline + 1;
      final line = text.substring(lineStart, lineEnd);

      if (_isSectionHeading(line) || _isReferenceSummaryHeading(line)) {
        boundaries.add(lineStart);
        boundaries.add(nextLineStart);
      } else if (_isValidInlineQuestionStart(line) ||
          _isValidBareQuestionStart(line) ||
          _readParenthesizedArabicMarker(line) != null ||
          _isRomanSubquestion(line)) {
        boundaries.add(lineStart);
      }

      if (newline < 0) break;
      lineStart = nextLineStart;
    }

    final sortedBoundaries = boundaries.toList()..sort();
    if (sortedBoundaries.length <= 2) {
      return [
        _OcrTextUnit(
          block: block,
          text: text,
          wasSplit: false,
          startsAtBlockStart: true,
        ),
      ];
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
            startsAtBlockStart: start == 0,
          ),
        );
      }
    }

    return units;
  }

  int? _detectQuestionNumber(
    _OcrTextUnit unit, {
    _OcrTextUnit? nextUnit,
  }) {
    final text = _normalizeQuestionCandidateText(unit.text);
    if (_isValidInlineQuestionStart(text) || _isValidBareQuestionStart(text)) {
      return _extractQuestionNumber(text);
    }

    if (_isStandaloneQuestionMarker(text) &&
        _isValidStandaloneFollower(unit, nextUnit)) {
      return _extractQuestionNumber(text);
    }

    final numericOnly = _numericOnlyQuestionMarkerRegex.firstMatch(text);
    if (numericOnly != null &&
        nextUnit != null &&
        unit.block.pageIndex == nextUnit.block.pageIndex &&
        _looksLikeStemStart(_normalizeQuestionCandidateText(nextUnit.text))) {
      return _parseQuestionNumber(numericOnly.group(1) ?? '');
    }

    return null;
  }

  String _normalizeQuestionMarkerText(String text) {
    const fullWidthDigits = '０１２３４５６７８９';
    return text.replaceAllMapped(RegExp(r'[０-９]'), (match) {
      return fullWidthDigits.indexOf(match.group(0)!).toString();
    });
  }

  int? _parseQuestionNumber(String text) {
    final normalized = _normalizeQuestionMarkerText(text);
    final number = int.tryParse(normalized);
    if (number == null || number < 1 || number > 999) return null;
    return number;
  }

  _ParenthesizedArabicMarker? _readParenthesizedArabicMarker(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final match = _parenthesizedArabicMarkerRegex.firstMatch(candidate);
    if (match == null) return null;

    final number = _parseQuestionNumber(match.group(1) ?? match.group(2) ?? '');
    if (number == null) return null;
    return _ParenthesizedArabicMarker(
      number: number,
      remainingText: (match.group(3) ?? '').trim(),
    );
  }

  bool _isRomanSubquestion(String text) {
    return _romanSubquestionRegex.hasMatch(
      _normalizeQuestionCandidateText(text),
    );
  }

  int? _extractQuestionNumber(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final explicit = _explicitQuestionMarkerRegex.firstMatch(candidate);
    if (explicit != null) {
      return _parseQuestionNumber(explicit.group(1) ?? '');
    }

    final standalone = _standaloneQuestionMarkerRegex.firstMatch(candidate);
    if (standalone != null) {
      return _parseQuestionNumber(standalone.group(1) ?? '');
    }

    final bare = _bareQuestionMarkerRegex.firstMatch(candidate);
    if (bare != null) {
      return _parseQuestionNumber(bare.group(1) ?? '');
    }

    return null;
  }

  bool _isValidInlineQuestionStart(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final match = _explicitQuestionMarkerRegex.firstMatch(candidate);
    if (match == null || _parseQuestionNumber(match.group(1) ?? '') == null) {
      return false;
    }

    final remaining = (match.group(3) ?? '').trimLeft();
    if (remaining.isEmpty) return false;
    return !RegExp(r'^[0-9０-９]').hasMatch(remaining);
  }

  bool _isValidBareQuestionStart(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final match = _bareQuestionMarkerRegex.firstMatch(candidate);
    if (match == null || _parseQuestionNumber(match.group(1) ?? '') == null) {
      return false;
    }
    return _looksLikeStemStart(match.group(2) ?? '');
  }

  bool _isStandaloneQuestionMarker(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final match = _standaloneQuestionMarkerRegex.firstMatch(candidate);
    return match != null && _parseQuestionNumber(match.group(1) ?? '') != null;
  }

  bool _isValidStandaloneFollower(
    _OcrTextUnit unit,
    _OcrTextUnit? nextUnit,
  ) {
    if (nextUnit == null || unit.block.pageIndex != nextUnit.block.pageIndex) {
      return false;
    }

    final nextText = _normalizeQuestionCandidateText(nextUnit.text);
    return nextText.isNotEmpty &&
        !_isSectionHeading(nextText) &&
        !_isValidInlineQuestionStart(nextText) &&
        !_isValidBareQuestionStart(nextText) &&
        !_isStandaloneQuestionMarker(nextText) &&
        !_looksLikeOption(nextText) &&
        _readFieldTransition(nextText) == null;
  }

  String _stripQuestionPrefix(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final parenthesized = _readParenthesizedArabicMarker(candidate);
    if (parenthesized != null) return parenthesized.remainingText;

    final explicit = _explicitQuestionMarkerRegex.firstMatch(candidate);
    if (explicit != null) return (explicit.group(3) ?? '').trim();

    if (_isStandaloneQuestionMarker(candidate) ||
        _numericOnlyQuestionMarkerRegex.hasMatch(candidate)) {
      return '';
    }

    final bare = _bareQuestionMarkerRegex.firstMatch(candidate);
    if (bare != null) return (bare.group(2) ?? '').trim();

    return candidate.trim();
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

  _MarkerInfo? _parseMarkerInfo(String text) {
    final candidate = _normalizeQuestionCandidateText(text);

    final parenMatch = _parenthesizedArabicMarkerRegex.firstMatch(candidate);
    if (parenMatch != null) {
      final rawNum = parenMatch.group(1) ?? parenMatch.group(2) ?? '';
      return _MarkerInfo(
        number: _parseQuestionNumber(rawNum),
        markerKind: 'parenthesized_arabic',
        rawNumberString: rawNum,
      );
    }

    final bareMatch = _bareQuestionMarkerRegex.firstMatch(candidate);
    if (bareMatch != null) {
      final rawNum = bareMatch.group(1) ?? '';
      return _MarkerInfo(
        number: _parseQuestionNumber(rawNum),
        markerKind: 'explicit_question',
        rawNumberString: rawNum,
      );
    }

    final explicitMatch = _explicitQuestionMarkerRegex.firstMatch(candidate);
    if (explicitMatch != null) {
      final rawNum = explicitMatch.group(1) ?? '';
      return _MarkerInfo(
        number: _parseQuestionNumber(rawNum),
        markerKind: 'punctuated_integer',
        rawNumberString: rawNum,
      );
    }

    final standaloneMatch =
        _standaloneQuestionMarkerRegex.firstMatch(candidate);
    if (standaloneMatch != null) {
      final rawNum = standaloneMatch.group(1) ?? '';
      return _MarkerInfo(
        number: _parseQuestionNumber(rawNum),
        markerKind: 'punctuated_integer',
        rawNumberString: rawNum,
      );
    }

    final numericOnlyMatch =
        _numericOnlyQuestionMarkerRegex.firstMatch(candidate);
    if (numericOnlyMatch != null) {
      final rawNum = numericOnlyMatch.group(1) ?? '';
      return _MarkerInfo(
        number: _parseQuestionNumber(rawNum),
        markerKind: 'plain_integer',
        rawNumberString: rawNum,
      );
    }

    return null;
  }

  _MarkerProbeInfo? _readMarkerProbe(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    final markerInfo = _parseMarkerInfo(candidate);
    if (markerInfo != null) {
      return _MarkerProbeInfo(
        markerShape: markerInfo.markerKind,
        parsedNumber: markerInfo.number,
        followerClass: _classifyMarkerProbeFollower(
          _stripQuestionPrefix(candidate),
        ),
        remainingText: _stripQuestionPrefix(candidate),
      );
    }

    final leadingDigits = _leadingDigitProbeRegex.firstMatch(candidate);
    if (leadingDigits == null) return null;
    final remainingText = (leadingDigits.group(2) ?? '').trim();
    return _MarkerProbeInfo(
      markerShape: 'digit_prefix_unrecognized',
      parsedNumber: _parseQuestionNumber(leadingDigits.group(1) ?? ''),
      followerClass: _classifyMarkerProbeFollower(remainingText),
      remainingText: remainingText,
    );
  }

  String _classifyMarkerProbeFollower(String text) {
    final normalized = text.trimLeft();
    if (normalized.isEmpty) return 'empty';
    if (_looksLikeFormulaLeadingStem(normalized)) return 'formula';
    if (_looksLikeStemStart(normalized)) return 'stem_keyword';
    if (RegExp(r'^[0-9０-９]').hasMatch(normalized)) return 'digit';
    return 'other';
  }

  String _determineMarkerKind(String text) {
    final candidate = _normalizeQuestionCandidateText(text);
    if (_parenthesizedArabicMarkerRegex.hasMatch(candidate)) {
      return 'parenthesized_arabic';
    }
    if (_bareQuestionMarkerRegex.hasMatch(candidate)) {
      return 'explicit_question';
    }
    if (_explicitQuestionMarkerRegex.hasMatch(candidate) ||
        _standaloneQuestionMarkerRegex.hasMatch(candidate)) {
      return 'punctuated_integer';
    }
    if (_numericOnlyQuestionMarkerRegex.hasMatch(candidate)) {
      return 'plain_integer';
    }
    return 'unknown';
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

  String _normalizeQuestionCandidateText(String text) {
    return _stripLeadingMarkdownStructure(_normalizeText(text));
  }

  String _stripLeadingMarkdownStructure(String text) {
    var result = text;
    while (true) {
      final quote = _markdownQuotePrefixRegex.firstMatch(result);
      if (quote != null) {
        result = result.substring(quote.end);
        continue;
      }

      final heading = _markdownHeadingPrefixRegex.firstMatch(result);
      if (heading != null) {
        result = result.substring(heading.end);
        continue;
      }
      return result;
    }
  }

  bool _hasLeadingMarkdownStructure(String text) {
    final normalized = _normalizeText(text);
    return _stripLeadingMarkdownStructure(normalized) != normalized;
  }

  bool _isReferenceSummaryHeading(String text) {
    return hasReferenceAnswerSectionHeadingSuffix(text);
  }

  _SectionHeadingInfo? _readSectionHeading(String text) {
    final normalized = _normalizeQuestionCandidateText(text)
        .replaceFirst(RegExp(r'^第\s*'), '')
        .replaceAll(RegExp(r'\s+'), '');

    final prefix = RegExp(
      r'^([一二三四五六七八九十]+)[、,，\.．]?(.*)$',
    ).firstMatch(normalized);
    if (prefix == null) return null;

    const labels = [
      '单项选择题',
      '多项选择题',
      '选择题',
      '填空题',
      '解答题',
      '证明题',
      '计算题',
    ];
    final remainder = prefix.group(2) ?? '';
    final label = labels.cast<String?>().firstWhere(
          (candidate) => remainder.startsWith(candidate!),
          orElse: () => null,
        );
    if (label == null) return null;

    final suffix = remainder.substring(label.length);
    if (!_isValidSectionHeadingSuffix(suffix)) return null;

    final kind = label.contains('选择')
        ? TextQuestionKind.choice
        : label.contains('填空')
            ? TextQuestionKind.fillBlank
            : TextQuestionKind.subjective;
    return _SectionHeadingInfo(
      ordinal: _parseChineseSectionOrdinal(prefix.group(1) ?? ''),
      kind: kind,
      expectedQuestionCount: _extractExpectedSectionQuestionCount(suffix),
    );
  }

  bool _isSectionHeading(String text) {
    return _readSectionHeading(text) != null;
  }

  int? _extractExpectedSectionQuestionCount(String suffix) {
    final counts = <int>{};
    for (final match in _sectionQuestionCountRegex.allMatches(suffix)) {
      final count = _parseQuestionNumber(match.group(1) ?? '');
      if (count != null && count <= 200) counts.add(count);
    }
    return counts.length == 1 ? counts.single : null;
  }

  int? _parseChineseSectionOrdinal(String raw) {
    const digits = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (raw == '十') return 10;
    if (!raw.contains('十')) return digits[raw];

    final parts = raw.split('十');
    if (parts.length != 2) return null;
    final tens = parts.first.isEmpty ? 1 : digits[parts.first];
    final ones = parts.last.isEmpty ? 0 : digits[parts.last];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }

  bool _isValidSectionHeadingSuffix(String suffix) {
    if (suffix.isEmpty) return true;

    if (suffix.startsWith('：') || suffix.startsWith(':')) {
      return _looksLikeSectionInstruction(suffix.substring(1));
    }

    final usesChineseBrackets = suffix.startsWith('（') && suffix.endsWith('）');
    final usesAsciiBrackets = suffix.startsWith('(') && suffix.endsWith(')');
    if (usesChineseBrackets || usesAsciiBrackets) {
      return _looksLikeSectionInstruction(
        suffix.substring(1, suffix.length - 1),
      );
    }

    return _looksLikeSectionInstruction(suffix);
  }

  bool _looksLikeSectionInstruction(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return false;
    final hasInstructionSubject =
        RegExp(r'^(?:本题|每|共|请|其中|答题|作答)').hasMatch(normalized);
    final hasInstructionDetail =
        RegExp(r'(?:题|分|选项|作答|要求)').hasMatch(normalized);
    return hasInstructionSubject && hasInstructionDetail;
  }

  bool _looksLikeOption(String text) {
    return RegExp(r'^\s*(?:\([A-D]\)|[A-D][\.、．])').hasMatch(
      _normalizeQuestionCandidateText(text),
    );
  }

  bool _looksLikeStemStart(String text) {
    return RegExp(r'^\s*(?:设|已知|若|求|证明|计算|下列|关于|函数|随机|令|讨论|判断|选择|填空|设随机|设函数)')
        .hasMatch(text);
  }

  bool _looksLikeFormulaLeadingStem(String text) {
    final normalized = text.trimLeft();
    if (normalized.isEmpty) return false;
    return RegExp(
      r'^(?:\$|\\\(|\\\[|\\[A-Za-z]+|[∫∑√]|当\s*[A-Za-z]|[A-Za-z][A-Za-z0-9_]*\s*[_^=<>≤≥])',
    ).hasMatch(normalized);
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

  int? _expectedQuestionCount(List<_SectionHeadingInfo> sections) {
    if (sections.isEmpty) return null;
    for (var index = 0; index < sections.length; index++) {
      final section = sections[index];
      if (section.ordinal != index + 1 ||
          section.expectedQuestionCount == null) {
        return null;
      }
    }
    return sections.fold<int>(
      0,
      (total, section) => total + section.expectedQuestionCount!,
    );
  }

  List<int> _tailMissingNumbers(
    List<int> acceptedNumbers,
    int? expectedQuestionCount,
  ) {
    if (expectedQuestionCount == null || acceptedNumbers.isEmpty) {
      return const [];
    }
    final lastAccepted = acceptedNumbers.reduce((a, b) => a > b ? a : b);
    if (lastAccepted >= expectedQuestionCount) return const [];
    return [
      for (var number = lastAccepted + 1;
          number <= expectedQuestionCount;
          number++)
        number,
    ];
  }

  int? _missingQuestionCount(
    List<int> acceptedNumbers,
    int? expectedQuestionCount,
  ) {
    if (expectedQuestionCount == null) return null;
    final accepted = acceptedNumbers.toSet();
    var missing = 0;
    for (var number = 1; number <= expectedQuestionCount; number++) {
      if (!accepted.contains(number)) missing++;
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
    required this.startsAtBlockStart,
  });

  final OcrBlock block;
  final String text;
  final bool wasSplit;
  final bool startsAtBlockStart;
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

class _SectionHeadingInfo {
  const _SectionHeadingInfo({
    required this.ordinal,
    required this.kind,
    required this.expectedQuestionCount,
  });

  final int? ordinal;
  final TextQuestionKind kind;
  final int? expectedQuestionCount;

  Map<String, dynamic> toDiagnostics(int sectionIndex) {
    return {
      'sectionIndex': sectionIndex,
      'kind': kind.name,
      'expectedSectionQuestionCount': expectedQuestionCount,
    };
  }
}

class _ParenthesizedArabicMarker {
  const _ParenthesizedArabicMarker({
    required this.number,
    required this.remainingText,
  });

  final int number;
  final String remainingText;
}

class _MarkerInfo {
  const _MarkerInfo({
    required this.number,
    required this.markerKind,
    required this.rawNumberString,
  });

  final int? number;
  final String markerKind;
  final String? rawNumberString;
}

class _MarkerProbeInfo {
  const _MarkerProbeInfo({
    required this.markerShape,
    required this.parsedNumber,
    required this.followerClass,
    required this.remainingText,
  });

  final String markerShape;
  final int? parsedNumber;
  final String followerClass;
  final String remainingText;
}
