import 'dart:async';

import '../../core/observability/log_writer.dart';
import '../../core/observability/trace_context.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import 'backup_contracts.dart';

final class BackupRestoreCoordinator {
  BackupRestoreCoordinator({required BackupRestoreOperations operations})
      : _operations = operations;

  final BackupRestoreOperations _operations;
  bool _busy = false;

  bool get isBusy => _busy;

  Future<T> _runExclusive<T>({
    required TraceOperationKind operationKind,
    required Future<T> Function() action,
  }) {
    if (_busy) {
      throw const BackupException(BackupFailure.restoreBusy);
    }
    _busy = true;
    return TraceContext.runRoot<T>(
      operationKind: operationKind,
      action: () async {
        try {
          return await action();
        } finally {
          _busy = false;
        }
      },
    );
  }

  Future<BackupExportSummary> exportTo(String destinationPath) {
    return _runExclusive(
      operationKind: TraceOperationKind.backupExport,
      action: () async {
        final result = await _operations.exportTo(destinationPath);
        LogWriter.info(
          'B0 export completed',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'completed',
            'status': 'success',
            'fileCount': result.fileCount,
            'byteCount': result.databaseSizeBytes + result.managedBytes,
          },
        );
        return result;
      },
    );
  }

  Future<BackupRestorePreview> inspectPackage(String packagePath) {
    return _runExclusive(
      operationKind: TraceOperationKind.backupRestore,
      action: () async {
        final result = await _operations.inspectPackage(packagePath);
        LogWriter.info(
          'B0 package inspected',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'inspected',
            'status': 'success',
            'fileCount': result.fileCount,
            'byteCount': result.totalSizeBytes,
          },
        );
        return result;
      },
    );
  }

  Future<BackupRestorePreview> prepareRestore(String packagePath) {
    return _runExclusive(
      operationKind: TraceOperationKind.backupRestore,
      action: () async {
        final result = await _operations.prepareRestore(packagePath);
        LogWriter.info(
          'B0 restore staged',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'staged',
            'status': 'success',
            'fileCount': result.fileCount,
            'byteCount': result.totalSizeBytes,
          },
        );
        return result;
      },
    );
  }

  Future<void> cancelPreparedRestore() {
    return _runExclusive<void>(
      operationKind: TraceOperationKind.backupRestore,
      action: () async {
        await _operations.cancelPreparedRestore();
        LogWriter.info(
          'B0 restore staging cancelled',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'cancelled',
            'status': 'cancelled',
          },
        );
      },
    );
  }

  Future<BackupRestoreSuccess> commitPreparedRestore() {
    return _runExclusive(
      operationKind: TraceOperationKind.backupRestore,
      action: () async {
        final result = await _operations.commitPreparedRestore();
        LogWriter.info(
          'B0 restore committed',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'committed',
            'status': 'success',
            'fileCount': result.fileCount,
          },
        );
        return result;
      },
    );
  }

  Future<BackupStartupRecovery> recoverStartupIfNeeded() {
    return TraceContext.runRoot<BackupStartupRecovery>(
      operationKind: TraceOperationKind.backupRestore,
      action: () async {
        final result = await _operations.recoverStartupIfNeeded();
        LogWriter.info(
          'B0 startup recovery',
          module: 'Backup',
          data: <String, Object?>{
            'stage': 'startup_recovery',
            'status': result.blocked ? 'blocked' : 'recovered',
            'failureCode': result.failure?.name,
          },
        );
        return result;
      },
    );
  }

  /// Rethrows a B0 exception with a diagnostic id when possible, without
  /// leaking raw errors into presentation logs.
  Never fail(Object error, StackTrace stackTrace) {
    LogWriter.error(
      'B0 operation failed',
      module: 'Backup',
      data: <String, Object?>{
        'status': 'failed',
        'failureCode': error is BackupException ? error.failure.name : null,
      },
    );
    Error.throwWithStackTrace(error, stackTrace);
  }
}
