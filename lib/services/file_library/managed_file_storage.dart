import 'dart:io';

/// Result of one successful managed copy.
///
/// [sha256] is the lowercase hex digest of the copied bytes and [sizeBytes]
/// the exact number of bytes written, both measured by the storage adapter
/// while it copies.
final class ManagedFileCopyResult {
  const ManagedFileCopyResult({
    required this.storageKey,
    required this.sha256,
    required this.sizeBytes,
  });

  final String storageKey;
  final String sha256;
  final int sizeBytes;
}

/// Port for app-managed file storage (F0).
///
/// Responsibilities:
/// - allocate a safe relative managed identity (storage key);
/// - copy external bytes into the managed root (never move/delete the
///   external original);
/// - resolve a trusted internal file, enforce existence/integrity;
/// - clean up managed files after failed ingestion;
/// - enforce root containment against `..`, absolute keys, drive escapes,
///   and path traversal.
///
/// Only implementations of this port may parse physical absolute paths.
/// Durable identity is `fileId + storageKey`; absolute paths are never part
/// of the public contract.
abstract interface class ManagedFileStorage {
  /// Allocates the safe relative managed identity for [fileId].
  ///
  /// Throws [ManagedFileStorageException] when [fileId] cannot produce a
  /// safe relative key.
  String allocateStorageKey(String fileId);

  /// Copies [externalPath] bytes into the managed root under [storageKey].
  ///
  /// The external source is only read. On success the managed bytes exist
  /// and the returned digest/size describe exactly those bytes. On failure
  /// no managed file remains and no partial file is left behind.
  Future<ManagedFileCopyResult> copyIntoManagedStorage({
    required String externalPath,
    required String storageKey,
  });

  /// Resolves a trusted internal [storageKey] to a physical [File].
  ///
  /// The returned file is guaranteed to be inside the managed root; the
  /// caller may check existence separately with [managedFileExists].
  File resolveManagedFile(String storageKey);

  /// Whether the managed file for [storageKey] currently exists.
  Future<bool> managedFileExists(String storageKey);

  /// Deletes the managed file for [storageKey] if it exists.
  Future<void> deleteManagedFile(String storageKey);
}
