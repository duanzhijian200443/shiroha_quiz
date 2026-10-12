import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_authorization_data_test.dart' show authFailure;
import 'local_authorization_test_support.dart';

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
        'real B0 ${rollback ? 'raw rollback retains policy' : 'portable restore scrubs policy'}; old view cannot write',
        () async {
      final fixture = LocalAuthorizationHarness();
      await fixture.open();
      addTearDown(fixture.close);
      // This policy-only backup fixture has no managed source files.
      await fixture.h.db.delete('library_files');
      final view = fixture.service.openView();
      final ref = await view.create('Synthetic');
      await view.save(ref, 0,
          permissions: [CapabilityPermission.read, CapabilityPermission.stage],
          targets:
              (await view.targets()).where((t) => t.scope.targetId == 'bank'),
          categories: ExternalContentCategory.values);
      final before = {
        for (final table in externalAuthorizationTables)
          table: await fixture.h.db.query(table)
      };
      final managed = Directory(p.join(fixture.h.temp.path, 'managed'))
        ..createSync();
      final restore = Directory(p.join(fixture.h.temp.path, 'restore'))
        ..createSync();
      final snapshots =
          BackupSnapshotRepository(databaseHelper: fixture.h.helper);
      final operations = BackupRestoreRuntime(
          databaseAuthority: SqliteBackupDatabaseAuthority(
              databaseHelper: fixture.h.helper, snapshotRepository: snapshots),
          snapshotRepository: snapshots,
          managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
          restoreRoot: restore,
          managedFilesRoot: managed,
          diskSpaceProbe: _Disk(),
          faultInjector: rollback ? _FailSwap() : const BackupFaultInjector());
      final coordinator = BackupRestoreCoordinator(
          operations: operations,
          compositionReload: () async {
            fixture.service.invalidate();
          });
      final package = p.join(fixture.h.temp.path, 'synthetic.shiroha');
      await coordinator.exportTo(package);
      await coordinator.prepareRestore(package);
      if (rollback) {
        await expectLater(coordinator.commitPreparedRestore(),
            throwsA(isA<BackupException>()));
      } else {
        await coordinator.commitPreparedRestore();
      }
      fixture.h.db = await fixture.h.helper.database;
      await expectLater(
          view.save(ref, 1,
              permissions: [CapabilityPermission.read],
              targets: [],
              categories: []),
          authFailure(ExternalAuthFailure.unauthorized));
      await expectLater(
          view.create('Stale'), authFailure(ExternalAuthFailure.unauthorized));
      for (final table in externalAuthorizationTables) {
        expect(await fixture.h.db.query(table),
            rollback ? before[table] : isEmpty);
      }
      fixture.compose();
      final fresh = fixture.service.openView();
      if (rollback) {
        final record = await fresh.read(await fresh.select(ref.profileId));
        expect(record.grant!.revision, 1);
        expect(record.profile.protocol, 'unconfigured');
      } else {
        expect((await fresh.profiles()).items, isEmpty);
        final recreated = await fresh.create('Fresh');
        expect((await fresh.read(recreated)).grant, isNull);
      }
      fresh.close();
      view.close();
    });
  }
}
