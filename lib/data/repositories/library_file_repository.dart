import '../../core/database/database_helper.dart';
import '../../domain/assets/library_file.dart';
import '../../application/file_library/file_library_ports.dart';

/// SQLite repository for [LibraryFile] metadata rows.
///
/// Only metadata is stored here; original bytes live in app-managed storage
/// behind the storage port. Rows never contain an absolute path, a project
/// id, OCR payloads, embeddings, or question-bank ownership.
class LibraryFileRepository implements LibraryFileRepositoryPort {
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
