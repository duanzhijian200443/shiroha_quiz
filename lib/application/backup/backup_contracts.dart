import 'dart:async';
import 'dart:typed_data';

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/restore_journal.dart';

final class BackupExportSummary {
  const BackupExportSummary({
    required this.fileName,
    required this.schemaVersion,
    required this.fileCount,
    required this.databaseSizeBytes,
    required this.managedBytes,
  });

  /// Safe basename only. The destination path never crosses the UI seam.
  final String fileName;
  final int schemaVersion;
  final int fileCount;
  final int databaseSizeBytes;
  final int managedBytes;
}

final class BackupRestorePreview {
  const BackupRestorePreview({
    required this.packageVersion,
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.fileCount,
    required this.totalSizeBytes,
  });

  final int packageVersion;
  final int schemaVersion;
  final DateTime createdAtUtc;
  final int fileCount;
  final int totalSizeBytes;
}

final class BackupRestoreSuccess {
  const BackupRestoreSuccess({
    required this.schemaVersion,
    required this.fileCount,
  });

  final int schemaVersion;
  final int fileCount;
}

final class BackupStartupRecovery {
  const BackupStartupRecovery({
    required this.blocked,
    required this.diagnosticId,
    this.failure,
    this.recoveredJournalState,
  });

  final bool blocked;
  final String diagnosticId;
  final BackupFailure? failure;
  final RestoreJournalState? recoveredJournalState;
}

final class SnapshotLibraryFile {
  const SnapshotLibraryFile({
    required this.fileId,
    required this.storageKey,
    required this.sizeBytes,
    required this.sha256,
  });

  final String fileId;
  final String storageKey;
  final int sizeBytes;
  final String sha256;
}

final class BackupSnapshot {
  const BackupSnapshot({
    required this.databasePath,
    required this.schemaVersion,
    required this.files,
  });

  final String databasePath;
  final int schemaVersion;
  final List<SnapshotLibraryFile> files;
}

final class StagedRestore {
  const StagedRestore({
    required this.stagingPath,
    required this.databasePath,
    required this.managedFilesPath,
    required this.manifest,
  });

  final String stagingPath;
  final String databasePath;
  final String managedFilesPath;
  final BackupManifest manifest;
}

/// Read-only stream over one managed original.
abstract interface class ManagedOriginalReader {
  Future<Stream<Uint8List>> open(String fileId);
}

/// Database lifecycle authority used by the B0 restore runtime. It is the
/// only seam through which services may close/reopen the production DB or run
/// staged validation; concrete sqflite wiring stays in the data layer.
abstract interface class BackupDatabaseAuthority {
  Future<String> productionDatabasePath();
  Future<void> closeProduction();
  Future<void> reopenProduction();
  Future<void> validateDatabaseFile(String path);
  Future<void> validateRollbackDatabaseFile(String path);
  Future<void> validateOpenProduction();
  Future<void> validateOpenProductionScrubInvariants();
  Future<List<SnapshotLibraryFile>> readOpenProductionLibraryFiles();
}

/// High-level B0 operations implemented by the infrastructure layer. The
/// Application coordinator owns tracing, concurrency, cancellation semantics
/// and failure mapping around this seam.
abstract interface class BackupRestoreOperations {
  Future<BackupExportSummary> exportTo(String destinationPath);
  Future<BackupRestorePreview> inspectPackage(String packagePath);
  Future<BackupRestorePreview> prepareRestore(String packagePath);
  Future<void> cancelPreparedRestore();
  Future<BackupRestoreSuccess> commitPreparedRestore({
    Future<void> Function()? beforeCommitted,
  });
  Future<BackupStartupRecovery> recoverStartupIfNeeded();
}
