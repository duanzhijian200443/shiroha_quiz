library;

import '../../application/backup/backup_restore_gate.dart';
import '../../application/file_library/file_library_ports.dart';
import '../../application/file_library/library_file_deletion.dart';
import '../../core/observability/log_writer.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../services/file_library/managed_file_storage.dart';

/// Application orchestration for the formal LibraryFile delete authority.
///
/// The database transaction is the primary commit point. Managed bytes are
/// checked for ownership before that transaction and deleted only after it
/// commits. Cleanup failure is reported as an observable orphan outcome and
/// never changes the already-committed DB result.
final class LibraryFileDeletionService implements LibraryFileDeletionPort {
  LibraryFileDeletionService({
    required LibraryFileRepositoryPort metadataRepository,
    required LibraryFileDeletionPersistencePort deletionRepository,
    required ManagedFileStorage managedFileStorage,
  })  : _metadataRepository = metadataRepository,
        _deletionRepository = deletionRepository,
        _managedFileStorage = managedFileStorage;

  final LibraryFileRepositoryPort _metadataRepository;
  final LibraryFileDeletionPersistencePort _deletionRepository;
  final ManagedFileStorage _managedFileStorage;

  @override
  Future<LibraryFileDeletionResult> deleteLibraryFile(String fileId) {
    return BackupRestoreMutationGate.instance.runMutation(
      () => _deleteUnchecked(fileId),
    );
  }

  Future<LibraryFileDeletionResult> _deleteUnchecked(String fileId) async {
    try {
      final file = await _metadataRepository.findById(fileId);
      if (file == null) {
        throw const LibraryFileDeletionException(
          LibraryFileDeletionFailure.fileNotFound,
        );
      }

      final expectedStorageKey = _expectedStorageKey(file.fileId);
      if (file.storageKey != expectedStorageKey) {
        throw const LibraryFileDeletionException(
          LibraryFileDeletionFailure.managedBytesOwnershipUnknown,
        );
      }

      // This call commits the DB row and all relation detaches before any
      // physical delete is attempted.
      final commit = await _deletionRepository.deleteLibraryFile(
        fileId: file.fileId,
        expectedStorageKey: expectedStorageKey,
      );
      final cleanup = await _cleanupManagedBytes(commit.file);
      return LibraryFileDeletionResult(
        fileId: commit.file.fileId,
        projectReferenceCount: commit.projectReferenceCount,
        conversationReferenceCount: commit.conversationReferenceCount,
        managedBytesCleanup: cleanup,
      );
    } on LibraryFileDeletionException {
      rethrow;
    } on BackupException {
      rethrow;
    } on FormatException {
      throw const LibraryFileDeletionException(
        LibraryFileDeletionFailure.dataCorrupt,
      );
    } catch (_) {
      throw const LibraryFileDeletionException(
        LibraryFileDeletionFailure.transactionFailed,
      );
    }
  }

  String _expectedStorageKey(String fileId) {
    try {
      return _managedFileStorage.allocateStorageKey(fileId);
    } catch (_) {
      throw const LibraryFileDeletionException(
        LibraryFileDeletionFailure.managedBytesOwnershipUnknown,
      );
    }
  }

  Future<LibraryFileManagedBytesCleanup> _cleanupManagedBytes(
    LibraryFile file,
  ) async {
    try {
      if (!await _managedFileStorage.managedFileExists(file.storageKey)) {
        return LibraryFileManagedBytesCleanup.alreadyAbsent;
      }
      await _managedFileStorage.deleteManagedFile(file.storageKey);
      return LibraryFileManagedBytesCleanup.deleted;
    } catch (_) {
      try {
        LogWriter.error(
          'Library file managed bytes cleanup pending',
          module: 'LibraryFile',
          data: <String, Object?>{
            'fileId': file.fileId,
            'status': 'orphaned',
            'retryable': true,
          },
        );
      } catch (_) {
        // Observability is best effort and cannot change the primary result.
      }
      return LibraryFileManagedBytesCleanup.orphaned;
    }
  }
}
