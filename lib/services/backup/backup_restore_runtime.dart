import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../application/backup/backup_contracts.dart';
import '../../data/repositories/backup_snapshot_repository.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/backup_values.dart';
import '../../domain/backup/restore_journal.dart';
import '../file_library/managed_file_storage.dart';
import 'backup_archive_io.dart';
import 'backup_disk_space.dart';
import 'backup_filesystem.dart';
import 'backup_journal_store.dart';

/// Thrown by fault hooks to simulate a process crash: the runtime must NOT
/// roll back on this signal; the journal remains for startup recovery.
final class BackupCrashSimulation implements Exception {
  const BackupCrashSimulation();
}

/// Fault hooks used by deterministic restore tests. Production wiring passes
/// a no-op injector.
class BackupFaultInjector {
  const BackupFaultInjector();

  Future<void> afterJournalPrepared() async {}
  Future<void> afterJournalSwapping() async {}
  Future<void> afterLiveDbReplaced() async {}
  Future<void> afterLiveFilesDeleted() async {}
  Future<void> afterLiveFilesReplaced() async {}
  Future<void> beforePostSwapValidation() async {}
  Future<void> beforeReopenProduction() async {}
  Future<void> beforeCommittedCleanup() async {}
  Future<void> beforeRollbackDbRestore() async {}
  Future<void> beforeRollbackFilesRestore() async {}
  Future<void> failRollbackPermanently() async {}
}

final class BackupRestoreRuntime implements BackupRestoreOperations {
  BackupRestoreRuntime({
    required BackupDatabaseAuthority databaseAuthority,
    required BackupSnapshotRepository snapshotRepository,
    required ManagedFileStorage managedFileStorage,
    required Directory restoreRoot,
    required Directory managedFilesRoot,
    BackupDiskSpaceProbe diskSpaceProbe = const PlatformDiskSpaceProbe(),
    BackupFaultInjector faultInjector = const BackupFaultInjector(),
    String Function()? operationIdFactory,
  })  : _database = databaseAuthority,
        _snapshots = snapshotRepository,
        _managedFiles = managedFileStorage,
        _restoreRoot = restoreRoot,
        _managedFilesRoot = managedFilesRoot,
        _diskSpaceProbe = diskSpaceProbe,
        _faultInjector = faultInjector,
        _operationIdFactory = operationIdFactory ?? _uuid.v4;

  static const Uuid _uuid = Uuid();

  final BackupDatabaseAuthority _database;
  final BackupSnapshotRepository _snapshots;
  final ManagedFileStorage _managedFiles;
  final Directory _restoreRoot;
  final Directory _managedFilesRoot;
  final BackupDiskSpaceProbe _diskSpaceProbe;
  final BackupFaultInjector _faultInjector;
  final String Function() _operationIdFactory;

  StagedRestore? _staged;
  String? _stagedPackagePath;
  BackupJournalStore? _journalStore;

  BackupJournalStore get _journalStoreOrCreate {
    return _journalStore ??= BackupJournalStore(
      journalRoot: Directory(p.join(_restoreRoot.path, 'journal')),
    );
  }

  @override
  Future<BackupExportSummary> exportTo(String destinationPath) async {
    final workspace = await Directory(
      p.join(_restoreRoot.path, 'export', _operationIdFactory()),
    ).create(recursive: true);
    try {
      final snapshotPath = p.join(
        workspace.path,
        'database',
        'shiroha.db',
      );
      final snapshot = await _snapshots.createSanitizedSnapshot(snapshotPath);

      final copiedFiles = <ArchiveSourceFile>[];
      var managedBytes = 0;
      for (final file in snapshot.files) {
        final source = _managedFiles.resolveManagedFile(file.storageKey);
        if (!await source.exists()) {
          throw const BackupException(BackupFailure.integrityMismatch);
        }
        final targetPath = p.join(
          workspace.path,
          'files',
          'library',
          file.fileId,
        );
        final measured = await BackupFilesystem.copyAndMeasure(
          sourcePath: source.path,
          targetPath: targetPath,
        );
        if (measured.sizeBytes != file.sizeBytes ||
            measured.sha256 != file.sha256) {
          throw const BackupException(BackupFailure.integrityMismatch);
        }
        managedBytes += measured.sizeBytes;
        copiedFiles.add(
          ArchiveSourceFile(fileId: file.fileId, path: targetPath),
        );
      }

      final durableBytes = File(snapshotPath).lengthSync() + managedBytes;
      if (snapshot.files.length + 2 > BackupValues.maxArchiveEntries ||
          durableBytes > BackupValues.packageMaxDeclaredUncompressedBytes) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }
      await BackupFreeSpacePolicy.ensureAvailable(
        probe: _diskSpaceProbe,
        path: destinationPath,
        durableBytes: durableBytes * 2,
      );

      final manifest = BackupManifest(
        schemaVersion: snapshot.schemaVersion,
        createdAtUtc: DateTime.now().toUtc(),
        database: BackupDatabaseEntry(
          archivePath: BackupValues.databaseArchivePath,
          sizeBytes: File(snapshotPath).lengthSync(),
          sha256: BackupFilesystem.sha256File(snapshotPath),
        ),
        managedFiles: <BackupManagedFileEntry>[
          for (var index = 0; index < snapshot.files.length; index++)
            BackupManagedFileEntry(
              fileId: snapshot.files[index].fileId,
              storageKey: snapshot.files[index].storageKey,
              archivePath: BackupValues.managedArchivePath(
                snapshot.files[index].fileId,
              ),
              sizeBytes: snapshot.files[index].sizeBytes,
              sha256: snapshot.files[index].sha256,
            ),
        ],
      );
      if (manifest.encode().length > BackupValues.manifestEntryMaxBytes) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }
      final manifestPath = p.join(workspace.path, 'manifest.json');
      await File(manifestPath).writeAsString(
        manifest.encode(),
        flush: true,
      );

      final tempPackage = p.join(workspace.path, 'package.shiroha.tmp');
      await BackupArchiveIo.writeStoredPackage(
        packagePath: tempPackage,
        manifestPath: manifestPath,
        databasePath: snapshotPath,
        files: copiedFiles,
      );
      await BackupArchiveIo.verifyPackage(
        packagePath: tempPackage,
        manifest: manifest,
      );

      final destination = File(destinationPath);
      await destination.parent.create(recursive: true);
      if (await destination.exists()) {
        await destination.delete();
      }
      await File(tempPackage).rename(destination.path);

      return BackupExportSummary(
        fileName: p.basename(destinationPath),
        schemaVersion: snapshot.schemaVersion,
        fileCount: snapshot.files.length,
        databaseSizeBytes: manifest.database.sizeBytes,
        managedBytes: managedBytes,
      );
    } finally {
      await _deleteIfExists(workspace);
    }
  }

  @override
  Future<BackupRestorePreview> inspectPackage(String packagePath) async {
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    if (manifest.schemaVersion > BackupValues.currentSchemaVersion) {
      throw const BackupException(BackupFailure.unsupportedSchemaVersion);
    }
    return BackupRestorePreview(
      packageVersion: manifest.packageVersion,
      schemaVersion: manifest.schemaVersion,
      createdAtUtc: manifest.createdAtUtc,
      fileCount: manifest.managedFileCount,
      totalSizeBytes: manifest.totalDeclaredBytes,
    );
  }

  @override
  Future<BackupRestorePreview> prepareRestore(String packagePath) async {
    if (_staged != null) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    if (manifest.packageVersion > BackupValues.packageVersion) {
      throw const BackupException(BackupFailure.unsupportedPackageVersion);
    }
    if (manifest.schemaVersion > BackupValues.currentSchemaVersion) {
      throw const BackupException(BackupFailure.unsupportedSchemaVersion);
    }

    await BackupFreeSpacePolicy.ensureAvailable(
      probe: _diskSpaceProbe,
      path: _restoreRoot.path,
      durableBytes: manifest.totalDeclaredBytes,
    );

    final operationId = _operationIdFactory();
    final stagingRoot = Directory(
      p.join(_restoreRoot.path, 'staging', operationId),
    );
    await stagingRoot.create(recursive: true);
    try {
      final extracted = await BackupArchiveIo.extractAndValidate(
        packagePath: packagePath,
        stagingRoot: stagingRoot.path,
      );
      await _snapshots.openStagedAndValidate(extracted.databasePath);
      final staged = StagedRestore(
        stagingPath: stagingRoot.path,
        databasePath: extracted.databasePath,
        managedFilesPath: extracted.managedFilesRoot,
        manifest: manifest,
      );
      await _verifyStagedLibraryFiles(staged);
      _staged = staged;
      _stagedPackagePath = packagePath;
      return BackupRestorePreview(
        packageVersion: manifest.packageVersion,
        schemaVersion: manifest.schemaVersion,
        createdAtUtc: manifest.createdAtUtc,
        fileCount: manifest.managedFileCount,
        totalSizeBytes: manifest.totalDeclaredBytes,
      );
    } catch (_) {
      await _deleteIfExists(stagingRoot);
      rethrow;
    }
  }

  @override
  Future<void> cancelPreparedRestore() async {
    final journal = await _journalStoreOrCreate.read();
    if (journal != null && journal.state != RestoreJournalState.prepared) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    final staged = _staged;
    _staged = null;
    _stagedPackagePath = null;
    if (staged != null) {
      await _deleteIfExists(Directory(staged.stagingPath));
    }
    if (journal != null) {
      await _deleteKey(journal.stagingKey);
      await _deleteKey(journal.rollbackDbKey);
      await _deleteKey(journal.rollbackFilesKey);
      await _journalStoreOrCreate.clear();
    }
  }

  @override
  Future<BackupRestoreSuccess> commitPreparedRestore() async {
    final staged = _staged;
    if (staged == null) {
      throw const BackupException(BackupFailure.invalidPackage);
    }
    final packagePath = _stagedPackagePath;
    if (packagePath == null) {
      throw const BackupException(BackupFailure.invalidPackage);
    }

    final operationId = _operationIdFactory();
    final journalStore = BackupJournalStore(
      journalRoot: Directory(p.join(_restoreRoot.path, 'journal')),
    );
    final stagingKey = _relativeKey(staged.stagingPath);
    final rollbackKey = 'rollback/$operationId';
    final rollbackDbKey = '$rollbackKey/db';
    final rollbackFilesKey = '$rollbackKey/files';
    final rollbackDbPath = journalStore.resolveKey(rollbackDbKey);
    final rollbackFilesPath = journalStore.resolveKey(rollbackFilesKey);

    final liveDbPath = await _database.productionDatabasePath();
    final liveManaged = _managedFilesRoot;

    try {
      await _copyLiveToRollback(
        liveDbPath: liveDbPath,
        liveManaged: liveManaged,
        rollbackDbPath: rollbackDbPath,
        rollbackFilesPath: rollbackFilesPath,
      );
      final packageDigest = BackupFilesystem.sha256File(packagePath);
      var journal = RestoreJournal(
        version: 1,
        operationId: operationId,
        format: BackupValues.format,
        packageVersion: staged.manifest.packageVersion,
        schemaVersion: staged.manifest.schemaVersion,
        packageDigest: packageDigest,
        state: RestoreJournalState.prepared,
        updatedAtUtc: DateTime.now().toUtc(),
        stagingKey: stagingKey,
        rollbackDbKey: rollbackDbKey,
        rollbackFilesKey: rollbackFilesKey,
        fileCount: staged.manifest.managedFileCount,
        databaseSizeBytes: staged.manifest.database.sizeBytes,
        managedBytes: staged.manifest.managedFiles.fold<int>(
          0,
          (sum, file) => sum + file.sizeBytes,
        ),
      );
      await journalStore.write(journal);
      await _faultInjector.afterJournalPrepared();

      journal = journal.copyWithState(RestoreJournalState.swapping);
      await journalStore.write(journal);
      await _faultInjector.afterJournalSwapping();

      await _swapLiveState(
        staged: staged,
        liveDbPath: liveDbPath,
        liveManaged: liveManaged,
      );
      await _faultInjector.beforePostSwapValidation();

      await _faultInjector.beforeReopenProduction();
      await _database.reopenProduction();
      await _database.validateOpenProduction();
      final stagedFiles = await _database.readOpenProductionLibraryFiles();
      if (stagedFiles.length != staged.manifest.managedFileCount) {
        throw const BackupException(BackupFailure.integrityMismatch);
      }

      journal = journal.copyWithState(RestoreJournalState.committed);
      await journalStore.write(journal);
      _staged = null;
      _stagedPackagePath = null;
      await _cleanupBestEffort(
        journalStore,
        journal,
        stagingPath: staged.stagingPath,
        rollbackDbPath: rollbackDbPath,
        rollbackFilesPath: rollbackFilesPath,
      );
      return BackupRestoreSuccess(
        schemaVersion: staged.manifest.schemaVersion,
        fileCount: staged.manifest.managedFileCount,
      );
    } on BackupCrashSimulation {
      rethrow;
    } catch (_) {
      await _rollbackFromJournalStore(
        journalStore: journalStore,
        liveDbPath: liveDbPath,
        liveManaged: liveManaged,
        rollbackDbPath: rollbackDbPath,
        rollbackFilesPath: rollbackFilesPath,
        stagingPath: staged.stagingPath,
      );
      _staged = null;
      _stagedPackagePath = null;
      rethrow;
    }
  }

  Future<void> _copyLiveToRollback({
    required String liveDbPath,
    required Directory liveManaged,
    required String rollbackDbPath,
    required String rollbackFilesPath,
  }) async {
    await BackupFreeSpacePolicy.ensureAvailable(
      probe: _diskSpaceProbe,
      path: _restoreRoot.path,
      durableBytes: (await File(liveDbPath).exists()
              ? File(liveDbPath).lengthSync()
              : 0) +
          await _directorySize(liveManaged),
    );
    await Directory(rollbackDbPath).create(recursive: true);
    if (await File(liveDbPath).exists()) {
      await BackupFilesystem.copyAndMeasure(
        sourcePath: liveDbPath,
        targetPath: p.join(rollbackDbPath, 'shiroha_core_v1.db'),
      );
    }
    await BackupFilesystem.copyDirectoryContents(
      source: liveManaged,
      target: Directory(rollbackFilesPath),
    );
  }

  Future<void> _swapLiveState({
    required StagedRestore staged,
    required String liveDbPath,
    required Directory liveManaged,
  }) async {
    final dbDirectory = Directory(p.dirname(liveDbPath));
    await dbDirectory.create(recursive: true);
    await _database.closeProduction();

    await _deleteIfExists(File(liveDbPath));
    await _deleteIfExists(File('$liveDbPath-wal'));
    await _deleteIfExists(File('$liveDbPath-shm'));
    await File(staged.databasePath).copy(liveDbPath);
    await _faultInjector.afterLiveDbReplaced();

    await BackupFilesystem.deleteDirectoryContents(liveManaged);
    await _faultInjector.afterLiveFilesDeleted();
    for (final entry in staged.manifest.managedFiles) {
      final target = _managedFiles.resolveManagedFile(entry.storageKey);
      await BackupFilesystem.copyAndMeasure(
        sourcePath: p.join(staged.managedFilesPath, entry.fileId),
        targetPath: target.path,
      );
    }
    await _faultInjector.afterLiveFilesReplaced();
  }

  Future<void> _rollbackFromJournalStore({
    required BackupJournalStore journalStore,
    required String liveDbPath,
    required Directory liveManaged,
    required String rollbackDbPath,
    required String rollbackFilesPath,
    required String stagingPath,
  }) async {
    final current = await journalStore.read();
    final journal = current == null
        ? throw const BackupException(BackupFailure.rollbackFailed)
        : current.copyWithState(RestoreJournalState.rollingBack);
    await journalStore.write(journal);
    try {
      await _database.closeProduction();
      await _faultInjector.beforeRollbackDbRestore();
      await BackupFilesystem.copyAndMeasure(
        sourcePath: p.join(rollbackDbPath, 'shiroha_core_v1.db'),
        targetPath: liveDbPath,
      );
      await _faultInjector.beforeRollbackFilesRestore();
      await BackupFilesystem.deleteDirectoryContents(liveManaged);
      await BackupFilesystem.copyDirectoryContents(
        source: Directory(rollbackFilesPath),
        target: liveManaged,
      );
      await _faultInjector.failRollbackPermanently();
      await _database.reopenProduction();
      await _database.validateOpenProduction();
      await journalStore
          .write(journal.copyWithState(RestoreJournalState.rolledBack));
      await _cleanupBestEffort(
        journalStore,
        journal.copyWithState(RestoreJournalState.rolledBack),
        stagingPath: stagingPath,
        rollbackDbPath: rollbackDbPath,
        rollbackFilesPath: rollbackFilesPath,
      );
    } on BackupCrashSimulation {
      rethrow;
    } catch (_) {
      final failed = current.copyWithState(
        RestoreJournalState.rollbackFailed,
      );
      await journalStore.write(failed);
      throw const BackupException(BackupFailure.rollbackFailed);
    }
  }

  @override
  Future<BackupStartupRecovery> recoverStartupIfNeeded() async {
    final journalStore = _journalStoreOrCreate;
    final RestoreJournal journal;
    try {
      final value = await journalStore.read();
      if (value == null) {
        return BackupStartupRecovery(
          blocked: false,
          diagnosticId: _diagnosticId(),
        );
      }
      journal = value;
    } on BackupException catch (error) {
      return BackupStartupRecovery(
        blocked: true,
        diagnosticId: error.diagnosticId ?? _diagnosticId(),
        failure: error.failure,
        recoveredJournalState: RestoreJournalState.rollbackFailed,
      );
    }
    final liveDbPath = await _database.productionDatabasePath();
    final liveManaged = _managedFilesRoot;
    final rollbackDbPath = journalStore.resolveKey(journal.rollbackDbKey);
    final rollbackFilesPath = journalStore.resolveKey(
      journal.rollbackFilesKey,
    );
    final stagingPath = journalStore.resolveKey(journal.stagingKey);

    try {
      switch (journal.state) {
        case RestoreJournalState.prepared:
          await _deleteIfExists(Directory(stagingPath));
          await _deleteIfExists(Directory(rollbackDbPath));
          await _deleteIfExists(Directory(rollbackFilesPath));
          await journalStore.clear();
          return BackupStartupRecovery(
            blocked: false,
            diagnosticId: _diagnosticId(),
            recoveredJournalState: RestoreJournalState.prepared,
          );
        case RestoreJournalState.swapping:
        case RestoreJournalState.rollingBack:
          await _restoreRollbackOnly(
            journal: journal,
            journalStore: journalStore,
            liveDbPath: liveDbPath,
            liveManaged: liveManaged,
            rollbackDbPath: rollbackDbPath,
            rollbackFilesPath: rollbackFilesPath,
            stagingPath: stagingPath,
          );
          return BackupStartupRecovery(
            blocked: false,
            diagnosticId: _diagnosticId(),
            recoveredJournalState: RestoreJournalState.rolledBack,
          );
        case RestoreJournalState.rolledBack:
          await _database.reopenProduction();
          await _database.validateOpenProduction();
          await _deleteIfExists(Directory(stagingPath));
          await _deleteIfExists(Directory(rollbackDbPath));
          await _deleteIfExists(Directory(rollbackFilesPath));
          await journalStore.clear();
          return BackupStartupRecovery(
            blocked: false,
            diagnosticId: _diagnosticId(),
            recoveredJournalState: RestoreJournalState.rolledBack,
          );
        case RestoreJournalState.committed:
          try {
            await _database.reopenProduction();
            await _database.validateOpenProduction();
          } catch (_) {
            if (Directory(rollbackDbPath).existsSync()) {
              await _restoreRollbackOnly(
                journal: journal,
                journalStore: journalStore,
                liveDbPath: liveDbPath,
                liveManaged: liveManaged,
                rollbackDbPath: rollbackDbPath,
                rollbackFilesPath: rollbackFilesPath,
                stagingPath: stagingPath,
              );
              return BackupStartupRecovery(
                blocked: false,
                diagnosticId: _diagnosticId(),
                recoveredJournalState: RestoreJournalState.rolledBack,
              );
            }
            await journalStore.write(
              journal.copyWithState(RestoreJournalState.rollbackFailed),
            );
            return BackupStartupRecovery(
              blocked: true,
              diagnosticId: _diagnosticId(),
              failure: BackupFailure.rollbackFailed,
              recoveredJournalState: RestoreJournalState.rollbackFailed,
            );
          }
          await _deleteIfExists(Directory(stagingPath));
          await _deleteIfExists(Directory(rollbackDbPath));
          await _deleteIfExists(Directory(rollbackFilesPath));
          await journalStore.clear();
          return BackupStartupRecovery(
            blocked: false,
            diagnosticId: _diagnosticId(),
            recoveredJournalState: RestoreJournalState.committed,
          );
        case RestoreJournalState.rollbackFailed:
          return BackupStartupRecovery(
            blocked: true,
            diagnosticId: _diagnosticId(),
            failure: BackupFailure.rollbackFailed,
            recoveredJournalState: RestoreJournalState.rollbackFailed,
          );
      }
    } on BackupException catch (error) {
      if (journal.state != RestoreJournalState.prepared) {
        try {
          await journalStore.write(
            journal.copyWithState(RestoreJournalState.rollbackFailed),
          );
        } catch (_) {}
      }
      return BackupStartupRecovery(
        blocked: true,
        diagnosticId: error.diagnosticId ?? _diagnosticId(),
        failure: error.failure,
        recoveredJournalState: RestoreJournalState.rollbackFailed,
      );
    }
  }

  Future<void> _restoreRollbackOnly({
    required RestoreJournal journal,
    required BackupJournalStore journalStore,
    required String liveDbPath,
    required Directory liveManaged,
    required String rollbackDbPath,
    required String rollbackFilesPath,
    required String stagingPath,
  }) async {
    await journalStore.write(
      journal.copyWithState(RestoreJournalState.rollingBack),
    );
    await _database.closeProduction();
    await _faultInjector.beforeRollbackDbRestore();
    await BackupFilesystem.copyAndMeasure(
      sourcePath: p.join(rollbackDbPath, 'shiroha_core_v1.db'),
      targetPath: liveDbPath,
    );
    await _faultInjector.beforeRollbackFilesRestore();
    await BackupFilesystem.deleteDirectoryContents(liveManaged);
    await BackupFilesystem.copyDirectoryContents(
      source: Directory(rollbackFilesPath),
      target: liveManaged,
    );
    await _faultInjector.failRollbackPermanently();
    await _database.reopenProduction();
    await _database.validateOpenProduction();
    await journalStore
        .write(journal.copyWithState(RestoreJournalState.rolledBack));
    await _deleteIfExists(Directory(stagingPath));
    await _deleteIfExists(Directory(rollbackDbPath));
    await _deleteIfExists(Directory(rollbackFilesPath));
    await journalStore.clear();
  }

  Future<void> _cleanupBestEffort(
    BackupJournalStore journalStore,
    RestoreJournal journal, {
    required String stagingPath,
    required String rollbackDbPath,
    required String rollbackFilesPath,
  }) async {
    try {
      await _faultInjector.beforeCommittedCleanup();
      await _deleteIfExists(Directory(stagingPath));
      await _deleteIfExists(Directory(rollbackDbPath));
      await _deleteIfExists(Directory(rollbackFilesPath));
      await journalStore.clear();
    } catch (_) {
      // Contract: COMMITTED cleanup is best effort and never inverts success.
    }
  }

  Future<void> _verifyStagedLibraryFiles(StagedRestore staged) async {
    final rows = await _snapshots.readStagedLibraryFiles(staged.databasePath);
    final byId = <String, SnapshotLibraryFile>{
      for (final row in rows) row.fileId: row,
    };
    if (byId.length != staged.manifest.managedFileCount) {
      throw const BackupException(BackupFailure.integrityMismatch);
    }
    for (final entry in staged.manifest.managedFiles) {
      final row = byId[entry.fileId];
      if (row == null ||
          row.storageKey != entry.storageKey ||
          row.sizeBytes != entry.sizeBytes ||
          row.sha256 != entry.sha256) {
        throw const BackupException(BackupFailure.integrityMismatch);
      }
      final file = File(p.join(staged.managedFilesPath, entry.fileId));
      if (!await file.exists() ||
          file.lengthSync() != entry.sizeBytes ||
          BackupFilesystem.sha256File(file.path) != entry.sha256) {
        throw const BackupException(BackupFailure.integrityMismatch);
      }
    }
  }

  Future<int> _directorySize(Directory root) async {
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> _deleteKey(String key) =>
      _deleteIfExists(Directory(_journalStoreOrCreate.resolveKey(key)));

  static Future<void> _deleteIfExists(FileSystemEntity entity) async {
    if (await entity.exists()) {
      await entity.delete(recursive: true);
    }
  }

  String _relativeKey(String path) =>
      p.relative(path, from: _restoreRoot.path).replaceAll(r'\', '/');

  static String _diagnosticId() {
    // Main/AppLogger owns the real OBS id. This fallback is a safe token.
    return 'OBS-B0P0-SAFE';
  }
}
