import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import '../../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import 'windows_app_transport_fixture.dart';
import 'windows_startup_cases.dart';
import 'offline_codex_responses_cases.dart';

final class _Disk implements BackupDiskSpaceProbe {
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

void windowsAppTransportCases() {
  offlineCodexResponsesCases();
  windowsStartupCases();
  test(
      'default inactive Bridge composition refuses STAGE before connection creation',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(stage: false);
    addTearDown(f.close);
    final context = await f.context();
    final before = f.connections.length;
    expect((await f.stage(context))['error'], 'capability.accessDenied');
    expect(f.connections.length, before);
    expect(await f.files.s.h.count('generated_question_proposals'), 0);
  });
  test('product App/P27/owned Host and Bridge share all seven tool routes',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    await insertLegacyQuestion(f.files.s.h.db,
        id: 'windows-question',
        bankName: 'bank',
        createdAt: 1,
        content: 'Synthetic needle');
    final context = await f.context();
    final search = f.data(await f
        .call('search_questions', {'contextRef': context, 'query': 'needle'}));
    final hit = (search['items'] as List).single as Map;
    expect(
        f.data(await f.call('get_question_detail', {
          'contextRef': context,
          'questionRef': hit['questionRef']
        }))['sourceKind'],
        'legacy');
    final choices = f
        .data(await f.call('open_generation_context', {'contextRef': context}));
    final selected = f.data(await f.call('open_generation_context', {
      'contextRef': context,
      'fileRefs': [(choices['items'] as List).first['fileRef']]
    }))['contextRef'];
    final retrieval = f.data(await f.call(
        'retrieve_file_content', {'contextRef': selected, 'query': 'needle'}));
    final passage = (retrieval['items'] as List).single as Map;
    expect(
        f.data(await f.call('get_file_passage', {
          'contextRef': selected,
          'passageRef': passage['passageRef']
        }))['items'],
        isNotEmpty);
    final staged = f.data(await f.approvedStage(context, 'windows-owned'));
    expect(staged['publication'], 'STAGED');
    // A fresh connection needs a fresh human decision even for the same key.
    expect(
        f.data(await f.approvedStage(context, 'windows-owned'))['proposalId'],
        staged['proposalId']);
    expect(
        f.data(await f.call('get_question_proposal',
            {'submissionKey': 'windows-owned'}))['lifecycleStatus'],
        'pending_review');
    expect(await f.files.s.h.count('generated_question_proposals'), 1);
    expect(await f.files.s.h.count('generated_question_commit_receipts'), 0);
    final local = await f.files.s.localFactory.openSession();
    var proposal = await local.read(staged['proposalId'] as String);
    final approval = local.confirmDisplayedTarget(proposal.target);
    proposal = await f.files.s.h.service.flush(
        GeneratedReviewFlush.fromJson({
          'proposalId': proposal.proposalId,
          'expectedReviewRevision': proposal.reviewRevision,
          'operations': [
            for (final item in proposal.items)
              {'type': 'decide', 'itemId': item.itemId, 'decision': 'accepted'}
          ]
        }),
        approval);
    await f.files.s.h.service.approve(
        ApproveGeneratedProposalCommand.fromJson({
          'proposalId': proposal.proposalId,
          'expectedReviewRevision': proposal.reviewRevision,
          'approvedItemIds': proposal.items.map((i) => i.itemId).toList()
        }),
        approval);
    local.close();
    expect(
        f.data(await f.call('get_question_proposal',
            {'submissionKey': 'windows-owned'}))['lifecycleStatus'],
        'committed');
    expect(await f.files.s.h.count('generated_question_commit_receipts'), 1);
    expect(f.clients.every((c) => c.writes.length == 1), isTrue);
    await f.host.whenConnectionsSettled;
    for (final connection in f.connections) {
      for (final resource in TlsResource.values) {
        expect(connection.budget.used(resource), 0);
      }
    }
    await f.integration.close();
    expect(f.host.phase, WindowsTlsHostPhase.closed);
    expect(f.controls.isCurrent, isFalse);
  });

  for (final mode in [
    'disable',
    'revision',
    'revoke',
    'disconnect',
    'bridge-eof',
    'listener-exit',
    'close',
    'restore'
  ]) {
    test(
        'product transport $mode invalidates original pending approval and drains',
        () async {
      final f = WindowsAppTransportFixture();
      await f.open();
      addTearDown(f.close);
      final context = await f.context();
      final waiting = Completer<void>();
      final changes = f.approval.changes.listen((_) {
        if (f.approval.waitingForUser && !waiting.isCompleted) {
          waiting.complete();
        }
      });
      final result = f.stage(context);
      await waiting.future;
      await changes.cancel();
      final original = f.approvalView.pending!;
      switch (mode) {
        case 'disable':
          await f.controls.disable();
        case 'revision':
          await f.files.grant();
          await f.approvalView.confirm(original);
        case 'revoke':
          final view = f.policy.openView();
          final ref = await view.select(f.files.s.profile.profileId);
          final revision = (await view.read(ref)).profile.grantRevision;
          await view.revokeGrant(ref, revision);
          view.close();
          await f.approvalView.confirm(original);
        case 'disconnect':
          await f.clients.last.close();
        case 'bridge-eof':
          await f.bridge.close();
        case 'listener-exit':
          await f.listener.controller.close();
        case 'close':
          await f.integration.close();
        case 'restore':
          final s = f.files.s;
          final snapshots =
              BackupSnapshotRepository(databaseHelper: s.h.helper);
          final backup = BackupRestoreCoordinator(
              operations: BackupRestoreRuntime(
                  databaseAuthority: SqliteBackupDatabaseAuthority(
                      beforeClose: f.integration.close,
                      databaseHelper: s.h.helper,
                      snapshotRepository: snapshots),
                  snapshotRepository: snapshots,
                  managedFileStorage:
                      ManagedFileStorageAdapter(managedRoot: f.files.managed),
                  restoreRoot: Directory(p.join(s.h.temp.path, 'restore')),
                  managedFilesRoot: f.files.managed,
                  diskSpaceProbe: _Disk()));
          final archive = p.join(s.h.temp.path, 'transport.zip');
          await backup.exportTo(archive);
          await backup.prepareRestore(archive);
          await backup.commitPreparedRestore();
          expect(f.host.phase, WindowsTlsHostPhase.closed);
          expect(
              (await (await s.h.helper.database)
                  .query('external_client_profiles')),
              isEmpty);
      }
      expect((await result)['error'], isNotNull);
      await f.host.whenConnectionsSettled;
      expect(f.approval.pendingCount, 0);
      await expectLater(f.approvalView.confirm(original), throwsA(anything));
      expect(
          (await (await f.files.s.h.helper.database)
              .query('generated_question_proposals')),
          isEmpty);
      for (final connection in f.connections) {
        for (final resource in TlsResource.values) {
          expect(connection.budget.used(resource), 0);
        }
      }
    });
  }

  test('response loss is queried by original key without automatic STAGE retry',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    final context = await f.context();
    f.configureConnection = (_, server) =>
        server.transform = (_) => throw StateError('fixture response lost');
    expect((await f.approvedStage(context, 'lost-owned'))['error'],
        'outcome_unknown');
    final calls = f.connections.length;
    expect(await f.files.s.h.count('generated_question_proposals'), 1);
    f.configureConnection = null;
    expect(
        f.data(await f.call('get_question_proposal',
            {'submissionKey': 'lost-owned'}))['lifecycleStatus'],
        'pending_review');
    expect(f.connections.length, calls + 1);
    expect(await f.files.s.h.count('generated_question_proposals'), 1);
  });

  test(
      'App close keeps database and Owner until local connection close settles',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    final release = Completer<void>();
    f.controlChannel!.closing = release;
    final reached = f.localCloseReached = Completer<void>();
    var closed = false;
    final closing = f.closeDatabase().then((_) => closed = true);
    await reached.future;
    expect(closed, isFalse);
    expect(f.files.s.h.db.isOpen, isTrue);
    expect(f.host.phase, WindowsTlsHostPhase.closing);
    f.pairing.native.owner.ensureOpen();
    release.complete();
    await closing;
    expect(f.host.phase, WindowsTlsHostPhase.closed);
    expect(closed, isTrue);
  });
}
