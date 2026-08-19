import 'package:sqflite/sqflite.dart';

import '../../application/file_library/file_library_ports.dart';
import '../../application/file_library/library_file_deletion.dart';
import '../../core/database/database_helper.dart';
import '../../domain/assets/library_file.dart';

/// SQLite repository for [LibraryFile] metadata rows.
///
/// Only metadata is stored here; original bytes live in app-managed storage
/// behind the storage port. Rows never contain an absolute path, a project
/// id, OCR payloads, embeddings, or question-bank ownership.
class LibraryFileRepository
    implements LibraryFileRepositoryPort, LibraryFileDeletionPersistencePort {
  LibraryFileRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  static const String _table = 'library_files';

  /// Persists one metadata row. Fails (with zero writes) when [file] is
  /// invalid or the row already exists.
  @override
  Future<void> save(LibraryFile file) async {
    final db = await _databaseHelper.database;
    await db.insert(_table, _toRow(file));
  }

  @override
  Future<LibraryFile?> findById(String fileId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _table,
      where: 'file_id = ?',
      whereArgs: <Object?>[fileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  @override
  Future<List<LibraryFile>> findAll() async {
    final db = await _databaseHelper.database;
    final rows = await db.query(_table, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Removes one LibraryFile row and its relation rows in one DB transaction.
  ///
  /// The returned commit evidence is consumed by the application deletion
  /// service, which performs managed-byte cleanup only after this transaction
  /// has committed. Project and Conversation relations are detached; their
  /// primary rows are never owned by this operation.
  @override
  Future<LibraryFileDeletionCommit> deleteLibraryFile({
    required String fileId,
    required String expectedStorageKey,
  }) async {
    final db = await _databaseHelper.database;
    try {
      return await db.transaction((txn) async {
        final rows = await txn.query(
          _table,
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw const LibraryFileDeletionException(
            LibraryFileDeletionFailure.fileNotFound,
          );
        }
        final file = _fromRow(rows.single);
        if (file.storageKey != expectedStorageKey) {
          throw const LibraryFileDeletionException(
            LibraryFileDeletionFailure.managedBytesOwnershipUnknown,
          );
        }

        final projectReferenceCount = await _countReferences(
          txn,
          table: 'project_files',
          fileId: fileId,
        );
        final conversationReferenceCount = await _countReferences(
          txn,
          table: 'conversation_files',
          fileId: fileId,
        );

        // These are relation rows, not owners of the managed bytes. Remove
        // them inside the same transaction as the primary row.
        await txn.delete(
          'project_files',
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
        );
        await txn.delete(
          'conversation_files',
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
        );
        await txn.delete(
          'library_file_folders',
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
        );

        final deleted = await txn.delete(
          _table,
          where: 'file_id = ? AND storage_key = ?',
          whereArgs: <Object?>[fileId, expectedStorageKey],
        );
        if (deleted != 1) {
          throw const LibraryFileDeletionException(
            LibraryFileDeletionFailure.transactionFailed,
          );
        }
        return LibraryFileDeletionCommit(
          file: file,
          projectReferenceCount: projectReferenceCount,
          conversationReferenceCount: conversationReferenceCount,
        );
      });
    } on LibraryFileDeletionException {
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

  Future<int> _countReferences(
    DatabaseExecutor txn, {
    required String table,
    required String fileId,
  }) async {
    final rows = await txn.rawQuery(
      'SELECT COUNT(*) AS count FROM $table WHERE file_id = ?',
      <Object?>[fileId],
    );
    return (rows.single['count']! as num).toInt();
  }

  Map<String, Object?> _toRow(LibraryFile file) {
    return <String, Object?>{
      'file_id': file.fileId,
      'display_name': file.displayName,
      'mime_type': file.mimeType,
      'size_bytes': file.sizeBytes,
      'sha256': file.sha256,
      'storage_key': file.storageKey,
      'created_at': file.createdAt.millisecondsSinceEpoch,
    };
  }

  LibraryFile _fromRow(Map<String, Object?> row) {
    return LibraryFile(
      fileId: row['file_id']! as String,
      displayName: row['display_name']! as String,
      mimeType: row['mime_type']! as String,
      sizeBytes: row['size_bytes']! as int,
      sha256: row['sha256']! as String,
      storageKey: row['storage_key']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
    );
  }
}
