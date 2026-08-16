import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_contracts.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';

final class _FakeOperations implements BackupRestoreOperations {
  bool maintenanceObservedDuringCommit = false;
  int commitCalls = 0;

  @override
  Future<BackupExportSummary> exportTo(String destinationPath) async {
    return const BackupExportSummary(
      fileName: 'backup.shiroha',
      schemaVersion: 22,
      fileCount: 0,
      databaseSizeBytes: 0,
      managedBytes: 0,
    );
  }

  @override
  Future<BackupRestorePreview> inspectPackage(String packagePath) async {
    return BackupRestorePreview(
      packageVersion: 1,
      schemaVersion: 22,
      createdAtUtc: DateTime.utc(2026),
      fileCount: 0,
      totalSizeBytes: 0,
    );
  }

  @override
  Future<BackupRestorePreview> prepareRestore(String packagePath) async {
    return inspectPackage(packagePath);
  }

  @override
  Future<void> cancelPreparedRestore() async {}

  @override
  Future<BackupRestoreSuccess> commitPreparedRestore() async {
    commitCalls++;
    maintenanceObservedDuringCommit =
        BackupRestoreMutationGate.instance.isMaintenance;
    return const BackupRestoreSuccess(schemaVersion: 22, fileCount: 0);
  }

  @override
  Future<BackupStartupRecovery> recoverStartupIfNeeded() async {
    return const BackupStartupRecovery(
      blocked: false,
      diagnosticId: 'OBS-2222-2222',
    );
  }
}

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('quiescence blocks all durable mutation authorities', () {
    BackupRestoreMutationGate.instance.enterQuiescence();
    expect(
      () => BackupRestoreMutationGate.instance.ensureMutationAllowed(),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBlocked,
      )),
    );
    BackupRestoreMutationGate.instance.exitQuiescence();
    BackupRestoreMutationGate.instance.ensureMutationAllowed();
  });

  test('exclusive B0 operations reject a concurrent backup/restore', () {
    BackupRestoreMutationGate.instance.acquireExclusive();
    expect(
      BackupRestoreMutationGate.instance.acquireExclusive,
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.restoreBusy,
      )),
    );
    BackupRestoreMutationGate.instance.releaseExclusive();
    BackupRestoreMutationGate.instance.acquireExclusive();
  });

  test('coordinator commit enters global quiescence before runtime commit',
      () async {
    final operations = _FakeOperations();
    final coordinator = BackupRestoreCoordinator(operations: operations);

    await coordinator.commitPreparedRestore();

    expect(operations.commitCalls, 1);
    expect(operations.maintenanceObservedDuringCommit, isTrue);
    expect(BackupRestoreMutationGate.instance.isMaintenance, isFalse);
    expect(BackupRestoreMutationGate.instance.isExclusive, isFalse);
  });
}
