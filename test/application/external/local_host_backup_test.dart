import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_question_read_test_support.dart';
import 'local_host_test_support.dart';

final class _Disk implements BackupDiskSpaceProbe {
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _FailSwap extends BackupFaultInjector {
  @override
  Future<void> beforePostSwapValidation() async =>
      throw const BackupException(BackupFailure.databaseInvalid);
}

void main() {
  initializeGeneratedTests();
  test('lost STAGE reconciles after Host drain and real SQLite restart',
      () async {
    final f = OfflineHostHarness();
    await f.open();
    try {
      final context = await f.stageContext();
      final oldEntry = f.entry;
      f.h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.afterCommit) {
          throw StateError('synthetic lost response');
        }
      };
      final lost = await f.host.dispatch(ExternalCapabilities.stage,
          ExternalStageSubmission(submission(key: 'restart-key')),
          entry: f.entry, context: context);
      expect(lost.output, isNull);
      expect(lost.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(lost.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(lost.receipt.durableReconciliation!.submissionKey, 'restart-key');
      await f.host.shutdown();
      expect(f.h.read.activeHandleCount, 0);
      f.h.s.checkpoint = null;
      await f.h.s.reopen();
      f.h.compose();
      f.compose();
      expect(f.host.state, LocalHostState.disabled);
      await f.startHost();
      for (final entry in [oldEntry, f.entry]) {
        expectNotStarted(await f.host.dispatch(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'restart-key')),
            entry: entry, context: context));
      }
      final reconciliation =
          await f.host.openReconciliation(f.entry, 'restart-key');
      final result = await f.host.dispatch(
          ExternalCapabilities.reconcile, const ExternalNoInput(),
          entry: f.entry, context: reconciliation);
      expect(result.output!.submissionKey, 'restart-key');
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
      expect(await f.h.s.h.count('questions'), 2);
    } finally {
      await f.close();
    }
  });

  for (final rollback in [false, true]) {
    test(
        'Host close/drain before real B0 ${rollback ? "raw rollback" : "Restore"} rejects old entry and Context',
        () async {
      final f = OfflineHostHarness();
      await f.open();
      try {
        final s = f.h.s;
        const ownerKeys = [
          'external_device_selection_v1',
          'external_link_handoff_release_v1'
        ];
        for (final key in ownerKeys) {
          await s.h.db.insert(
              'app_settings', {'key': key, 'value': 'synthetic-local-owner'});
        }
        final oldRead = await f.readContext();
        final oldStage = await f.stageContext();
        final oldEntry = f.entry;
        final staged = await f.host.dispatch(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'restore-key')),
            entry: oldEntry, context: oldStage);
        expect(staged.output, isNotNull);
        final snapshots = BackupSnapshotRepository(databaseHelper: s.h.helper);
        final managed = Directory(p.join(s.h.temp.path, 'managed'))
          ..createSync();
        final restore = Directory(p.join(s.h.temp.path, 'restore'))
          ..createSync();
        BackupRestoreRuntime runtime({bool fail = false}) =>
            BackupRestoreRuntime(
                databaseAuthority: SqliteBackupDatabaseAuthority(
                    databaseHelper: s.h.helper, snapshotRepository: snapshots),
                snapshotRepository: snapshots,
                managedFileStorage:
                    ManagedFileStorageAdapter(managedRoot: managed),
                restoreRoot: restore,
                managedFilesRoot: managed,
                diskSpaceProbe: _Disk(),
                faultInjector:
                    fail ? _FailSwap() : const BackupFaultInjector());
        final package = p.join(s.h.temp.path, 'p8-synthetic.shiroha');
        await runtime().exportTo(package);
        final restoring = runtime(fail: rollback);
        await restoring.prepareRestore(package);
        await f.host.shutdown();
        expect(f.gateway.pendingCount, 0);
        expect(f.h.read.pendingCount, 0);
        expect(s.service.pendingCount, 0);
        expect(f.h.read.activeHandleCount, 0);
        s.management.invalidate();
        s.localFactory.invalidate();
        s.trust.restore();
        if (rollback) {
          await expectLater(restoring.commitPreparedRestore(),
              throwsA(isA<BackupException>()));
        } else {
          await restoring.commitPreparedRestore();
        }
        s.h.db = await s.h.helper.database;
        final localOwners = await s.h.db.query('app_settings',
            columns: ['key'], where: 'key IN (?, ?)', whereArgs: ownerKeys);
        expect(localOwners, hasLength(rollback ? 2 : 0));
        expectNotStarted(await f.host.dispatch(
            ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            entry: oldEntry,
            context: oldRead));
        expectNotStarted(await f.host.dispatch(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'restore-key')),
            entry: oldEntry, context: oldStage));
        expect(await s.h.count('generated_question_proposals'), 1);
        expect(await s.h.count('generated_question_commit_receipts'), 0);
        if (rollback) {
          await s.reopen();
          f.h.compose();
          f.compose();
          await f.startHost();
          await expectLater(f.host.openRead(oldEntry),
              hostFailure(CapabilityFailure.accessDenied));
          final reconciliation =
              await f.host.openReconciliation(f.entry, 'restore-key');
          final found = await f.host.dispatch(
              ExternalCapabilities.reconcile, const ExternalNoInput(),
              entry: f.entry, context: reconciliation);
          expect(found.output!.proposalId, staged.output!.proposalId);
          expectNotStarted(await f.host.dispatch(
              ExternalCapabilities.searchQuestions,
              const ExternalQuestionQuery('needle'),
              entry: f.entry,
              context: oldRead));
        } else {
          expect(await s.h.count('external_client_profiles'), 0);
          expect(await s.h.count('external_grants'), 0);
          await s.compose();
          await expectLater(s.management.selectProfile(s.profile.profileId),
              throwsA(anything));
        }
      } finally {
        await f.close();
      }
    });
  }
}
