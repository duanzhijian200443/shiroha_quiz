enum QuestionDataClearAllFailure {
  examReferenced,
  unavailable,
  transactionFailed,
}

final class QuestionDataClearAllException implements Exception {
  const QuestionDataClearAllException(this.failure);

  final QuestionDataClearAllFailure failure;

  @override
  String toString() => 'QuestionDataClearAllException(${failure.name})';
}
