import 'package:uuid/uuid.dart';

import '../../data/repositories/library_file_repository.dart';
import '../../domain/assets/library_file.dart';
import 'managed_file_storage.dart';

/// F0 use case: external file -> managed copy + [LibraryFile] metadata.
///
/// Frozen semantics:
/// - ingestion copies and never moves/deletes the user's external original;
/// - durable identity is `fileId + storageKey`, never an absolute path;
/// - a failed metadata write deletes the just-copied managed bytes;
/// - a failed copy leaves no database row and no managed file;
/// - ingestion never triggers OCR, import, project, bank, or question work;
/// - two files with the same display name get different file ids and storage
///   keys, so they can never overwrite each other.
///
/// Presentation code depends on this service, not on the repository or the
/// storage adapter directly.
class FileIngestionService {
  FileIngestionService({
    required ManagedFileStorage storage,
    required LibraryFileRepository repository,
    Uuid? uuid,
  })  : _storage = storage,
        _repository = repository,
        _uuid = uuid ?? const Uuid();

  final ManagedFileStorage _storage;
  final LibraryFileRepository _repository;
  final Uuid _uuid;

  /// Ingests the file at [externalPath] into app-managed storage and records
  /// its metadata. [mimeType] defaults to `application/octet-stream` when
  /// omitted.
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  }) async {
    final fileId = _uuid.v4();
    final storageKey = _storage.allocateStorageKey(fileId);
    final copy = await _storage.copyIntoManagedStorage(
      externalPath: externalPath,
      storageKey: storageKey,
    );

    final LibraryFile file;
    try {
      file = LibraryFile(
        fileId: fileId,
        displayName: displayName,
        mimeType: mimeType ?? 'application/octet-stream',
        sizeBytes: copy.sizeBytes,
        sha256: copy.sha256,
        storageKey: storageKey,
        createdAt: DateTime.now().toUtc(),
      );
      await _repository.save(file);
    } catch (_) {
      // Metadata (or model validation) failed after the managed copy: the
      // just-copied bytes must not be left orphaned.
      await _storage.deleteManagedFile(storageKey);
      rethrow;
    }
    return file;
  }
}
