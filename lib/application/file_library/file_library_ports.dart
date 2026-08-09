library;

import '../../domain/assets/library_file.dart';

/// Application-facing persistence port for F0 File Library metadata.
abstract interface class LibraryFileRepositoryPort {
  Future<void> save(LibraryFile file);

  Future<LibraryFile?> findById(String fileId);

  Future<List<LibraryFile>> findAll();
}

/// Application-facing ingestion port.
///
/// [externalPath] is an ephemeral picker result. Implementations must never
/// return it, log it, or persist it as File Library identity.
abstract interface class FileIngestionPort {
  Future<LibraryFile> ingest({
    required String externalPath,
    required String displayName,
    String? mimeType,
  });
}
