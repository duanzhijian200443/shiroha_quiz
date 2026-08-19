library;

import '../../domain/assets/library_file.dart';

/// Application authority for the explicit LibraryFile destructive operation.
///
/// Project and Conversation references are relations, not byte ownership.
/// Implementations report the references observed in the same database
/// transaction that removes the file row.
abstract interface class LibraryFileDeletionPort {
  Future<LibraryFileDeletionResult> deleteLibraryFile(String fileId);
}

/// Persistence seam for the DB-first LibraryFile delete.
///
/// The implementation must commit the metadata/relation mutation before the
/// caller performs any managed-byte cleanup.
abstract interface class LibraryFileDeletionPersistencePort {
  Future<LibraryFileDeletionCommit> deleteLibraryFile({
    required String fileId,
    required String expectedStorageKey,
  });
}

enum LibraryFileDeletionFailure {
  unavailable,
  fileNotFound,
  dataCorrupt,
  managedBytesOwnershipUnknown,
  transactionFailed,
}

final class LibraryFileDeletionException implements Exception {
  const LibraryFileDeletionException(this.failure);

  final LibraryFileDeletionFailure failure;

  @override
  String toString() => 'LibraryFileDeletionException(${failure.name})';
}

/// Primary DB commit evidence returned by the persistence boundary.
final class LibraryFileDeletionCommit {
  const LibraryFileDeletionCommit({
    required this.file,
    required this.projectReferenceCount,
    required this.conversationReferenceCount,
  });

  final LibraryFile file;
  final int projectReferenceCount;
  final int conversationReferenceCount;
}

enum LibraryFileManagedBytesCleanup {
  deleted,
  alreadyAbsent,
  orphaned,
}

/// Safe application result after the DB commit and best-effort byte cleanup.
final class LibraryFileDeletionResult {
  const LibraryFileDeletionResult({
    required this.fileId,
    required this.projectReferenceCount,
    required this.conversationReferenceCount,
    required this.managedBytesCleanup,
  });

  final String fileId;
  final int projectReferenceCount;
  final int conversationReferenceCount;
  final LibraryFileManagedBytesCleanup managedBytesCleanup;
}
