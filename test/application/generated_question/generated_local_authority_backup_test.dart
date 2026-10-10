import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'generated_test_support.dart';

final class _Disk implements BackupDiskSpaceProbe {
  const _Disk();
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late GeneratedLocalAuthorityFactory authority;
  late GeneratedLocalAuthoritySession session;
  late BackupRestoreCoordinator backup;
  var reloads = 0;

  GeneratedLocalAuthorityFactory factory() {
    final repository =
        GeneratedLocalAuthorityRepository(databaseHelper: h.helper);
    return GeneratedLocalAuthorityFactory(
        identity: repository,
        proposals: repository,
        compositionIsCurrent: () =>
            !BackupRestoreMutationGate.instance.isMaintenance);
  }

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    h = GeneratedHarness();
    await h.open();
    authority = factory();
    session = await authority.openSession();
    reloads = 0;
    final managed = Directory(p.join(h.temp.path, 'managed'))..createSync();
    final restore = Directory(p.join(h.temp.path, 'restore'))..createSync();
    final snapshots = BackupSnapshotRepository(databaseHelper: h.helper);
    backup = BackupRestoreCoordinator(
        operations: BackupRestoreRuntime(
            databaseAuthority: SqliteBackupDatabaseAuthority(
                databaseHelper: h.helper, snapshotRepository: snapshots),
            snapshotRepository: snapshots,
            managedFileStorage: ManagedFileStorageAdapter(managedRoot: managed),
            restoreRoot: restore,
            managedFilesRoot: managed,
            diskSpaceProbe: const _Disk()),
        compositionReload: () async {
          // Matches production: invalidate before rebuilding, while B0 still
          // holds maintenance. No UI session or confirmation is restored.
          expect(BackupRestoreMutationGate.instance.isMaintenance, isTrue);
          expect(session.isCurrent, isFalse);
          authority.invalidate();
          authority = factory();
          expect(authority.isCurrent, isFalse);
          reloads++;
        });
  });
  tearDown(() async {
    authority.invalidate();
    await h.close();
    BackupRestoreMutationGate.resetForTesting();
  });

  Future<GeneratedQuestionProposal> stage(String key) async =>
      (await h.service.stage(
              submission(key: key, items: [candidate(stem: key)]),
              GeneratedOriginContext(
                  localOwner: session.localOwner,
                  originKind: 'synthetic',
                  clientProfileId: 'p0-fixture',
                  target: h.target,
                  evidence: const [],
                  isCurrent: () => session.isCurrent)))
          .proposal;

  Future<GeneratedQuestionProposal> accept(
          GeneratedQuestionProposal proposal) =>
      h.service.flush(
          GeneratedReviewFlush.fromJson({
            'proposalId': proposal.proposalId,
            'expectedReviewRevision': proposal.reviewRevision,
            'operations': [
              {
                'type': 'decide',
                'itemId': proposal.items.single.itemId,
                'decision': 'accepted'
              }
            ]
          }),
          session.confirmDisplayedTarget(h.target));

  test('real B0 preserves ownership, invalidates sessions and never approves',
      () async {
    final pending = await accept(await stage('pending-fixture'));
    final committed = await accept(await stage('committed-fixture'));
    final receipt = await h.service.approve(
        h.approval(committed), session.confirmDisplayedTarget(h.target));
    final oldAuthority = authority;
    final oldSession = session;
    final oldContext = session.confirmDisplayedTarget(h.target);
    final owner = session.localOwner;
    await h.db.insert('app_settings', {'key': 'app_theme', 'value': 'dark'});
    final path = p.join(h.temp.path, 'owner.shiroha');
    await backup.exportTo(path);
    final manifest = await BackupArchiveIo.readManifestOnly(path);
    expect(manifest.packageVersion, 2);
    expect(manifest.schemaVersion, 33);
    await backup.prepareRestore(path);
    expect(oldSession.isCurrent, isTrue); // Staging is not a restore/approval.
    await backup.commitPreparedRestore();
    h.db = await h.helper.database;
    expect(reloads, 1);
    expect(oldAuthority.isCurrent, isFalse);
    expect(oldSession.isCurrent, isFalse);
    await expectLater(oldSession.read(pending.proposalId),
        failure(GeneratedFailure.unauthorized));
    await expectLater(
        oldAuthority.openSession(), failure(GeneratedFailure.unauthorized));
    for (final command in [
      () => h.service.approve(h.approval(pending), oldContext),
      () => h.service.reject(
          RejectGeneratedProposalCommand.fromJson({
            'proposalId': pending.proposalId,
            'expectedReviewRevision': pending.reviewRevision
          }),
          oldContext),
      () => h.service.flush(
          GeneratedReviewFlush.fromJson({
            'proposalId': pending.proposalId,
            'expectedReviewRevision': pending.reviewRevision,
            'operations': [
              {
                'type': 'decide',
                'itemId': pending.items.single.itemId,
                'decision': 'rejected'
              }
            ]
          }),
          oldContext)
    ]) {
      await expectLater(command, failure(GeneratedFailure.unauthorized));
    }
    session = await authority.openSession();
    expect(session.localOwner, owner);
    expect((await session.pending()).single.toJson(), pending.toJson());
    expect((await session.read(committed.proposalId)).commitReceipt!.toJson(),
        receipt.toJson());
    expect(await h.count('questions'), 1);
    expect(await h.count('question_v2_payloads'), 1);
    expect(await h.count('review_states'), 1);
    expect(await h.count('generated_question_commit_receipts'), 1);
    expect(
        await h.db
            .query('app_settings', where: 'key=?', whereArgs: ['app_theme']),
        isEmpty);
    // Repeated restore and application restart preserve data, never contexts.
    final restoredContext = session.confirmDisplayedTarget(h.target);
    await backup.prepareRestore(path);
    await backup.commitPreparedRestore();
    h.db = await h.helper.database;
    expect(() => restoredContext.validate(),
        failure(GeneratedFailure.unauthorized));
    authority.invalidate();
    await h.reopen();
    authority = factory();
    session = await authority.openSession();
    expect(session.localOwner, owner);
    expect((await session.read(pending.proposalId)).lifecycleStatus,
        GeneratedStatus.pendingReview);
    expect(await h.count('questions'), 1);
  });

  for (final defect in ['missing', 'corrupt', 'mismatch']) {
    test('restored $defect identity stops access without repairing or claiming',
        () async {
      final proposal = await stage('retained-fixture');
      final oldContext = session.confirmDisplayedTarget(h.target);
      const key = GeneratedLocalAuthorityRepository.ownerSettingKey;
      if (defect == 'missing') {
        await h.db.delete('app_settings', where: 'key=?', whereArgs: [key]);
      } else {
        await h.db.update('app_settings',
            {'value': defect == 'corrupt' ? 'damaged' : const Uuid().v4()},
            where: 'key=?', whereArgs: [key]);
      }
      final setting = await h.db.query('app_settings');
      final path = p.join(h.temp.path, '$defect.shiroha');
      await backup.exportTo(path);
      await backup.prepareRestore(path);
      await backup.commitPreparedRestore();
      h.db = await h.helper.database;
      final expected = switch (defect) {
        'missing' => GeneratedLocalIdentityFailure.missingWithProposals,
        'corrupt' => GeneratedLocalIdentityFailure.corrupt,
        _ => GeneratedLocalIdentityFailure.ownerMismatch
      };
      await expectLater(
          authority.openSession(),
          throwsA(isA<GeneratedLocalIdentityException>()
              .having((e) => e.failure, 'fixed failure', expected)));
      expect(
          () => oldContext.validate(), failure(GeneratedFailure.unauthorized));
      expect(await h.db.query('app_settings'), setting);
      expect(await h.count('generated_question_proposals'), 1);
      expect(await h.count('questions'), 0);
      expect(await h.count('generated_question_commit_receipts'), 0);
      // Restore retained original ownership and content without treating it
      // as a permit to create a fresh first-party session.
      expect(
          (await h.db.query('generated_question_proposals'))
              .single['local_owner'],
          proposal.localOwner);
    });
  }
}
