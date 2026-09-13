enum SubjectiveAnswerRecognitionMode { ocr, vision }

enum SubjectiveAnswerRecognitionClassification {
  success,
  invalidInput,
  engineUnavailable,
  providerFailure,
  emptyResult,
  outputTooLong,
}

final class SubjectiveAnswerRecognitionRequest {
  const SubjectiveAnswerRecognitionRequest({
    required this.imagePath,
    required this.imageName,
    required this.mode,
  });

  /// Transient picker identity. It is consumed by the provider adapter and is
  /// never returned, persisted, or logged by this Application contract.
  final String imagePath;
  final String imageName;
  final SubjectiveAnswerRecognitionMode mode;
}

final class SubjectiveAnswerRecognitionResult {
  const SubjectiveAnswerRecognitionResult._({
    required this.classification,
    required this.recognizedText,
  });

  factory SubjectiveAnswerRecognitionResult.success(String recognizedText) {
    return SubjectiveAnswerRecognitionResult._(
      classification: SubjectiveAnswerRecognitionClassification.success,
      recognizedText: recognizedText,
    );
  }

  factory SubjectiveAnswerRecognitionResult.failure(
    SubjectiveAnswerRecognitionClassification classification,
  ) {
    assert(classification != SubjectiveAnswerRecognitionClassification.success);
    return SubjectiveAnswerRecognitionResult._(
      classification: classification,
      recognizedText: '',
    );
  }

  final SubjectiveAnswerRecognitionClassification classification;
  final String recognizedText;

  bool get isSuccess =>
      classification == SubjectiveAnswerRecognitionClassification.success;
}

abstract interface class SubjectiveAnswerRecognitionPort {
  Future<SubjectiveAnswerRecognitionResult> recognize(
    SubjectiveAnswerRecognitionRequest request,
  );
}
