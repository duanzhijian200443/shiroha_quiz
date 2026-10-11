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
        'T11 real B0 ${rollback ? "rollback" : "restore"} never restores old READ Handles/Session',
        () async {
      final s = DurableStageHarness();
      await s.open();
      ExternalReadContextService composeRead() => ExternalReadContextService(
          admission: s.service.runtimeAdmission,
          targets:
              SqliteExternalTargetReadRepository(databaseHelper: s.h.helper));
      var read = composeRead();
      try {
        await s.management.replaceGrant(
            s.profile,
            1,
            s.policy(permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ]));
        final ref =
            (await read.listTargets(session: s.session)).items.single.targetRef;
        final token =
            await read.createContext(session: s.session, targetRef: ref);
        final staged = await s.stage();
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
        final package = p.join(s.h.temp.path, 'synthetic.shiroha');
        await runtime().exportTo(package);
        final restoring = runtime(fail: rollback);
        await restoring.prepareRestore(package);
        final oldSession = s.session;
        // Existing B0 composition obligation before swap/recovery, not a Host route.
        s.service.close();
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
        expect(await read.contextStatus(session: oldSession, context: token),
            ExternalReadValidity.invalid);
        expect(await s.h.count('generated_question_proposals'), 1);
        expect(await s.h.count('questions'), 0);
        if (rollback) {
          await s.reopen();
          read = composeRead();
          expect(await read.contextStatus(session: s.session, context: token),
              ExternalReadValidity.invalid);
          final fresh = (await read.listTargets(session: s.session))
              .items
              .single
              .targetRef;
          expect(await read.createContext(session: s.session, targetRef: fresh),
              isNot(token));
          expect((await s.reconcile('external-key')).output!.proposalId,
              staged.output!.proposalId);
        } else {
          expect(await s.h.count('external_client_profiles'), 0);
          expect(await s.h.count('external_grants'), 0);
          await s.compose();
          await expectLater(s.management.selectProfile(s.profile.profileId),
              throwsA(anything));
        }
      } finally {
        read.close();
        await read.whenIdle;
        await s.close();
      }
    });
  }
}
