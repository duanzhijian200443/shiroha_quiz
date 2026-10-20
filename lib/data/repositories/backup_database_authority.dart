import '../../application/backup/backup_contracts.dart';
import '../../core/database/database_helper.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import 'backup_snapshot_repository.dart';

final class SqliteBackupDatabaseAuthority implements BackupDatabaseAuthority {
  SqliteBackupDatabaseAuthority({
    DatabaseHelper? databaseHelper,
    BackupSnapshotRepository? snapshotRepository,
    Future<void> Function()? beforeClose,
  })  : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _beforeClose = beforeClose,
        _snapshots = snapshotRepository ??
            BackupSnapshotRepository(databaseHelper: databaseHelper);

  final DatabaseHelper _databaseHelper;
  final BackupSnapshotRepository _snapshots;
  final Future<void> Function()? _beforeClose;

  @override
  Future<String> productionDatabasePath() =>
      _databaseHelper.getProductionDatabasePath();

  @override
  Future<void> closeProduction() async {
    await _beforeClose?.call();
    await _databaseHelper.close();
  }

  @override
  Future<void> reopenProduction() async {
    try {
      await _databaseHelper.database;
    } catch (_) {
      throw const BackupException(BackupFailure.databaseInvalid);
    }
  }

  @override
  Future<void> validateDatabaseFile(String path) =>
      _snapshots.openStagedAndValidate(path);

  @override
  Future<void> validateRollbackDatabaseFile(String path) =>
      _snapshots.openRollbackAndValidateSchema(path);

  @override
  Future<void> validateOpenProduction() async {
    final db = await _databaseHelper.database;
    await DatabaseHelper.validateStagedBackupSchema(db);
  }

  @override
  Future<void> validateOpenProductionScrubInvariants() async {
    final db = await _databaseHelper.database;
    await _snapshots.validateScrubInvariantsOn(db);
  }

  @override
  Future<List<SnapshotLibraryFile>> readOpenProductionLibraryFiles() async {
    final db = await _databaseHelper.database;
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
  }
}
