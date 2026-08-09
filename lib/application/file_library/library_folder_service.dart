library;

import '../../domain/assets/library_file.dart';
import '../../domain/assets/library_folder.dart';
import 'library_folder_repository.dart';

/// Reusable F0.1 application semantics for flat File Library folders.
final class LibraryFolderService {
  LibraryFolderService({
    required LibraryFolderRepositoryPort repository,
    required String Function() folderIdFactory,
  })  : _repository = repository,
        _folderIdFactory = folderIdFactory;

  final LibraryFolderRepositoryPort _repository;
  final String Function() _folderIdFactory;

  Future<List<LibraryFolder>> listFolders() => _repository.listFolders();

  Future<LibraryFolder?> findFolder(String folderId) =>
      _repository.findFolder(folderId);

  Future<LibraryFolder> createFolder(String displayName) async {
    final normalizedName = _normalizeName(displayName);
    final LibraryFolder folder;
    try {
      folder = LibraryFolder(
        folderId: _folderIdFactory(),
        displayName: normalizedName,
        createdAt: DateTime.now().toUtc(),
      );
    } on FormatException {
      throw const LibraryFolderException(
        LibraryFolderFailure.folderIdConflict,
      );
    }
    await _repository.createFolder(folder);
    return folder;
  }

  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  }) {
    return _repository.renameFolder(
      folderId: folderId,
      displayName: _normalizeName(displayName),
    );
  }

  Future<void> deleteFolder(String folderId) =>
      _repository.deleteFolder(folderId);

  Future<LibraryFolder?> getFolderForFile(String fileId) =>
      _repository.getFolderForFile(fileId);

  Future<void> moveFileToFolder({
    required String fileId,
    required String folderId,
  }) =>
      _repository.moveFileToFolder(fileId: fileId, folderId: folderId);

  Future<void> removeFileFromFolder(String fileId) =>
      _repository.removeFileFromFolder(fileId);

  Future<List<LibraryFile>> listFilesInFolder(String folderId) =>
      _repository.listFilesInFolder(folderId);

  Future<List<LibraryFile>> listUnclassifiedFiles() =>
      _repository.listUnclassifiedFiles();

  static String _normalizeName(String displayName) {
    try {
      return LibraryFolder.normalizeDisplayName(displayName);
    } on FormatException {
      throw const LibraryFolderException(LibraryFolderFailure.invalidName);
    }
  }
}
