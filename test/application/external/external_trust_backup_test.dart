import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_trust_test_support.dart';
import 'local_host_test_support.dart' show expectNotStarted;

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
  for (final rollback in [false, true]) {
    test(
        'P12 real B0 ${rollback ? 'raw rollback' : 'Restore'} never restores trust binding',
        () async {
      final f = OfflineTrustHarness();
      await f.open();
      addTearDown(f.close);
      // P11 fixture metadata has no managed source bytes; the granted bank
      // and staged Proposal remain real SQLite authority throughout the test.
      await f.local.h.db.delete('library_files');
      await f.save();
      await f.pair();
      await f.enable();
      await f.coordinator.startOffline();
      final session = await f.session();
      final oldProfile = f.profile;
      final oldCoordinator = f.coordinator;
      final entry = await oldCoordinator.host.bindSession(session);
      final context = await oldCoordinator.host.openStage(
          entry, await f.stages.approveTarget(session, f.local.h.target, []));
      final staged = await oldCoordinator.host.dispatch(
          ExternalCapabilities.stage,
          ExternalStageSubmission(submission(key: 'b0-original-key')),
          entry: entry,
          context: context);
      expect(staged.output, isNotNull);
      final profileId = f.reference.profileId;
      final snapshots =
          BackupSnapshotRepository(databaseHelper: f.local.h.helper);
      final managed = Directory(p.join(f.local.h.temp.path, 'managed'))
        ..createSync();
      final restore = Directory(p.join(f.local.h.temp.path, 'restore'))
        ..createSync();
      final runtime = BackupRestoreRuntime(
          databaseAuthority: SqliteBackupDatabaseAuthority(
              databaseHelper: f.local.h.helper, snapshotRepository: snapshots),
          snapshotRepository: snapshots,
          managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
          restoreRoot: restore,
          managedFilesRoot: managed,
          diskSpaceProbe: _Disk(),
          faultInjector: rollback ? _FailSwap() : const BackupFaultInjector());
      final backup = BackupRestoreCoordinator(
          operations: runtime,
          compositionReload: () async => f.local.service.invalidate());
      final package = p.join(f.local.h.temp.path, 'p12-synthetic.shiroha');
      await backup.exportTo(package);
      await backup.prepareRestore(package);
      await oldCoordinator.shutdown();
      f.trust.restore();
      f.management.invalidate();
      f.localSession.close();
      f.localFactory.invalidate();
      f.view.close();
      if (rollback) {
        await expectLater(
            backup.commitPreparedRestore(), throwsA(isA<BackupException>()));
      } else {
        await backup.commitPreparedRestore();
      }
      f.local.h.db = await f.local.h.helper.database;
      expect(session.failure, isNotNull);
      expectNotStarted(await oldCoordinator.host.dispatch(
          ExternalCapabilities.stage,
          ExternalStageSubmission(submission(key: 'b0-original-key')),
          entry: entry,
          context: context));
      expect(
          await f.local.h.count('external_client_profiles'), rollback ? 1 : 0);
      expect(await f.local.h.count('external_grants'), rollback ? 1 : 0);
      expect(await f.local.h.count('generated_question_proposals'), 1);
      expect(await f.local.h.count('generated_question_commit_receipts'), 0);
      f.local.compose();
      f.view = f.local.service.openView();
      await f.compose();
      await expectLater(
          f.coordinator.enable(oldProfile, const Duration(minutes: 1)),
          throwsA(anything));
      if (rollback) {
        f.reference = await f.management.selectProfile(profileId);
        f.profile = await f.coordinator.registerProfile(f.reference);
        expect(
            f.trust.snapshot(f.profile.principal).state, PairingState.unpaired);
        await expectLater(f.session(), throwsA(isA<ExternalCoreException>()));
        await f.pair();
        await f.enable();
        await f.coordinator.startOffline();
        final fresh = await f.coordinator.host.bindSession(await f.session());
        expectNotStarted(await f.coordinator.host.dispatch(
            ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'b0-original-key')),
            entry: fresh,
            context: context));
        final reconciliation = await f.coordinator.host
            .openReconciliation(fresh, 'b0-original-key');
        final found = await f.coordinator.host.dispatch(
            ExternalCapabilities.reconcile, const ExternalNoInput(),
            entry: fresh, context: reconciliation);
        expect(found.output!.proposalId, staged.output!.proposalId);
      } else {
        await expectLater(
            f.management.selectProfile(profileId), throwsA(anything));
        // Retained historical Origin cannot recover the deleted Profile.
        expect(await f.local.h.count('external_client_profiles'), 0);
      }
    });
  }
}
