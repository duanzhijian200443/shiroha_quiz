library;

import '../../domain/assets/library_file.dart';
import '../../domain/assets/parsed_artifact.dart';

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _routePattern = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$');
final _versionPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _controlPattern = RegExp(r'[\u0000-\u001f\u007f]');

/// Immutable current-row metadata for one parsed artifact generation.
///
/// [artifact] carries the D0 identity values (fileId, artifactId, revision,
/// payloadSchemaVersion); the remaining fields mirror the frozen v20
/// `parsed_artifacts` current row. Every value is bounded-validated at
/// construction; this value never exposes raw SQLite rows or absolute paths.
final class ParsedArtifactMetadata {
  ParsedArtifactMetadata({
    required this.artifact,
    required String sourceSha256,
    required int cacheKeyVersion,
    required String cacheFingerprint,
    required String parserRoute,
    required String parserVersion,
    required int optionsSchemaVersion,
    required String storageKey,
    required String payloadSha256,
    required int sizeBytes,
    required int publishedAt,
  })  : sourceSha256 = _validateSha256(sourceSha256, 'sourceSha256'),
        cacheKeyVersion = _validatePositive(cacheKeyVersion, 'cacheKeyVersion'),
        cacheFingerprint = _validateFingerprint(cacheFingerprint),
        parserRoute = _validateRoute(parserRoute),
        parserVersion = _validateVersion(parserVersion),
        optionsSchemaVersion =
            _validatePositive(optionsSchemaVersion, 'optionsSchemaVersion'),
        storageKey = _validateStorageKey(storageKey),
        payloadSha256 = _validateSha256(payloadSha256, 'payloadSha256'),
        sizeBytes = _validateNonNegative(sizeBytes, 'sizeBytes'),
        publishedAt = _validateNonNegative(publishedAt, 'publishedAt');

  final ParsedArtifact artifact;
  final String sourceSha256;
  final int cacheKeyVersion;
  final String cacheFingerprint;
  final String parserRoute;
  final String parserVersion;
  final int optionsSchemaVersion;
  final String storageKey;
  final String payloadSha256;
  final int sizeBytes;
  final int publishedAt;

  String get fileId => artifact.fileId;
  String get artifactId => artifact.artifactId;
  int get revision => artifact.revision;
  int get payloadSchemaVersion => artifact.payloadSchemaVersion;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifactMetadata &&
            artifact == other.artifact &&
            sourceSha256 == other.sourceSha256 &&
            cacheKeyVersion == other.cacheKeyVersion &&
            cacheFingerprint == other.cacheFingerprint &&
            parserRoute == other.parserRoute &&
            parserVersion == other.parserVersion &&
            optionsSchemaVersion == other.optionsSchemaVersion &&
            storageKey == other.storageKey &&
            payloadSha256 == other.payloadSha256 &&
            sizeBytes == other.sizeBytes &&
            publishedAt == other.publishedAt;
  }

  @override
  int get hashCode => Object.hash(
        artifact,
        sourceSha256,
        cacheKeyVersion,
        cacheFingerprint,
        parserRoute,
        parserVersion,
        optionsSchemaVersion,
        storageKey,
        payloadSha256,
        sizeBytes,
        publishedAt,
      );
}

enum ParsedArtifactPublishStatus { published, parentMissing, revisionConflict }

/// Typed result of one publish-current CAS primitive.
///
/// A CAS loser returns [ParsedArtifactPublishStatus.revisionConflict] with
/// the actual head revision; no metadata row is mutated. A publish whose
/// parent `LibraryFile` row is missing returns
/// [ParsedArtifactPublishStatus.parentMissing].
final class ParsedArtifactPublishResult {
  const ParsedArtifactPublishResult._(
    this.status, {
    this.current,
    this.actualRevision,
  });

  const ParsedArtifactPublishResult.published(ParsedArtifactMetadata current)
      : this._(ParsedArtifactPublishStatus.published, current: current);

  const ParsedArtifactPublishResult.parentMissing()
      : this._(ParsedArtifactPublishStatus.parentMissing);

  const ParsedArtifactPublishResult.revisionConflict(int actualRevision)
      : this._(
          ParsedArtifactPublishStatus.revisionConflict,
          actualRevision: actualRevision,
        );

  final ParsedArtifactPublishStatus status;
  final ParsedArtifactMetadata? current;
  final int? actualRevision;
}

enum ParsedArtifactRemoveStatus { removed, notFound, revisionConflict }

/// Typed result of one remove-current CAS primitive.
///
/// Removal deletes the current row but preserves the revision head; a stale
/// [ParsedArtifactRemoveStatus.revisionConflict] mutates nothing.
final class ParsedArtifactRemoveResult {
  const ParsedArtifactRemoveResult._(
    this.status, {
    this.actualRevision,
  });

  const ParsedArtifactRemoveResult.removed()
      : this._(ParsedArtifactRemoveStatus.removed);

  const ParsedArtifactRemoveResult.notFound()
      : this._(ParsedArtifactRemoveStatus.notFound);

  const ParsedArtifactRemoveResult.revisionConflict(int actualRevision)
      : this._(
          ParsedArtifactRemoveStatus.revisionConflict,
          actualRevision: actualRevision,
        );

  final ParsedArtifactRemoveStatus status;
  final int? actualRevision;
}

/// Application-facing persistence port for D1 parsed-artifact metadata
/// primitives. Implementations never expose raw SQLite maps or rows.
abstract interface class ParsedArtifactRepositoryPort {
  /// Reads the current artifact metadata for [fileId], or null when absent.
  Future<ParsedArtifactMetadata?> findCurrentByFileId(String fileId);

  /// Reads the retained revision head for [fileId]; 0 when no head exists.
  Future<int> readRevisionHead(String fileId);

  /// Atomically publishes [candidate] as the current artifact when
  /// [expectedRevision] equals the current head and
  /// `candidate.revision == expectedRevision + 1`.
  Future<ParsedArtifactPublishResult> publishCurrent({
    required String fileId,
    required ParsedArtifactMetadata candidate,
    required int expectedRevision,
  });

  /// Atomically removes the current artifact when [expectedRevision] matches
  /// the retained head, preserving the head for later publications.
  Future<ParsedArtifactRemoveResult> removeCurrent({
    required String fileId,
    required int expectedRevision,
  });
}

enum ParsedArtifactRepositoryFailure {
  invalidRequest,
  duplicateIdentity,
  unavailable,
}

/// Safe persistence failure for the parsed-artifact repository boundary.
///
/// The exception retains no raw cause, SQL, row, or SQLite exception;
/// [toString] renders one fixed safe message per failure.
final class ParsedArtifactRepositoryException implements Exception {
  const ParsedArtifactRepositoryException(this.failure);

  final ParsedArtifactRepositoryFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ParsedArtifactRepositoryFailure.invalidRequest =>
        'The parsed artifact request is invalid.',
      ParsedArtifactRepositoryFailure.duplicateIdentity =>
        'A parsed artifact identity or storage key is already in use.',
      ParsedArtifactRepositoryFailure.unavailable =>
        'The parsed artifact persistence layer is temporarily unavailable.',
    };
    return 'ParsedArtifactRepositoryException(${failure.name}): $detail';
  }
}

String _validateSha256(String value, String label) {
  if (!_sha256Pattern.hasMatch(value)) {
    throw FormatException('$label must be lowercase SHA-256 hex.');
  }
  return value;
}

int _validatePositive(int value, String label) {
  if (value <= 0) {
    throw FormatException('$label must be a positive integer.');
  }
  return value;
}

int _validateNonNegative(int value, String label) {
  if (value < 0) {
    throw FormatException('$label must be a non-negative integer.');
  }
  return value;
}

String _validateFingerprint(String value) {
  if (value.isEmpty || value.length > 128 || _controlPattern.hasMatch(value)) {
    throw const FormatException(
      'Cache fingerprints must be bounded opaque strings.',
    );
  }
  return value;
}

String _validateRoute(String value) {
  if (value.length > 64 || !_routePattern.hasMatch(value)) {
    throw const FormatException(
      'Parser routes must use bounded lower snake case.',
    );
  }
  return value;
}

String _validateVersion(String value) {
  if (value.length > 64 || !_versionPattern.hasMatch(value)) {
    throw const FormatException(
      'Parser versions must use bounded opaque tokens.',
    );
  }
  return value;
}

String _validateStorageKey(String value) {
  if (!LibraryFile.isSafeStorageKey(value)) {
    throw const FormatException(
      'Artifact storage keys must be safe relative managed identities.',
    );
  }
  return value;
}
