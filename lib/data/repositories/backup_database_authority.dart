import '../../application/backup/backup_contracts.dart';
import '../../core/database/database_helper.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import 'backup_snapshot_repository.dart';

final class SqliteBackupDatabaseAuthority implements BackupDatabaseAuthority {
  SqliteBackupDatabaseAuthority({
    DatabaseHelper? databaseHelper,
    BackupSnapshotRepository? snapshotRepository,
  })  : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _snapshots = snapshotRepository ??
            BackupSnapshotRepository(databaseHelper: databaseHelper);

  final DatabaseHelper _databaseHelper;
  final BackupSnapshotRepository _snapshots;

  @override
  Future<String> productionDatabasePath() =>
      _databaseHelper.getProductionDatabasePath();

  @override
  Future<void> closeProduction() => _databaseHelper.close();

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
}
