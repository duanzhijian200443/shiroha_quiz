/// Domain contracts for Answer Completion imported question sets.
///
/// An [ImportedQuestionSet] records the exact persisted questions created by
/// one successful top-level source-document commit. Durable question identity
/// stays `PersistedQuestion.storageId`; membership never introduces a second
/// question identity, `PaperQuestionId`, or `QuestionSetScope`.
library;

/// Inclusive Unicode-scalar bounds for an imported question set display name.
const int minImportedQuestionSetDisplayNameScalars = 1;
const int maxImportedQuestionSetDisplayNameScalars = 256;

/// Whether [value] is a canonical imported question set display name.
///
/// The frozen rule is 1–256 Unicode scalars with no path separator (`/`, `\`)
/// and no control character (C0 `U+0000`–`U+001F` or DEL/C1
/// `U+007F`–`U+009F`). The value is judged verbatim: it is never trimmed,
/// collapsed, or repaired.
bool isValidImportedQuestionSetDisplayName(String value) {
  var scalarCount = 0;
  for (final rune in value.runes) {
    scalarCount++;
    if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) {
      return false;
    }
    if (rune == 0x2f || rune == 0x5c) {
      return false;
    }
  }
  return scalarCount >= minImportedQuestionSetDisplayNameScalars &&
      scalarCount <= maxImportedQuestionSetDisplayNameScalars;
}

/// Fixed failure classification for imported question set value validation.
enum ImportedQuestionSetValidationFailure {
  invalidSetId,
  invalidBankName,
  invalidDisplayName,
  invalidCreatedAt,
  invalidSourceFileId,
  invalidQuestionStorageId,
  invalidPosition,
}

/// Safe fixed exception for imported question set value validation.
///
/// Carries only the failure classification. [toString] returns fixed text and
/// never includes rejected values, display names, source IDs, or paths.
final class ImportedQuestionSetValidationException implements Exception {
  const ImportedQuestionSetValidationException(this.failure);

  final ImportedQuestionSetValidationFailure failure;

  @override
  String toString() {
    return switch (failure) {
      ImportedQuestionSetValidationFailure.invalidSetId =>
        'Imported question set identity is invalid.',
      ImportedQuestionSetValidationFailure.invalidBankName =>
        'Imported question set bank name is invalid.',
      ImportedQuestionSetValidationFailure.invalidDisplayName =>
        'Imported question set display name is invalid.',
      ImportedQuestionSetValidationFailure.invalidCreatedAt =>
        'Imported question set creation timestamp is invalid.',
      ImportedQuestionSetValidationFailure.invalidSourceFileId =>
        'Imported question set source file reference is invalid.',
      ImportedQuestionSetValidationFailure.invalidQuestionStorageId =>
        'Imported question set item storage identity is invalid.',
      ImportedQuestionSetValidationFailure.invalidPosition =>
        'Imported question set item position is invalid.',
    };
  }
}

/// Immutable durable identity of one successful source-document import.
///
/// [setId] is an opaque durable identity that must never be derived from
/// filename, task, artifact, or locator. [bankName] is the current
/// compatibility bank identity. [displayName] is a bounded display snapshot
/// that is never identity or matching evidence. [sourceFileId] is optional
/// soft provenance: it does not own the source file, and `null` means "no
/// provenance" rather than "file deleted".
///
/// Only locally provable value validation happens here; bank membership,
/// set emptiness, membership uniqueness, and source-file existence belong to
/// persistence and query stages.
final class ImportedQuestionSet {
  ImportedQuestionSet({
    required String setId,
    required String bankName,
    required String displayName,
    required int createdAt,
    String? sourceFileId,
  })  : setId = _requireNonEmpty(
          setId,
          ImportedQuestionSetValidationFailure.invalidSetId,
        ),
        bankName = _requireNonEmpty(
          bankName,
          ImportedQuestionSetValidationFailure.invalidBankName,
        ),
        displayName = _requireDisplayName(displayName),
        createdAt = _requireCreatedAt(createdAt),
        sourceFileId = _requireSourceFileId(sourceFileId);

  final String setId;
  final String bankName;
  final String displayName;
  final int createdAt;
  final String? sourceFileId;
}

/// Immutable ordered membership of one question inside an [ImportedQuestionSet].
///
/// [position] records commit order and is never matching evidence.
final class ImportedQuestionSetItem {
  ImportedQuestionSetItem({
    required String setId,
    required String questionStorageId,
    required int position,
  })  : setId = _requireNonEmpty(
          setId,
          ImportedQuestionSetValidationFailure.invalidSetId,
        ),
        questionStorageId = _requireNonEmpty(
          questionStorageId,
          ImportedQuestionSetValidationFailure.invalidQuestionStorageId,
        ),
        position = _requirePosition(position);

  final String setId;
  final String questionStorageId;
  final int position;
}

String _requireNonEmpty(
  String value,
  ImportedQuestionSetValidationFailure failure,
) {
  if (value.isEmpty) {
    throw ImportedQuestionSetValidationException(failure);
  }
  return value;
}

String _requireDisplayName(String value) {
  if (!isValidImportedQuestionSetDisplayName(value)) {
    throw const ImportedQuestionSetValidationException(
      ImportedQuestionSetValidationFailure.invalidDisplayName,
    );
  }
  return value;
}

int _requireCreatedAt(int value) {
  if (value < 0) {
    throw const ImportedQuestionSetValidationException(
      ImportedQuestionSetValidationFailure.invalidCreatedAt,
    );
  }
  return value;
}

String? _requireSourceFileId(String? value) {
  if (value != null && value.isEmpty) {
    throw const ImportedQuestionSetValidationException(
      ImportedQuestionSetValidationFailure.invalidSourceFileId,
    );
  }
  return value;
}

int _requirePosition(int value) {
  if (value < 0) {
    throw const ImportedQuestionSetValidationException(
      ImportedQuestionSetValidationFailure.invalidPosition,
    );
  }
  return value;
}
