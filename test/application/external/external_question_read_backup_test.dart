import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'external_question_read_test_support.dart';

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
        'T15 B0 ${rollback ? "rollback" : "restore"} preserves learning data and excludes all READ references',
        () async {
      final h = QuestionReadHarness();
      await h.open();
      try {
        await h.typed();
        await h.legacy('extra');
        final context = await h.context();
        final page = await h.read.searchQuestions(
            session: h.s.session,
            context: context,
            query: 'needle',
            pageSize: 1);
        final ref = page.items.single.questionRef;
        final snapshots =
            BackupSnapshotRepository(databaseHelper: h.s.h.helper);
        final managed = Directory(p.join(h.s.h.temp.path, 'managed'))
          ..createSync();
        final restore = Directory(p.join(h.s.h.temp.path, 'restore'))
          ..createSync();
        BackupRestoreRuntime runtime({bool fail = false}) =>
            BackupRestoreRuntime(
                databaseAuthority: SqliteBackupDatabaseAuthority(
                    databaseHelper: h.s.h.helper,
                    snapshotRepository: snapshots),
                snapshotRepository: snapshots,
                managedFileStorage:
                    ManagedFileStorageAdapter(managedRoot: managed),
                restoreRoot: restore,
                managedFilesRoot: managed,
                diskSpaceProbe: _Disk(),
                faultInjector:
                    fail ? _FailSwap() : const BackupFaultInjector());
        final package = p.join(h.s.h.temp.path, 'synthetic.shiroha');
        await runtime().exportTo(package);
        final restoring = runtime(fail: rollback);
        await restoring.prepareRestore(package);
        final oldSession = h.s.session;
        h.s.service.close();
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
        expect(await h.s.h.count('questions'), 2);
        await expectLater(
            h.read.getQuestionDetail(
                session: oldSession, context: context, questionRef: ref),
            throwsA(isA<ExternalReadException>()));
        if (rollback) {
          await h.s.reopen();
          h.compose();
          final fresh = await h.context();
          await expectLater(
              h.read.getQuestionDetail(
                  session: h.s.session, context: fresh, questionRef: ref),
              throwsA(isA<ExternalReadException>()));
          await expectLater(
              h.read.searchQuestions(
                  session: h.s.session,
                  context: fresh,
                  query: 'needle',
                  cursor: page.nextCursor),
              throwsA(isA<ExternalReadException>()));
          expect(
              (await h.read.searchQuestions(
                      session: h.s.session, context: fresh, query: 'needle'))
                  .items,
              hasLength(2));
        } else {
          expect(await h.s.h.count('external_client_profiles'), 0);
          expect(await h.s.h.count('external_grants'), 0);
        }
      } finally {
        await h.close();
      }
    });
  }
}
