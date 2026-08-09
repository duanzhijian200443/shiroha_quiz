import 'package:sqflite/sqflite.dart';

import '../../application/file_library/library_folder_repository.dart';
import '../../core/database/database_helper.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/assets/library_folder.dart';

/// SQLite adapter for the F0.1 flat Folder contract.
///
/// It never reads or mutates Project, QuestionBank, question, sidecar, review,
/// or managed-file storage state.
final class SqliteLibraryFolderRepository
    implements LibraryFolderRepositoryPort {
  SqliteLibraryFolderRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  static const String _folders = 'library_folders';
  static const String _memberships = 'library_file_folders';
  static const String _files = 'library_files';

  @override
  Future<void> createFolder(LibraryFolder folder) async {
    await _write((db) async {
      await db.transaction((txn) async {
        if (await _folderIdExists(txn, folder.folderId)) {
          throw const LibraryFolderException(
            LibraryFolderFailure.folderIdConflict,
          );
        }
        if (await _folderNameExists(txn, folder.displayName)) {
          throw const LibraryFolderException(
            LibraryFolderFailure.duplicateName,
          );
        }
        await txn.insert(_folders, _folderToRow(folder));
      });
    });
  }

  @override
  Future<List<LibraryFolder>> listFolders() {
    return _read((db) async {
      final rows = await db.query(
        _folders,
        orderBy: 'created_at ASC, folder_id ASC',
      );
      return rows.map(_folderFromRow).toList(growable: false);
    });
  }

  @override
  Future<LibraryFolder?> findFolder(String folderId) {
    return _read((db) async {
      final rows = await db.query(
        _folders,
        where: 'folder_id = ?',
        whereArgs: <Object?>[folderId],
        limit: 1,
      );
      return rows.isEmpty ? null : _folderFromRow(rows.single);
    });
  }

  @override
  Future<LibraryFolder> renameFolder({
    required String folderId,
    required String displayName,
  }) {
    return _write((db) async {
      return db.transaction((txn) async {
        final rows = await txn.query(
          _folders,
          where: 'folder_id = ?',
          whereArgs: <Object?>[folderId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw const LibraryFolderException(
            LibraryFolderFailure.folderNotFound,
          );
        }
        final existing = _folderFromRow(rows.single);
        if (existing.displayName == displayName) return existing;
        if (await _folderNameExists(
          txn,
          displayName,
          excludingFolderId: folderId,
        )) {
          throw const LibraryFolderException(
            LibraryFolderFailure.duplicateName,
          );
        }
        final renamed = LibraryFolder(
          folderId: folderId,
          displayName: displayName,
          createdAt: existing.createdAt,
        );
        await txn.update(
          _folders,
          <String, Object?>{'display_name': renamed.displayName},
          where: 'folder_id = ?',
          whereArgs: <Object?>[folderId],
        );
        return renamed;
      });
    });
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    await _write((db) async {
      final deleted = await db.delete(
        _folders,
        where: 'folder_id = ?',
        whereArgs: <Object?>[folderId],
      );
      if (deleted == 0) {
        throw const LibraryFolderException(
          LibraryFolderFailure.folderNotFound,
        );
      }
    });
  }

  @override
  Future<LibraryFolder?> getFolderForFile(String fileId) {
    return _read((db) async {
      await _expectFile(db, fileId);
      final rows = await db.rawQuery(
        '''
        SELECT f.folder_id, f.display_name, f.created_at
        FROM $_memberships m
        JOIN $_folders f ON f.folder_id = m.folder_id
        WHERE m.file_id = ?
        LIMIT 1
        ''',
        <Object?>[fileId],
      );
      return rows.isEmpty ? null : _folderFromRow(rows.single);
    });
  }

  @override
  Future<void> moveFileToFolder({
    required String fileId,
    required String folderId,
  }) async {
    await _write((db) async {
      await db.transaction((txn) async {
        await _expectFile(txn, fileId);
        await _expectFolder(txn, folderId);
        final existing = await txn.query(
          _memberships,
          columns: const <String>['folder_id'],
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert(_memberships, <String, Object?>{
            'file_id': fileId,
            'folder_id': folderId,
          });
        } else if (existing.single['folder_id'] != folderId) {
          await txn.update(
            _memberships,
            <String, Object?>{'folder_id': folderId},
            where: 'file_id = ?',
            whereArgs: <Object?>[fileId],
          );
        }
      });
    });
  }

  @override
  Future<void> removeFileFromFolder(String fileId) async {
    await _write((db) async {
      await db.transaction((txn) async {
        await _expectFile(txn, fileId);
        await txn.delete(
          _memberships,
          where: 'file_id = ?',
          whereArgs: <Object?>[fileId],
        );
      });
    });
  }

  @override
  Future<List<LibraryFile>> listFilesInFolder(String folderId) {
    return _read((db) async {
      await _expectFolder(db, folderId);
      final rows = await db.rawQuery(
        '''
        SELECT lf.*
        FROM $_files lf
        JOIN $_memberships m ON m.file_id = lf.file_id
        WHERE m.folder_id = ?
        ORDER BY lf.created_at DESC, lf.file_id ASC
        ''',
        <Object?>[folderId],
      );
      return rows.map(_fileFromRow).toList(growable: false);
    });
  }

  @override
  Future<List<LibraryFile>> listUnclassifiedFiles() {
    return _read((db) async {
      final rows = await db.rawQuery('''
        SELECT lf.*
        FROM $_files lf
        LEFT JOIN $_memberships m ON m.file_id = lf.file_id
        WHERE m.file_id IS NULL
        ORDER BY lf.created_at DESC, lf.file_id ASC
      ''');
      return rows.map(_fileFromRow).toList(growable: false);
    });
  }

  Future<bool> _folderIdExists(DatabaseExecutor db, String folderId) async {
    final rows = await db.query(
      _folders,
      columns: const <String>['folder_id'],
      where: 'folder_id = ?',
      whereArgs: <Object?>[folderId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _folderNameExists(
    DatabaseExecutor db,
    String displayName, {
    String? excludingFolderId,
  }) async {
    final rows = await db.query(
      _folders,
      columns: const <String>['folder_id'],
      where: excludingFolderId == null
          ? 'display_name = ? COLLATE NOCASE'
          : 'display_name = ? COLLATE NOCASE AND folder_id <> ?',
      whereArgs: <Object?>[
        displayName,
        if (excludingFolderId != null) excludingFolderId,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _expectFolder(DatabaseExecutor db, String folderId) async {
    if (!await _folderIdExists(db, folderId)) {
      throw const LibraryFolderException(
        LibraryFolderFailure.folderNotFound,
      );
    }
  }

  Future<void> _expectFile(DatabaseExecutor db, String fileId) async {
    final rows = await db.query(
      _files,
      columns: const <String>['file_id'],
      where: 'file_id = ?',
      whereArgs: <Object?>[fileId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LibraryFolderException(LibraryFolderFailure.fileNotFound);
    }
  }

  Map<String, Object?> _folderToRow(LibraryFolder folder) {
    return <String, Object?>{
      'folder_id': folder.folderId,
      'display_name': folder.displayName,
      'created_at': folder.createdAt.millisecondsSinceEpoch,
    };
  }

  LibraryFolder _folderFromRow(Map<String, Object?> row) {
    return LibraryFolder(
      folderId: row['folder_id']! as String,
      displayName: row['display_name']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      ),
    );
  }

  LibraryFile _fileFromRow(Map<String, Object?> row) {
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

  Future<T> _read<T>(Future<T> Function(Database db) action) async {
    try {
      return await action(await _databaseHelper.database);
    } on LibraryFolderException {
      rethrow;
    } on FormatException {
      throw const LibraryFolderException(LibraryFolderFailure.dataCorrupt);
    } on LibraryFolderSchemaException {
      throw const LibraryFolderException(LibraryFolderFailure.dataCorrupt);
    } on DatabaseRuntimeException {
      throw const LibraryFolderException(
        LibraryFolderFailure.temporarilyUnavailable,
      );
    } on DatabaseException {
      throw const LibraryFolderException(
        LibraryFolderFailure.temporarilyUnavailable,
      );
    }
  }

  Future<T> _write<T>(Future<T> Function(Database db) action) => _read(action);
}
