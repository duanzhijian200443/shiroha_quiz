class ReferenceAnswerEntry {
  const ReferenceAnswerEntry({
    required this.questionNumber,
    required this.answerText,
    required this.sourcePageIndices,
    required this.sourceBlockIds,
    required this.patternKind,
  });

  final int questionNumber;
  final String answerText;
  final List<int> sourcePageIndices;
  final List<String> sourceBlockIds;
  final String patternKind;
}

class ReferenceAnswerIndex {
  const ReferenceAnswerIndex({
    required this.entries,
    required this.conflictedNumbers,
    required this.diagnostics,
  });

  final Map<int, ReferenceAnswerEntry> entries;
  final Set<int> conflictedNumbers;
  final Map<String, dynamic> diagnostics;
}
