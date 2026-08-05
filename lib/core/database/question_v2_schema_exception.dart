/// Failure taxonomy of the frozen v15 additive schema boundary.
enum QuestionV2SchemaFailure {
  unsupportedSourceVersion,
  malformedParentSchema,
  malformedSidecarSchema,
  foreignKeysDisabled,
  foreignKeyViolation,
}

/// Raised when the v15 schema cannot be opened or migrated safely.
///
/// The exception retains no raw cause, path, SQL, schema text, row, or
/// SQLite exception. Public construction accepts only the fixed failure
/// taxonomy and [toString] renders one fixed safe message per failure.
final class QuestionV2SchemaException implements Exception {
  const QuestionV2SchemaException(this.failure);

  final QuestionV2SchemaFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      QuestionV2SchemaFailure.unsupportedSourceVersion =>
        'The source database version is below the supported migration floor.',
      QuestionV2SchemaFailure.malformedParentSchema =>
        'The parent schema does not satisfy the frozen v15 requirements.',
      QuestionV2SchemaFailure.malformedSidecarSchema =>
        'The question_v2_payloads sidecar does not match the frozen '
            'definition.',
      QuestionV2SchemaFailure.foreignKeysDisabled =>
        'Foreign key enforcement is disabled on the opened connection.',
      QuestionV2SchemaFailure.foreignKeyViolation =>
        'The database contains foreign key violations.',
    };
    return 'QuestionV2SchemaException(${failure.name}): $detail';
  }
}
