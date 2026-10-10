import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'durable_stage_test_support.dart';

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _SwapFailure extends BackupFaultInjector {
  const _SwapFailure();
  @override
  Future<void> beforePostSwapValidation() async =>
      throw const BackupException(BackupFailure.databaseInvalid);
}

void main() {
  initializeGeneratedTests();
  late DurableStageHarness s;
  late BackupSnapshotRepository snapshots;
  late Directory managed, restore;
  setUp(() async {
    s = DurableStageHarness();
    await s.open();
    snapshots = BackupSnapshotRepository(databaseHelper: s.h.helper);
    managed = Directory(p.join(s.h.temp.path, 'managed'))..createSync();
    restore = Directory(p.join(s.h.temp.path, 'restore'))..createSync();
  });
  tearDown(() async => s.close());
  BackupRestoreRuntime runtime(
          {BackupFaultInjector faults = const BackupFaultInjector()}) =>
      BackupRestoreRuntime(
          databaseAuthority: SqliteBackupDatabaseAuthority(
              databaseHelper: s.h.helper, snapshotRepository: snapshots),
          snapshotRepository: snapshots,
          managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
          restoreRoot: restore,
          managedFilesRoot: managed,
          diskSpaceProbe: const _Disk(),
          faultInjector: faults);

  test(
      'T13 actual external STAGE survives B0 v2 INCLUDE; Restore SCRUB cannot authenticate from Origin',
      () async {
    final result = await s.stage();
    expect(result.output, isNotNull);
    final before =
        await readGeneratedProposal(s.h.db, result.output!.proposalId);
    final grant = await s.h.db.query('external_grants');
    final destination = p.join(s.h.temp.path, 'roundtrip.shiroha');
    await runtime().exportTo(destination);
    final manifest = await BackupArchiveIo.readManifestOnly(destination);
    expect(manifest.packageVersion, 2);
    expect(manifest.schemaVersion, 34);
    expect(await s.h.db.query('external_grants'), grant);
    final restoring = runtime();
    await restoring.prepareRestore(destination);
    // Composition invalidation before live swap is the existing B0 obligation.
    s.service.close();
    s.localFactory.invalidate();
    s.trust.restore();
    await restoring.commitPreparedRestore();
    s.h.db = await s.h.helper.database;
    for (final table in externalAuthorizationTables) {
      expect(await s.h.db.query(table), isEmpty);
    }
    expect((await readGeneratedProposal(s.h.db, before.proposalId)).toJson(),
        before.toJson());
    expect((await s.reconcile('external-key')).output, isNull);
    await s.compose();
    await expectLater(
        s.management.selectProfile(before.clientProfileId), throwsA(anything));
    // Even a new credential proof using a historical display id cannot obtain
    // an App binding to a current durable Profile after scrub.
    s.nextProfile = before.clientProfileId;
    final historical = s.trust.createProfile();
    await expectLater(
        s.service.bindIdentity(s.profile, historical), throwsA(anything));
    expect(await s.h.count('generated_question_proposals'), 1);
    expect(await s.h.count('questions'), 0);
    final local = (await s.localSession.pending()).single;
    expect(local.proposalId, before.proposalId);
    // The original R5A local approval path can still consume the retained batch.
    final context = s.localSession.confirmDisplayedTarget(local.target);
    final reviewed = await s.h.service.flush(
        GeneratedReviewFlush.fromJson({
          'proposalId': local.proposalId,
          'expectedReviewRevision': local.reviewRevision,
          'operations': [
            {
              'type': 'decide',
              'itemId': local.items.single.itemId,
              'decision': 'accepted'
            }
          ]
        }),
        context);
    final receipt = await s.h.service.approve(s.h.approval(reviewed), context);
    expect(receipt.itemMappings, hasLength(1));
    expect(await s.h.count('generated_question_commit_receipts'), 1);
    expect(await s.h.count('questions'), 1);
  });

  test(
      'T13 raw rollback keeps original Profile/Grant and complete STAGE history',
      () async {
    final result = await s.stage();
    final before =
        await readGeneratedProposal(s.h.db, result.output!.proposalId);
    final profiles = await s.h.db.query('external_client_profiles');
    final grants = await s.h.db.query('external_grants');
    final destination = p.join(s.h.temp.path, 'rollback.shiroha');
    await runtime().exportTo(destination);
    final restoring = runtime(faults: const _SwapFailure());
    await restoring.prepareRestore(destination);
    await expectLater(
        restoring.commitPreparedRestore(), throwsA(isA<BackupException>()));
    s.h.db = await s.h.helper.database;
    expect(await s.h.db.query('external_client_profiles'), profiles);
    expect(await s.h.db.query('external_grants'), grants);
    expect((await readGeneratedProposal(s.h.db, before.proposalId)).toJson(),
        before.toJson());
    await DatabaseHelper.validateStagedBackupSchema(s.h.db);
    // A replacement runtime authenticates afresh; rollback is not enablement.
    await s.reopen();
    expect((await s.reconcile('external-key')).output!.proposalId,
        before.proposalId);
  });
}
