import '../../data/models/import_question_validation.dart';
import 'ocr_question_regionizer.dart';
import 'reference_answer_entry.dart';

class ReferenceAnswerMerger {
  const ReferenceAnswerMerger();

  List<OcrQuestionRegion> merge(
    List<OcrQuestionRegion> regions,
    ReferenceAnswerIndex index,
  ) {
    return regions.map((region) {
      if (index.conflictedNumbers.contains(region.number)) {
        return _copyRegion(
          region,
          diagnostics: {
            ...region.diagnostics,
            'reference_answer_duplicate_conflict',
          },
        );
      }

      final entry = index.entries[region.number];
      if (entry == null || !_isMeaningfulReferenceAnswer(entry.answerText)) {
        return region;
      }

      final localAnswer = region.answerText;
      final diagnostics = <String>{...region.diagnostics};
      List<String> answerParts = region.answerParts;
      if (!isMeaningfulAnswer(localAnswer)) {
        answerParts = [entry.answerText];
        diagnostics
          ..remove('missing_answer')
          ..add('reference_answer_attached')
          ..add(
            'reference_answer_pattern:${_safePatternKind(entry.patternKind)}',
          );
      } else if (_normalizeAnswer(localAnswer) ==
          _normalizeAnswer(entry.answerText)) {
        diagnostics.add('reference_answer_confirmed');
      } else {
        diagnostics.add('reference_answer_conflict');
      }

      final pages = {
        ...region.sourcePageIndices,
        ...entry.sourcePageIndices,
      }.toList()
        ..sort();
      final blockIds = {
        ...region.sourceBlockIds,
        ...entry.sourceBlockIds,
      }.toList();
      return _copyRegion(
        region,
        answerParts: answerParts,
        sourcePageIndices: pages,
        sourceBlockIds: blockIds,
        diagnostics: diagnostics,
      );
    }).toList(growable: false);
  }

  OcrQuestionRegion _copyRegion(
    OcrQuestionRegion region, {
    List<String>? answerParts,
    List<int>? sourcePageIndices,
    List<String>? sourceBlockIds,
    Set<String>? diagnostics,
  }) {
    return OcrQuestionRegion(
      number: region.number,
      stemParts: region.stemParts,
      answerParts: List.unmodifiable(answerParts ?? region.answerParts),
      explanationParts: region.explanationParts,
      sourcePageIndices:
          List.unmodifiable(sourcePageIndices ?? region.sourcePageIndices),
      sourceBlockIds:
          List.unmodifiable(sourceBlockIds ?? region.sourceBlockIds),
      diagnostics: List.unmodifiable(diagnostics ?? region.diagnostics.toSet()),
      declaredKind: region.declaredKind,
    );
  }

  bool _isMeaningfulReferenceAnswer(String answer) {
    final normalized = answer.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized == '略' || normalized == '证明略') return false;
    return isMeaningfulAnswer(answer);
  }

  String _normalizeAnswer(String answer) =>
      answer.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _safePatternKind(String value) {
    return const {'dense_objective', 'explicit_numbered'}.contains(value)
        ? value
        : 'unknown';
  }
}
