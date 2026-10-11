import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_file_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_file_read_test_support.dart';

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
        'T18 actual B0 ${rollback ? "raw rollback" : "restore"} invalidates every File/Passage reference',
        () async {
      final h = FileReadHarness();
      await h.open();
      try {
        final parent = await h.context();
        final choices = await h.read
            .listFileSelections(session: h.s.session, context: parent);
        final fileRef = choices.items.first['fileRef'] as String;
        final context = await h.read.createFileContext(
            session: h.s.session, context: parent, fileRefs: [fileRef]);
        final passageRef =
            (await h.search(context)).items.single['passageRef'] as String;
        final cursor = (await h.passage(context, passageRef)).nextCursor!;
        final snapshots =
            BackupSnapshotRepository(databaseHelper: h.s.h.helper);
        final restore = Directory(p.join(h.s.h.temp.path, 'restore'))
          ..createSync();
        BackupRestoreRuntime runtime({bool fail = false}) =>
            BackupRestoreRuntime(
                databaseAuthority: SqliteBackupDatabaseAuthority(
                    databaseHelper: h.s.h.helper,
                    snapshotRepository: snapshots),
                snapshotRepository: snapshots,
                managedFileStorage:
                    ManagedFileStorageAdapter(managedRoot: h.managed),
                restoreRoot: restore,
                managedFilesRoot: h.managed,
                diskSpaceProbe: _Disk(),
                faultInjector:
                    fail ? _FailSwap() : const BackupFaultInjector());
        final package = p.join(h.s.h.temp.path, 'source-read.shiroha');
        await runtime().exportTo(package);
        final restoring = runtime(fail: rollback);
        await restoring.prepareRestore(package);
        h.s.service.close();
        await h.read.whenIdle;
        h.s.management.invalidate();
        h.s.localFactory.invalidate();
        h.s.trust.restore();
        expect(h.read.activeHandleCount, 0);
        if (rollback) {
          await expectLater(restoring.commitPreparedRestore(),
              throwsA(isA<BackupException>()));
        } else {
          await restoring.commitPreparedRestore();
        }
        h.s.h.db = await h.s.h.helper.database;
        expect(await h.s.h.count('library_files'), 2);
        await expectLater(h.passage(context, passageRef, cursor: cursor),
            throwsA(isA<ExternalFileReadException>()));
        await expectLater(
            h.read.createFileContext(
                session: h.s.session, context: parent, fileRefs: [fileRef]),
            throwsA(anything));
        if (rollback) {
          await h.s.reopen();
          h.compose();
          final fresh = await h.approved();
          await expectLater(h.passage(fresh, passageRef, cursor: cursor),
              throwsA(isA<ExternalFileReadException>()));
          expect((await h.search(fresh)).items, isNotEmpty);
        } else {
          expect(await h.s.h.count('external_client_profiles'), 0);
          expect(await h.s.h.count('external_grants'), 0);
          expect(await h.s.h.count('parsed_artifacts'), 0);
          expect(await h.s.h.count('retrieval_index_builds'), 0);
        }
      } finally {
        await h.close();
      }
    });
  }
}
