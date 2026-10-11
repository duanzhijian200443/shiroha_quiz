import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'durable_stage_test_support.dart';

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
        'P7 real B0 ${rollback ? "rollback" : "restore"} invalidates old execution Context and preserves Proposal authority',
        () async {
      final s = DurableStageHarness();
      await s.open();
      ExternalReadContextService composeRead() => ExternalReadContextService(
          admission: s.service.runtimeAdmission,
          targets:
              SqliteExternalTargetReadRepository(databaseHelper: s.h.helper));
      var read = composeRead();
      var gateway = ExternalCapabilityGateway(stages: s.service, reads: read);
      try {
        await s.management.replaceGrant(
            s.profile,
            1,
            s.policy(permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ]));
        final discovery = await gateway.openRead(session: s.session);
        final page = await gateway.execute(
            ExternalCapabilities.listTargets, const ExternalTargetQuery(),
            session: s.session, context: discovery);
        final context = await gateway.openStage(
            session: s.session, context: await s.context());
        final staged = await gateway.execute(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'external-key')),
            session: s.session, context: context);
        expect(staged.output, isNotNull);
        final originalSession = s.session;
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
        final package = p.join(s.h.temp.path, 'p7-synthetic.shiroha');
        await runtime().exportTo(package);
        final restoring = runtime(fail: rollback);
        await restoring.prepareRestore(package);
        // Existing App composition close/drain obligation before B0 swap.
        s.service.close();
        await s.service.whenIdle;
        await read.whenIdle;
        await gateway.whenIdle;
        s.management.invalidate();
        s.localFactory.invalidate();
        s.trust.restore();
        expect(read.activeHandleCount, 0);
        if (rollback) {
          await expectLater(restoring.commitPreparedRestore(),
              throwsA(isA<BackupException>()));
        } else {
          await restoring.commitPreparedRestore();
        }
        s.h.db = await s.h.helper.database;
        final denied = await gateway.execute(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'external-key')),
            session: originalSession, context: context);
        expect(denied.output, isNull);
        expect(denied.receipt.status, CapabilityExecutionStatus.notStarted);
        expect(denied.receipt.knownEffect, CapabilityEffect.none);
        expect(await s.h.count('generated_question_proposals'), 1);
        expect(await s.h.count('generated_question_commit_receipts'), 0);
        expect(await s.h.count('questions'), 0);
        if (rollback) {
          await s.reopen();
          read = composeRead();
          gateway = ExternalCapabilityGateway(stages: s.service, reads: read);
          final fresh = await gateway.openReconciliation(
              session: s.session, submissionKey: 'external-key');
          final recovered = await gateway.execute(
              ExternalCapabilities.reconcile, const ExternalNoInput(),
              session: s.session, context: fresh);
          expect(recovered.output!.proposalId, staged.output!.proposalId);
          final discovery2 = await gateway.openRead(session: s.session);
          final old = await gateway.execute(
              ExternalCapabilities.createReadContext,
              ExternalTargetSelection(page.output!.items.single.targetRef),
              session: s.session,
              context: discovery2);
          expect(old.output, isNull);
          expect(old.failure, CapabilityFailure.externalReadDenied);
          final copied = await gateway.execute(
              ExternalCapabilities.listTargets, const ExternalTargetQuery(),
              session: s.session, context: discovery);
          expect(copied.receipt.status, CapabilityExecutionStatus.notStarted);
        } else {
          expect(await s.h.count('external_client_profiles'), 0);
          expect(await s.h.count('external_grants'), 0);
          await s.compose();
          await expectLater(s.management.selectProfile(s.profile.profileId),
              throwsA(anything));
        }
      } finally {
        gateway.close();
        read.close();
        await read.whenIdle;
        await s.close();
      }
    });
  }
}
