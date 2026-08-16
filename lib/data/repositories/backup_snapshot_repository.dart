import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../application/backup/backup_contracts.dart';
import '../../core/database/database_helper.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';

/// B0 data authority for consistent SQLite snapshots and staged DB
/// validation/scrub. Raw SQL and sqflite imports are intentionally confined
/// to this repository (architecture boundary: data/repositories).
final class BackupSnapshotRepository {
  BackupSnapshotRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  Future<BackupSnapshot> createSanitizedSnapshot(
    String snapshotPath,
  ) async {
    await createRawConsistentSnapshot(snapshotPath);
    try {
      return await _sanitizeAndRead(snapshotPath);
    } catch (_) {
      await _deleteIfExists(snapshotPath);
      rethrow;
    }
  }

  /// Creates a transactionally consistent, unsanitized snapshot through
  /// SQLite `VACUUM INTO`. Used by export sanitization and by the restore
  /// rollback baseline; never a bare file copy of an open WAL database.
  Future<void> createRawConsistentSnapshot(String snapshotPath) async {
    final snapshot = File(snapshotPath);
    if (await snapshot.exists()) {
      throw const BackupException(BackupFailure.snapshotUnavailable);
    }
    await snapshot.parent.create(recursive: true);

    final db = await _databaseHelper.database;
    final quoted = snapshotPath.replaceAll("'", "''");
    try {
      await db.execute("VACUUM INTO '$quoted'");
    } catch (_) {
      throw const BackupException(BackupFailure.snapshotUnavailable);
    }
    if (!await snapshot.exists()) {
      throw const BackupException(BackupFailure.snapshotUnavailable);
    }
  }

  Future<BackupSnapshot> _sanitizeAndRead(String snapshotPath) async {
    final Database candidate;
    try {
      candidate = await databaseFactory.openDatabase(snapshotPath);
    } catch (_) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
    try {
      await candidate.execute('PRAGMA foreign_keys = ON');
      await _scrub(candidate);
      await _validateInvariants(candidate);

      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      final schemaVersion = versionRows.single['user_version'] as int;
      final rows = await candidate.query('library_files', orderBy: 'file_id');
      final files = <SnapshotLibraryFile>[
        for (final row in rows)
          SnapshotLibraryFile(
            fileId: row['file_id']! as String,
            storageKey: row['storage_key']! as String,
            sizeBytes: row['size_bytes']! as int,
            sha256: row['sha256']! as String,
          ),
      ];
      return BackupSnapshot(
        databasePath: snapshotPath,
        schemaVersion: schemaVersion,
        files: files,
      );
    } finally {
      await candidate.close();
    }
  }

  Future<void> _scrub(Database db) async {
    await db.execute("UPDATE ai_engines SET api_key = ''");
    await db.execute(
      'UPDATE ai_profiles SET text_api_key = NULL, vision_api_key = NULL',
    );

    await db.delete('parsed_artifacts');
    await db.delete('parsed_artifact_heads');

    await db.delete('retrieval_index_heads');
    await db.delete('retrieval_index_builds');
    await db.delete('retrieval_chunks');
    if (await _tableExists(db, 'questions_fts')) {
      await db.delete('questions_fts');
    }

    await db.delete('import_tasks');
    if (await _tableExists(db, 'app_settings')) {
      await db.delete(
        'app_settings',
        where: 'key = ?',
        whereArgs: <Object?>['app_theme'],
      );
    }
  }

  Future<void> _validateInvariants(Database db) async {
    final quick = await db.rawQuery('PRAGMA quick_check');
    if (quick.isEmpty || quick.single.values.single != 'ok') {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
    final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
    if (foreignKeyIssues.isNotEmpty) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }

    final excludedTables = <String>[
      'parsed_artifacts',
      'parsed_artifact_heads',
      'retrieval_index_builds',
      'retrieval_index_heads',
      'retrieval_chunks',
      'retrieval_chunks_fts',
      'import_tasks',
      'questions_fts',
    ];
    for (final table in excludedTables) {
      if (!await _tableExists(db, table)) continue;
      final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM $table'),
          ) ??
          0;
      if (count != 0) {
        throw const BackupException(BackupFailure.databaseInvalid);
      }
    }

    final engineKeys = Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ai_engines WHERE api_key IS NOT NULL AND api_key <> ''",
          ),
        ) ??
        0;
    final profileKeys = Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM ai_profiles WHERE "
            "(text_api_key IS NOT NULL AND text_api_key <> '') OR "
            "(vision_api_key IS NOT NULL AND vision_api_key <> '')",
          ),
        ) ??
        0;
    if (engineKeys != 0 || profileKeys != 0) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
  }

  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM sqlite_master WHERE type = ? AND name = ?',
      <Object?>['table', table],
    );
    return (rows.single['count'] as int) > 0;
  }

  /// Public scrub-invariant validator. Restore must prove a candidate or
  /// newly installed DB is credential-scrubbed and derived/transient-free;
  /// schema validation alone is not sufficient.
  Future<void> validateScrubInvariantsOn(Database db) {
    return _validateInvariants(db);
  }

  Future<void> openRollbackAndValidateSchema(String rollbackDatabasePath) {
    return _openAndValidate(rollbackDatabasePath,
        includeScrubInvariants: false);
  }

  Future<void> openStagedAndValidate(
    String stagedDatabasePath,
  ) {
    return _openAndValidate(stagedDatabasePath, includeScrubInvariants: true);
  }

  Future<void> _openAndValidate(
    String databasePath, {
    required bool includeScrubInvariants,
  }) async {
    if (await File(databasePath).exists() == false) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
    final Database migrated;
    try {
      migrated = await _databaseHelper.openPathForStagedMigration(
        databasePath,
      );
    } catch (_) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
    try {
      final versionRows = await migrated.rawQuery('PRAGMA user_version');
      final version = versionRows.single['user_version'] as int;
      if (version > DatabaseHelper.databaseVersion) {
        throw const BackupException(BackupFailure.unsupportedSchemaVersion);
      }
      await DatabaseHelper.validateStagedBackupSchema(migrated);
      if (includeScrubInvariants) {
        await _validateInvariants(migrated);
      }
    } finally {
      await migrated.close();
    }
  }

  Future<List<SnapshotLibraryFile>> readStagedLibraryFiles(
    String stagedDatabasePath,
  ) async {
    final Database db;
    try {
      db = await databaseFactory.openDatabase(stagedDatabasePath);
    } catch (_) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
    try {
      final rows = await db.query('library_files', orderBy: 'file_id');
      return <SnapshotLibraryFile>[
        for (final row in rows)
          SnapshotLibraryFile(
            fileId: row['file_id']! as String,
            storageKey: row['storage_key']! as String,
            sizeBytes: row['size_bytes']! as int,
            sha256: row['sha256']! as String,
          ),
      ];
    } finally {
      await db.close();
    }
  }

  Future<void> discardSnapshot(String snapshotPath) async {
    await _deleteIfExists(snapshotPath);
  }

  static Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  static String nextSnapshotPath(String workspaceRoot) =>
      p.join(workspaceRoot, 'database', 'shiroha.db');
}
