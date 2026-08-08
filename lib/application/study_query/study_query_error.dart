/// Failure semantics of the T0 read-only study query layer.
///
/// The complete fixed code set is
/// `invalid_request | not_found | access_denied | data_corrupt |
/// temporarily_unavailable | internal_error`. Errors never carry SQL,
/// SQLite paths, local paths, provider URLs/keys, raw payloads, full
/// question content, answers, stack traces, or schema internals.
library;

/// Fixed failure codes of the study query layer.
enum StudyQueryFailure {
  invalidRequest,
  notFound,
  accessDenied,
  dataCorrupt,
  temporarilyUnavailable,
  internalError,
}

/// Raised by the application query layer. Carries only the fixed code and
/// never leaks raw cause text.
final class StudyQueryException implements Exception {
  const StudyQueryException(this.failure);

  final StudyQueryFailure failure;

  /// Whether retrying the same request may succeed later.
  bool get retryable => failure == StudyQueryFailure.temporarilyUnavailable;

  @override
  String toString() {
    return 'StudyQueryException(${failure.name}): ${_fixedMessage(failure)}';
  }
}

String _fixedMessage(StudyQueryFailure failure) {
  return switch (failure) {
    StudyQueryFailure.invalidRequest => 'The request is invalid.',
    StudyQueryFailure.notFound => 'The requested object was not found.',
    StudyQueryFailure.accessDenied => 'Access to the requested data is denied.',
    StudyQueryFailure.dataCorrupt => 'The stored data cannot be read safely.',
    StudyQueryFailure.temporarilyUnavailable =>
      'The data source is temporarily unavailable.',
    StudyQueryFailure.internalError => 'An internal error occurred.',
  };
}
