import '../../data/models/import_question_validation.dart';
import 'ocr_document.dart';
import 'ocr_question_regionizer.dart';
import 'reference_answer_entry.dart';
import 'reference_answer_section.dart';

class ReferenceAnswerExtractor {
  const ReferenceAnswerExtractor();

  static final RegExp _densePairPattern = RegExp(
    r'(?:^|\s)([0-9０-９]{1,3})\s*[.．、]?\s*([A-D])(?=\s|$|[,，;；])',
    caseSensitive: false,
  );

  static final RegExp _explicitPattern = RegExp(
    r'^\s*([0-9０-９]{1,3})\s*(?:[.．、]\s*|(?:答案|参考答案)\s*[:：]\s*)([\s\S]*)$',
    caseSensitive: false,
  );

  static final RegExp _parenthesizedMarkerPattern = RegExp(
    r'[（(]\s*([0-9０-９]{1,3})\s*[）)]',
  );

  static final RegExp _parenthesizedChoiceBodyPattern = RegExp(
    r'^\s*([A-D])\s*[,，;；、]?\s*$',
    caseSensitive: false,
  );

  ReferenceAnswerIndex extract(
    OcrDocument document,
    List<OcrQuestionRegion> officialRegions,
  ) {
    final officialNumbers =
        officialRegions.map((region) => region.number).toSet();
    final blocks = document.flattenedBlocks;
    if (officialNumbers.isEmpty || blocks.isEmpty) {
      return _emptyIndex();
    }

    final blockIndexById = <String, int>{
      for (var index = 0; index < blocks.length; index++)
        blocks[index].blockId: index,
    };
    var lastOfficialBlockIndex = -1;
    for (final region in officialRegions) {
      for (final blockId in region.sourceBlockIds) {
        final index = blockIndexById[blockId];
        if (index != null && index > lastOfficialBlockIndex) {
          lastOfficialBlockIndex = index;
        }
      }
    }
    if (lastOfficialBlockIndex < 0) return _emptyIndex();

    final repeatedBoilerplate =
        _repeatedBoilerplateTexts(blocks, officialNumbers);
    final sectionLines = <_ReferenceLine>[];
    var sectionDetected = false;
    var stopped = false;

    for (var blockIndex = lastOfficialBlockIndex + 1;
        blockIndex < blocks.length && !stopped;
        blockIndex++) {
      final block = blocks[blockIndex];
      if (repeatedBoilerplate.contains(_normalizeBlockText(block.text))) {
        continue;
      }
      final lines = block.text
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        final line = lines[lineIndex];
        if (!sectionDetected) {
          if (hasReferenceAnswerSectionHeadingSuffix(line)) {
            sectionDetected = true;
          }
          continue;
        }
        if (isReferenceAnswerStopHeading(line)) {
          stopped = true;
          break;
        }
        sectionLines.add(_ReferenceLine(block: block, text: line));
      }
    }

    if (!sectionDetected) return _emptyIndex();
    return _parseSection(sectionLines, officialNumbers);
  }

  ReferenceAnswerIndex _parseSection(
    List<_ReferenceLine> lines,
    Set<int> officialNumbers,
  ) {
    final candidates = <_ReferenceCandidate>[];
    final seenNumbers = <int>{};
    _PendingAnswer? pending;
    int? lastMarkerNumber;
    var ignoredCount = 0;

    void commitPending() {
      final current = pending;
      pending = null;
      if (current == null) return;
      final answer = current.parts.join('\n').trim();
      if (answer.isEmpty) {
        ignoredCount++;
        return;
      }
      candidates.add(
        _ReferenceCandidate(
          number: current.number,
          answer: answer,
          pageIndices: current.pageIndices,
          blockIds: current.blockIds,
          patternKind: current.patternKind,
        ),
      );
      seenNumbers.add(current.number);
    }

    for (final line in lines) {
      final text = line.text.trim();
      if (text.isEmpty) {
        if (pending != null && pending!.parts.isNotEmpty) {
          pending!.parts.add('');
        }
        continue;
      }

      final parenthesizedMatches =
          _parenthesizedMarkerPattern.allMatches(text).toList();
      if (parenthesizedMatches.isNotEmpty &&
          parenthesizedMatches.first.start == 0) {
        if (parenthesizedMatches.length >= 2) {
          final parsed = _parseParenthesizedDenseChoices(
            text,
            parenthesizedMatches,
            officialNumbers,
          );
          if (parsed != null) {
            commitPending();
            for (final pair in parsed) {
              candidates.add(
                _ReferenceCandidate(
                  number: pair.$1,
                  answer: pair.$2,
                  pageIndices: {line.block.pageIndex},
                  blockIds: {line.block.blockId},
                  patternKind: 'dense_objective',
                ),
              );
              seenNumbers.add(pair.$1);
            }
            final maxNumber =
                parsed.map((pair) => pair.$1).reduce((a, b) => a > b ? a : b);
            if (lastMarkerNumber == null || maxNumber > lastMarkerNumber) {
              lastMarkerNumber = maxNumber;
            }
            continue;
          }
        } else {
          final match = parenthesizedMatches.single;
          final number = _parseDigits(match.group(1)!);
          if (number != null && officialNumbers.contains(number)) {
            final sequenceIsSafe = lastMarkerNumber == null ||
                number > lastMarkerNumber ||
                pending?.number == number;
            if (sequenceIsSafe) {
              commitPending();
              pending = _PendingAnswer(
                number: number,
                initialText: text.substring(match.end).trim(),
                block: line.block,
                patternKind: 'explicit_numbered',
              );
              if (lastMarkerNumber == null || number > lastMarkerNumber) {
                lastMarkerNumber = number;
              }
              continue;
            }
          }
        }
      }

      final denseMatches = _densePairPattern.allMatches(text).toList();
      if (denseMatches.length >= 2) {
        final parsed = <(int, String)>[];
        final numbers = <int>{};
        var valid = true;
        for (final match in denseMatches) {
          final number = _parseDigits(match.group(1)!);
          final answer = match.group(2)!.toUpperCase();
          if (number == null ||
              !officialNumbers.contains(number) ||
              !numbers.add(number)) {
            valid = false;
            break;
          }
          parsed.add((number, answer));
        }
        if (valid) {
          commitPending();
          for (final pair in parsed) {
            candidates.add(
              _ReferenceCandidate(
                number: pair.$1,
                answer: pair.$2,
                pageIndices: {line.block.pageIndex},
                blockIds: {line.block.blockId},
                patternKind: 'dense_objective',
              ),
            );
            seenNumbers.add(pair.$1);
          }
          final maxNumber =
              parsed.map((pair) => pair.$1).reduce((a, b) => a > b ? a : b);
          if (lastMarkerNumber == null || maxNumber > lastMarkerNumber) {
            lastMarkerNumber = maxNumber;
          }
          continue;
        }
        ignoredCount++;
      }

      final explicit = _explicitPattern.firstMatch(text);
      if (explicit != null) {
        final number = _parseDigits(explicit.group(1)!);
        if (number == null || !officialNumbers.contains(number)) {
          ignoredCount++;
          continue;
        }
        final sequenceIsSafe = lastMarkerNumber == null ||
            number > lastMarkerNumber ||
            pending?.number == number ||
            seenNumbers.contains(number);
        if (sequenceIsSafe) {
          commitPending();
          pending = _PendingAnswer(
            number: number,
            initialText: explicit.group(2)!.trim(),
            block: line.block,
            patternKind: 'explicit_numbered',
          );
          if (lastMarkerNumber == null || number > lastMarkerNumber) {
            lastMarkerNumber = number;
          }
          continue;
        }
      }

      final current = pending;
      if (current != null) {
        current.parts.add(line.text.trimRight());
        current.pageIndices.add(line.block.pageIndex);
        current.blockIds.add(line.block.blockId);
      }
    }
    commitPending();

    final byNumber = <int, List<_ReferenceCandidate>>{};
    for (final candidate in candidates) {
      byNumber.putIfAbsent(candidate.number, () => []).add(candidate);
    }

    final entries = <int, ReferenceAnswerEntry>{};
    final conflictedNumbers = <int>{};
    final acceptedPages = <int>{};
    final patternKinds = <String>{};
    var conflictCount = 0;

    for (final number in byNumber.keys.toList()..sort()) {
      final numberCandidates = byNumber[number]!;
      final meaningful = numberCandidates
          .where((candidate) => _isMeaningfulReferenceAnswer(candidate.answer))
          .toList(growable: false);
      ignoredCount += numberCandidates.length - meaningful.length;
      if (meaningful.isEmpty) continue;

      final normalizedAnswers = meaningful
          .map((candidate) => _normalizeAnswer(candidate.answer))
          .toSet();
      if (normalizedAnswers.length != 1) {
        conflictedNumbers.add(number);
        conflictCount++;
        continue;
      }

      final first = meaningful.first;
      final pages = <int>{};
      final blockIds = <String>{};
      for (final candidate in meaningful) {
        pages.addAll(candidate.pageIndices);
        blockIds.addAll(candidate.blockIds);
      }
      final sortedPages = pages.toList()..sort();
      acceptedPages.addAll(sortedPages);
      patternKinds.add(first.patternKind);
      entries[number] = ReferenceAnswerEntry(
        questionNumber: number,
        answerText: first.answer,
        sourcePageIndices: List.unmodifiable(sortedPages),
        sourceBlockIds: List.unmodifiable(blockIds),
        patternKind: first.patternKind,
      );
    }

    final acceptedNumbers = entries.keys.toList()..sort();
    final sortedPages = acceptedPages.toList()..sort();
    final sortedKinds = patternKinds.toList()..sort();
    return ReferenceAnswerIndex(
      entries: Map.unmodifiable(entries),
      conflictedNumbers: Set.unmodifiable(conflictedNumbers),
      diagnostics: Map.unmodifiable({
        'referenceSectionDetected': true,
        'candidateCount': candidates.length,
        'acceptedCount': entries.length,
        'ignoredCount': ignoredCount,
        'conflictCount': conflictCount,
        'acceptedNumbers': acceptedNumbers,
        'patternKinds': sortedKinds,
        'sourcePageIndices': sortedPages,
      }),
    );
  }

  ReferenceAnswerIndex _emptyIndex() {
    return const ReferenceAnswerIndex(
      entries: {},
      conflictedNumbers: {},
      diagnostics: {
        'referenceSectionDetected': false,
        'candidateCount': 0,
        'acceptedCount': 0,
        'ignoredCount': 0,
        'conflictCount': 0,
        'acceptedNumbers': <int>[],
        'patternKinds': <String>[],
        'sourcePageIndices': <int>[],
      },
    );
  }

  Set<String> _repeatedBoilerplateTexts(
    List<OcrBlock> blocks,
    Set<int> officialNumbers,
  ) {
    final pagesByText = <String, Set<int>>{};
    for (final block in blocks) {
      final normalized = _normalizeBlockText(block.text);
      if (normalized.isEmpty ||
          normalized.length > 80 ||
          hasReferenceAnswerSectionHeadingSuffix(block.text) ||
          isReferenceAnswerStopHeading(block.text) ||
          _containsPotentialAnswerMarker(normalized, officialNumbers)) {
        continue;
      }
      pagesByText.putIfAbsent(normalized, () => <int>{}).add(block.pageIndex);
    }
    return {
      for (final entry in pagesByText.entries)
        if (entry.value.length >= 2) entry.key,
    };
  }

  bool _containsPotentialAnswerMarker(
    String text,
    Set<int> officialNumbers,
  ) {
    final dense = _densePairPattern.allMatches(text).toList();
    if (dense.length >= 2) return true;
    final explicit = _explicitPattern.firstMatch(text);
    final number =
        explicit == null ? null : _parseDigits(explicit.group(1) ?? '');
    if (number != null && officialNumbers.contains(number)) return true;
    final parenthesized = _parenthesizedMarkerPattern.firstMatch(text);
    final parenthesizedNumber = parenthesized == null
        ? null
        : _parseDigits(parenthesized.group(1) ?? '');
    return parenthesized?.start == 0 &&
        parenthesizedNumber != null &&
        officialNumbers.contains(parenthesizedNumber);
  }

  List<(int, String)>? _parseParenthesizedDenseChoices(
    String text,
    List<RegExpMatch> matches,
    Set<int> officialNumbers,
  ) {
    final parsed = <(int, String)>[];
    final numbers = <int>{};
    int? previousNumber;
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final number = _parseDigits(match.group(1)!);
      final bodyEnd =
          index + 1 < matches.length ? matches[index + 1].start : text.length;
      final bodyMatch = _parenthesizedChoiceBodyPattern.firstMatch(
        text.substring(match.end, bodyEnd),
      );
      if (number == null ||
          !officialNumbers.contains(number) ||
          !numbers.add(number) ||
          (previousNumber != null && number <= previousNumber) ||
          bodyMatch == null) {
        return null;
      }
      parsed.add((number, bodyMatch.group(1)!.toUpperCase()));
      previousNumber = number;
    }
    return parsed;
  }

  String _normalizeBlockText(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _normalizeAnswer(String answer) =>
      answer.replaceAll(RegExp(r'\s+'), ' ').trim();

  bool _isMeaningfulReferenceAnswer(String answer) {
    final normalized = answer.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized == '略' || normalized == '证明略') return false;
    return isMeaningfulAnswer(answer);
  }

  int? _parseDigits(String value) {
    const fullwidth = '０１２３４５６７８９';
    final buffer = StringBuffer();
    for (final codePoint in value.runes) {
      final character = String.fromCharCode(codePoint);
      final index = fullwidth.indexOf(character);
      buffer.write(index < 0 ? character : index);
    }
    return int.tryParse(buffer.toString());
  }
}

class _ReferenceLine {
  const _ReferenceLine({required this.block, required this.text});

  final OcrBlock block;
  final String text;
}

class _PendingAnswer {
  _PendingAnswer({
    required this.number,
    required String initialText,
    required OcrBlock block,
    required this.patternKind,
  })  : parts = [if (initialText.isNotEmpty) initialText],
        pageIndices = {block.pageIndex},
        blockIds = {block.blockId};

  final int number;
  final List<String> parts;
  final Set<int> pageIndices;
  final Set<String> blockIds;
  final String patternKind;
}

class _ReferenceCandidate {
  const _ReferenceCandidate({
    required this.number,
    required this.answer,
    required this.pageIndices,
    required this.blockIds,
    required this.patternKind,
  });

  final int number;
  final String answer;
  final Set<int> pageIndices;
  final Set<String> blockIds;
  final String patternKind;
}
