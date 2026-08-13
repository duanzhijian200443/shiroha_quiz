/// S0 bounded credential seam for AI/OCR/Agent engine credentials.
///
/// The secure credential store is the sole credential authority for engine
/// API keys. SQLite stores metadata only and is never a credential fallback.
/// Implementations must namespace keys by the stable engine identity:
/// `engine.<engineId>`.
library;

/// Typed failure states for engine credential access.
enum EngineCredentialFailure {
  /// No credential exists for the engine id (read returns null instead).
  missing,

  /// The stored value exists but is invalid (for example NUL bytes or
  /// violated bounds).
  dataCorrupt,

  /// The secure store could not be reached right now.
  temporarilyUnavailable,
}

/// Thrown for typed credential failures. `toString()` never contains the
/// secret, a raw cause, or a path.
final class EngineCredentialException implements Exception {
  const EngineCredentialException(this.failure);

  final EngineCredentialFailure failure;

  @override
  String toString() => 'EngineCredentialException(${failure.name})';
}

/// Thrown when an operation failed and compensation succeeded, restoring the
/// prior state (FAILED(compensated)).
final class EngineCredentialCompensatedException implements Exception {
  const EngineCredentialCompensatedException();

  @override
  String toString() => 'EngineCredentialCompensatedException';
}

/// Thrown when an operation failed and a pre-existing corrupt credential was
/// normalized to missing (FAILED(normalized)); this is safe normalization,
/// not restoration of the original state.
final class EngineCredentialNormalizedException implements Exception {
  const EngineCredentialNormalizedException();

  @override
  String toString() => 'EngineCredentialNormalizedException';
}

/// Thrown when an operation failed and compensation also failed
/// (PARTIAL_FAILED): the two stores are left in a mixed state that must be
/// reconciled by a later same-id save or delete.
final class EngineCredentialPartialException implements Exception {
  const EngineCredentialPartialException(this.failure);

  final EngineCredentialFailure failure;

  @override
  String toString() => 'EngineCredentialPartialException(${failure.name})';
}

/// Bounded credential port.
///
/// - [readCredential] returns the secret when present, `null` only for a
///   genuine missing credential, and throws [EngineCredentialException] for
///   `temporarilyUnavailable` / `dataCorrupt` otherwise. Unavailable/corrupt
///   must never be folded into missing.
/// - [writeCredential] replaces the credential for [engineId].
/// - [deleteCredential] removes the credential and is idempotent.
///
/// Every input must pass [validatedEngineCredentialId] /
/// [validatedEngineCredentialSecret] before any IO; invalid input is rejected
/// with [ArgumentError] carrying a fixed message that never echoes the value.
abstract interface class EngineCredentialStore {
  Future<String?> readCredential(String engineId);

  Future<void> writeCredential(String engineId, String secret);

  Future<void> deleteCredential(String engineId);
}

/// Maximum credential secret length in runes.
const int engineCredentialMaxSecretRunes = 4096;

/// Maximum engine id length in runes.
const int engineCredentialMaxIdRunes = 128;

/// Validates a stable engine id: non-empty, bounded, no NUL, no control
/// characters, and no path separator. Returns the id unchanged or throws
/// [ArgumentError] with a fixed message that never echoes the value.
String validatedEngineCredentialId(String engineId) {
  if (engineId.isEmpty ||
      engineId.runes.length > engineCredentialMaxIdRunes ||
      engineId.contains('\u0000') ||
      engineId.contains('/') ||
      engineId.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError('invalid engine credential id');
  }
  return engineId;
}

/// Validates a credential secret: non-empty, bounded, no NUL. Returns the
/// secret unchanged or throws [ArgumentError] with a fixed message that never
/// echoes the value.
String validatedEngineCredentialSecret(String secret) {
  if (secret.isEmpty ||
      secret.runes.length > engineCredentialMaxSecretRunes ||
      secret.contains('\u0000')) {
    throw ArgumentError('invalid engine credential secret');
  }
  return secret;
}
