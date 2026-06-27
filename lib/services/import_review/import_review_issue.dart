enum ImportReviewSeverity { error, warning, info }

enum ImportReviewIssueCode {
  missingStem,
  placeholderStem,
  missingAnswer,
  choiceWithoutOptions,
  choiceAnswerNotInOptions,

  // A2 Fusion Metadata Issues
  answerConflict,
  orphanFragment,
  answerOnlyFragment,
  partialQuestion,
  visionOnly,
  fusedFromTextVision,
  unsupportedTypeFallback,
  answerLeakedToContent,
  missingAnswerOrExplanation,
  typeOptionsMismatch,
  duplicateQuestionNumber,
  questionNumberDrift,
  lowQualityVisionParse,
}

class ImportReviewIssue {
  final ImportReviewSeverity severity;
  final ImportReviewIssueCode code;
  final int questionIndex;
  final String message;

  const ImportReviewIssue({
    required this.severity,
    required this.code,
    required this.questionIndex,
    required this.message,
  });
}
