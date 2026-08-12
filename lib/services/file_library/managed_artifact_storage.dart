/// Result of one immutable artifact sidecar finalize.
///
/// [sha256] is the lowercase hex digest of the written bytes and [sizeBytes]
/// the exact number of bytes written, both measured by the storage adapter.
final class ArtifactWriteResult {
  const ArtifactWriteResult({
    required this.storageKey,
    required this.sha256,
    required this.sizeBytes,
  });

  final String storageKey;
  final String sha256;
  final int sizeBytes;
}

/// Result of one validated artifact sidecar read.
final class ArtifactReadResult {
  const ArtifactReadResult({
    required this.bytes,
    required this.sha256,
    required this.sizeBytes,
  });

  final List<int> bytes;
  final String sha256;
  final int sizeBytes;
}

enum ManagedArtifactStorageFailure {
  unsafeArtifactId,
  unsafeStorageKey,
  alreadyFinalized,
  sizeMismatch,
  digestMismatch,
  ioFailed,
}

/// Safe failure for the managed artifact sidecar boundary.
///
/// The exception retains no raw cause, path, storage key, or bytes;
/// [toString] renders one fixed safe message per failure.
final class ManagedArtifactStorageException implements Exception {
  const ManagedArtifactStorageException(this.failure);

  final ManagedArtifactStorageFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ManagedArtifactStorageFailure.unsafeArtifactId =>
        'The artifact identity cannot produce a safe storage key.',
      ManagedArtifactStorageFailure.unsafeStorageKey =>
        'The storage key is not a safe relative managed identity.',
      ManagedArtifactStorageFailure.alreadyFinalized =>
        'An immutable artifact sidecar already exists at that storage key.',
      ManagedArtifactStorageFailure.sizeMismatch =>
        'The artifact sidecar size does not match its metadata.',
      ManagedArtifactStorageFailure.digestMismatch =>
        'The artifact sidecar digest does not match its metadata.',
      ManagedArtifactStorageFailure.ioFailed =>
        'The artifact sidecar operation could not be completed.',
    };
    return 'ManagedArtifactStorageException(${failure.name}): $detail';
  }
}

/// Port for app-managed immutable artifact sidecars (D1).
///
/// Durable identity is the safe relative [storageKey] only; absolute paths
/// exist solely inside implementations. Sidecars are immutable once
/// finalized: writing an existing key fails, reads validate existence, size
/// and digest, and deletes are idempotent candidate/orphan cleanup.
abstract interface class ManagedArtifactStorage {
  /// Allocates the safe relative storage key for [artifactId].
  String allocateArtifactStorageKey(String artifactId);

  /// Writes [bytes] to a fresh immutable sidecar under [storageKey].
  ///
  /// The write stages a temporary file, flushes it, computes the SHA-256
  /// digest and exact size of the written bytes, then atomically finalizes
  /// it. An existing finalized sidecar is never overwritten.
  Future<ArtifactWriteResult> writeArtifact({
    required String storageKey,
    required List<int> bytes,
  });

  /// Reads and validates the sidecar under [storageKey].
  ///
  /// Returns null when the sidecar is absent. When [expectedSha256] or
  /// [expectedSizeBytes] is provided and mismatches, throws a typed
  /// [ManagedArtifactStorageException] instead of returning corrupt bytes.
  Future<ArtifactReadResult?> readArtifact({
    required String storageKey,
    String? expectedSha256,
    int? expectedSizeBytes,
  });

  /// Deletes the sidecar under [storageKey] if present; deleting an absent
  /// sidecar is a no-op.
  Future<void> deleteArtifact(String storageKey);
}
