library;

import '../../domain/assets/library_file.dart';
import '../../domain/assets/library_folder.dart';

/// Application-facing persistence port for F0.1 flat File Library folders.
abstract interface class LibraryFolderRepositoryPort {
  Future<void> createFolder(LibraryFolder folder);

  Future<List<LibraryFolder>> listFolders();

  Future<LibraryFolder?> findFolder(String folderId);

  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  });

  /// Deletes folder metadata and membership rows only.
  Future<void> deleteFolder(String folderId);

  /// Returns null for an existing unclassified file.
  Future<LibraryFolder?> getFolderForFile(String fileId);

  /// Atomically inserts or replaces the file's single folder membership.
  Future<void> moveFileToFolder({
    required String fileId,
    required String folderId,
  });

  /// Idempotently removes membership for an existing file.
  Future<void> removeFileFromFolder(String fileId);

  Future<List<LibraryFile>> listFilesInFolder(String folderId);

  Future<List<LibraryFile>> listUnclassifiedFiles();
}

enum LibraryFolderFailure {
  invalidName,
  duplicateName,
  folderNotFound,
  fileNotFound,
  folderIdConflict,
  dataCorrupt,
  temporarilyUnavailable,
}

/// Fixed, path/SQL/payload-free failure exposed by the Application boundary.
final class LibraryFolderException implements Exception {
  const LibraryFolderException(this.failure);

  final LibraryFolderFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      LibraryFolderFailure.invalidName => 'The folder name is invalid.',
      LibraryFolderFailure.duplicateName =>
        'A folder with that name already exists.',
      LibraryFolderFailure.folderNotFound => 'The folder does not exist.',
      LibraryFolderFailure.fileNotFound => 'The library file does not exist.',
      LibraryFolderFailure.folderIdConflict =>
        'The generated folder identifier is already in use.',
      LibraryFolderFailure.dataCorrupt =>
        'The stored folder metadata is invalid.',
      LibraryFolderFailure.temporarilyUnavailable =>
        'Folder storage is temporarily unavailable.',
    };
    return 'LibraryFolderException(${failure.name}): $detail';
  }
}
