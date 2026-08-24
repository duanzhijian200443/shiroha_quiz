import 'dart:io';

import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

import 'train_c_b0_runtime_api.dart';

TrainCBackupRuntimePort createTrainCBackupRuntime({
  required Object databaseHelper,
  required Object managedFileStorage,
  required Object contentAssetStore,
  required Directory restoreRoot,
  required Directory managedFilesRoot,
}) {
  final helper = databaseHelper as DatabaseHelper;
  final fileStorage = managedFileStorage as ManagedFileStorageAdapter;
  final assetStore = contentAssetStore as ManagedContentAssetStore;
  final snapshots = BackupSnapshotRepository(databaseHelper: helper);
  final runtime = BackupRestoreRuntime(
    databaseAuthority: SqliteBackupDatabaseAuthority(
      databaseHelper: helper,
      snapshotRepository: snapshots,
    ),
    snapshotRepository: snapshots,
    managedFileStorage: fileStorage,
    contentAssetStore: assetStore,
    restoreRoot: restoreRoot,
    managedFilesRoot: managedFilesRoot,
    diskSpaceProbe: const _InfiniteDiskSpaceProbe(),
  );
  return _FlutterTrainCBackupRuntime(runtime);
}

final class _FlutterTrainCBackupRuntime implements TrainCBackupRuntimePort {
  const _FlutterTrainCBackupRuntime(this._runtime);

  final BackupRestoreRuntime _runtime;

  @override
  Future<void> exportTo(String destinationPath) async {
    await _runtime.exportTo(destinationPath);
  }

  @override
  Future<void> prepareRestore(String packagePath) {
    return _runtime.prepareRestore(packagePath);
  }

  @override
  Future<void> commitPreparedRestore() async {
    await _runtime.commitPreparedRestore();
  }
}

final class _InfiniteDiskSpaceProbe implements BackupDiskSpaceProbe {
  const _InfiniteDiskSpaceProbe();

  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}
