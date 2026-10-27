import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_bridge_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import '../../application/generated_question/generated_test_support.dart';
import '../../data/external/fixtures/windows_tls_bridge_cases.dart';
import '../../data/external/windows_tls_transport_test.dart' as tls;
import 'vnext_mcp_test_support.dart' show SubmissionEncodingProbe;

final class _Disk implements BackupDiskSpaceProbe {
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

/// The existing TLS/P15/P0/P8/P3 and SQLite owners, with real local controls.
/// All channels, cryptographic objects and clocks are existing offline fixtures.
final class _ApprovalFixture {
  _ApprovalFixture(this.h);
  final tls.TlsHarness h;
  late FirstPartyStageApproval approval;
  late FirstPartyExternalAccess controls;
  late VnextMcpAppComposition app;
  late BridgeFixture connection;
  late VnextMcpBridgePort port;
  FirstPartyStageApprovalView? view;
  late String contextRef;
  Future<Map<String, Object?>>? result;
  int handlers = 0;

  Future<void> open({bool widget = false, bool? direct}) async {
    final local = h.pairing.local;
    approval = FirstPartyStageApproval(
        host: local.coordinator.host,
        stages: local.stages,
        localOwner: local.localSession,
        compositionIsCurrent: () => local.current,
        monotonicNow: () => h.deadlines.now,
        schedule: h.deadlines.schedule);
    app = VnextMcpAppComposition(
        host: local.coordinator.host,
        reads: local.reads,
        stages: local.stages,
        authentication: VnextMcpSessionAuthentication(() async => null),
        stageApproval: approval,
        approvedTargets: const []);
    connection = BridgeFixture(h);
    await connection.open(
        binding: app,
        enableStageApprovalWait: true,
        attachHost: false,
        configureGrant: direct == null
            ? null
            : () async {
                final ref = await local.view.select(local.reference.profileId);
                final revision =
                    (await local.view.read(ref)).profile.grantRevision;
                await local.view
                    .saveAllContent(ref, revision, directWrite: direct);
              });
    port = VnextMcpBridgePort(connection.bridge);
    controls = FirstPartyExternalAccess(
        policy: local.local.service, compositionIsCurrent: () => local.current);
    controls.installTrusted(FirstPartyExternalBinding(
        management: local.management,
        coordinator: local.coordinator,
        trust: local.trust,
        stages: local.stages,
        localOwner: local.localSession,
        authenticationAttempt: () => null,
        stageApproval: approval,
        publishApprovals: app.replaceApprovedTargets,
        shutdown: () async {
          final closing = approval.close();
          await h.candidate!.shutdown();
          await closing;
        }));
    if (!widget) view = controls.openStageApprovalView();
    // A previous independently authenticated connection mints only a READ ref.
    // The STAGE connection below must obtain its own S/E and human approval.
    final previous = tls.MemoryTlsChannel();
    final session = await h.verifier.authenticate(previous, h.plan);
    final host = local.coordinator.host;
    final entry = await host.bindSession(session.session);
    final read = await host.openRead(entry);
    final targets = await host.dispatch(
        ExternalCapabilities.listTargets, const ExternalTargetQuery(),
        entry: entry, context: read);
    final context = await host.dispatch(
        ExternalCapabilities.createReadContext,
        ExternalTargetSelection(targets.output!.items
            .firstWhere((t) => t.bankName == 'bank' && t.projectId == null)
            .targetRef),
        entry: entry,
        context: read);
    contextRef = context.output!;
    h.verifier.invalidateChannel(previous);
    await previous.close();
    local.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeTransaction) handlers++;
    };
  }

  Future<void> start(
      {Stream<void> cancelled = const Stream.empty(),
      String key = 'human-stage',
      Map<String, Object?>? content,
      String? context}) async {
    final prompted = Completer<void>();
    final changes = approval.changes.listen((_) {
      if (approval.waitingForUser && !prompted.isCompleted) prompted.complete();
    });
    result = port.call(
        'propose_generated_questions',
        {
          'contextRef': context ?? contextRef,
          'submission': content ?? jsonDecode(submission(key: key)),
        },
        cancelled: cancelled,
        available: () => true);
    h.listener.controller.add(tls.MemoryRawPeer(connection.server));
    await Future.any([prompted.future, result!.then((_) {})]);
    await changes.cancel();
  }

  void advance(Duration duration) {
    h.pairing.local.clock.current = h.pairing.local.clock.current.add(duration);
    h.deadlines.advance(duration);
  }

  Future<int> count(String table) => h.pairing.local.local.h.count(table);
  Future<void> finish() async {
    await result;
    await port.close();
    await h.candidate!.whenConnectionsSettled;
    expect(approval.pendingCount, 0);
    connection.released();
  }

  Future<void> close() async {
    view?.close();
    await controls.shutdown();
  }
}

void firstPartyStageApprovalCases(tls.TlsHarness Function() harness) {
  group('explicit first-party Bridge STAGE wait', () {
    late _ApprovalFixture f;
    setUp(() => f = _ApprovalFixture(harness()));

    test(
        'saved-mode cancellation returns while original authentication still owns settlement',
        () async {
      await f.open(widget: true, direct: false);
      final channel = tls.MemoryTlsChannel();
      final authenticated = await f.h.verifier.authenticate(channel, f.h.plan);
      final session = authenticated.session;
      final entry = await f.approval.host.bindSession(session);
      final entered = Completer<void>(), release = Completer<void>();
      final control = ExternalCallControl(clock: f.h.pairing.local.clock);
      var calls = 0;
      final work = f.approval.waitForApproval(
          session: session,
          entry: entry,
          contextRef: f.contextRef,
          submissionJson: submission(),
          control: control,
          available: () => true,
          authenticate: () async {
            if (++calls == 3) {
              entered.complete();
              await release.future;
            }
            return session;
          });
      final refused =
          expectLater(work, throwsA(isA<LocalHostAdmissionException>()));
      await entered.future;
      var settled = false;
      final settling = f.approval.whenSettled.then((_) => settled = true);
      control.cancel();
      await refused;
      expect(settled, isFalse);
      release.complete();
      await settling;
      expect(await f.count('generated_question_proposals'), 0);
      f.approval.finish(control, clean: true);
      f.h.verifier.invalidateChannel(channel);
      await channel.close();
      await f.close();
    });

    for (final direct in [false, true]) {
      test(
          'saved ${direct ? "direct" : "review"} policy works without an open settings view through TLS and IPC',
          () async {
        await f.open(widget: true, direct: direct);
        await f.start(key: 'saved-mode');
        final response = await f.result!;
        expect(response['error'], isNull, reason: '$response');
        expect(f.approval.waitingForUser, isFalse);
        expect(await f.count('generated_question_proposals'), 1);
        expect(await f.count('questions'), direct ? 1 : 0);
        expect(await f.count('generated_question_commit_receipts'),
            direct ? 1 : 0);
        await f.finish();
        await f.close();
      });
    }

    testWidgets(
        'real Widget click after ten seconds stages once through Fake TLS and SQLite',
        (tester) async {
      await tester.runAsync(() => f.open(widget: true));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: FirstPartyExternalControl(access: f.controls)))));
      await tester.runAsync(() => f.start());
      await tester.pump();
      expect(find.text('批准本次暂存'), findsOneWidget);
      await tester.runAsync(() async {
        f.advance(const Duration(seconds: 11));
        await f.approval.whenSettled;
        expect(f.handlers, 0);
        expect(await f.count('generated_question_proposals'), 0);
      });
      await tester.tap(find.text('批准本次暂存'));
      await tester.runAsync(() async {
        final result = await f.result!;
        expect(result['error'], isNull);
        expect(f.handlers, 1);
        expect(await f.count('generated_question_proposals'), 1);
        expect(await f.count('questions'), 0);
        expect(await f.count('generated_question_commit_receipts'), 0);
        expect(f.connection.client.writes, hasLength(1));
        await f.finish();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    });

    for (final mode in [
      'no-view',
      'wrong-target',
      'read-only',
      'expired-enable',
      'trailing-input',
      'generation',
      'caller-ten-seconds'
    ]) {
      test('$mode cannot grant STAGE authority', () async {
        await f.open(widget: mode == 'no-view');
        final cancellation = StreamController<void>();
        if (mode == 'wrong-target') {
          await f.h.pairing.local.local.h.db.update(
              'bank_folders', {'folder_name': 'moved'},
              where: 'bank_name=?', whereArgs: ['bank']);
        }
        if (mode == 'read-only') {
          final local = f.h.pairing.local;
          final reference = await local.view.select(local.reference.profileId);
          final revision =
              (await local.view.read(reference)).profile.grantRevision;
          await local.view.save(reference, revision,
              permissions: [CapabilityPermission.read],
              targets: (await local.view.targets()).where((t) =>
                  t.scope.targetId == 'bank' && t.scope.projectId == null),
              categories: const []);
        }
        await f.start(cancelled: cancellation.stream);
        switch (mode) {
          case 'expired-enable':
            f.advance(const Duration(minutes: 5));
          case 'generation':
            f.h.pairing.local.current = false;
            f.advance(const Duration(seconds: 1));
          case 'trailing-input':
            f.connection.server.feed(utf8.encode('x'));
          case 'caller-ten-seconds':
            f.advance(const Duration(seconds: 10));
            cancellation.add(null);
        }
        expect((await f.result!)['error'], isNotNull);
        await f.finish();
        expect(f.handlers, 0);
        expect(await f.count('generated_question_proposals'), 0);
        await cancellation.close();
        f.h.pairing.local.current = true;
        await f.close();
      });
    }

    for (final mode in ['size', 'depth', 'items', 'object']) {
      test('$mode is bounded before encoding or sending Submission', () async {
        await f.open();
        final probe = SubmissionEncodingProbe();
        final content =
            (jsonDecode(submission()) as Map).cast<String, Object?>();
        switch (mode) {
          case 'size':
            content['extra'] = '\u0001' * (1024 * 1024 ~/ 6);
          case 'depth':
            Object nested = 'x';
            for (var i = 0; i < 17; i++) {
              nested = [nested];
            }
            content['extra'] = nested;
          case 'items':
            content['items'] = List.filled(51, probe);
          case 'object':
            content['items'] = [probe];
        }
        await f.start(content: content);
        expect((await f.result!)['error'], isNotNull);
        expect(probe.encoded, isFalse);
        expect(f.connection.client.writes, isEmpty);
        await f.finish();
        expect(f.handlers, 0);
        expect(f.approval.pendingCount, 0);
        await f.close();
      });
    }

    test(
        'one generation has no queue and retains its slot through actual close',
        () async {
      await f.open();
      await f.start();
      final original = f.view!.pending!;
      final acknowledgement = f.connection.server.closing = Completer<void>();
      addTearDown(() {
        if (!acknowledgement.isCompleted) acknowledgement.complete();
      });
      f.view!.reject(original);
      await f.connection.server.written.future;
      await pumpEventQueue(times: 4);
      expect(f.approval.pendingCount, 1);
      expect(f.h.candidate!.budget.used(TlsResource.pipeline), 1);
      final second = BridgeFixture(f.h);
      await second.open(
          prepare: false, attachHost: false, enableStageApprovalWait: true);
      final secondPort = VnextMcpBridgePort(second.bridge);
      final denied = secondPort.call(
          'propose_generated_questions',
          {
            'contextRef': f.contextRef,
            'submission': jsonDecode(submission(key: 'second')),
          },
          cancelled: const Stream.empty(),
          available: () => true);
      f.h.listener.controller.add(tls.MemoryRawPeer(second.server));
      expect((await denied)['error'], isNotNull);
      await secondPort.close();
      expect(f.approval.pendingCount, 1);
      expect(f.handlers, 0);
      acknowledgement.complete();
      await f.finish();
      await expectLater(f.view!.confirm(original), throwsA(anything));
      await f.close();
    });

    test(
        'late click racing shutdown cannot complete an in-flight approval check',
        () async {
      await f.open();
      await f.start();
      final old = f.view!.pending!;
      final barrier = f.h.pairing.local.barrier;
      barrier.reached = Completer<void>();
      final resume = barrier.resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      final click = f.view!.confirm(old);
      await barrier.reached!.future;
      var closed = false;
      final closing = f.controls.shutdown().whenComplete(() => closed = true);
      await pumpEventQueue(times: 4);
      expect(closed, isFalse);
      expect(f.approval.pendingCount, 1);
      resume.complete();
      await click;
      await closing;
      await f.finish();
      expect(f.handlers, 0);
      expect(await f.count('generated_question_proposals'), 0);
      await expectLater(f.view!.confirm(old), throwsA(anything));
    });

    test(
        'publication followed by response loss uses only original-key reconciliation',
        () async {
      await f.open();
      final reached = Completer<void>(), resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      f.h.pairing.local.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.beforeTransaction) f.handlers++;
        if (point == ExternalStageCheckpoint.afterCommit) {
          reached.complete();
          await resume.future;
        }
      };
      await f.start(key: 'human-lost');
      await f.view!.confirm(f.view!.pending!);
      await reached.future;
      await f.port.close();
      expect((await f.result!)['error'], 'outcome_unknown');
      expect(f.approval.pendingCount, 1);
      expect(f.h.candidate!.budget.used(TlsResource.pipeline), 1);
      resume.complete();
      await f.finish();
      expect(f.handlers, 1);
      expect(f.connection.server.writes, isEmpty);
      final read = BridgeFixture(f.h);
      await read.open(prepare: false, binding: f.app);
      final readPort = VnextMcpBridgePort(read.bridge);
      final status = await readPort.call(
          'get_question_proposal', {'submissionKey': 'human-lost'},
          cancelled: const Stream.empty(), available: () => true);
      expect(status['error'], isNull);
      expect((status['data'] as Map)['lifecycleStatus'], 'pending_review');
      await readPort.close();
      expect(f.handlers, 1);
      expect(await f.count('generated_question_proposals'), 1);
      expect(await f.count('questions'), 0);
      await f.close();
    });

    test('B0 Restore cancels waiting before the real database swap', () async {
      await f.open();
      final generated = f.h.pairing.local.local.h;
      // The P11 fixture's metadata-only files are unrelated to this bank-only
      // request. B0 requires every retained file to have real managed bytes.
      await generated.db.delete('project_files');
      await generated.db.delete('library_files');
      final managed = Directory(p.join(generated.temp.path, 'stage-managed'));
      await managed.create();
      final snapshots =
          BackupSnapshotRepository(databaseHelper: generated.helper);
      final backup = BackupRestoreCoordinator(
          operations: BackupRestoreRuntime(
              databaseAuthority: SqliteBackupDatabaseAuthority(
                  databaseHelper: generated.helper,
                  snapshotRepository: snapshots,
                  beforeClose: f.controls.shutdown),
              snapshotRepository: snapshots,
              managedFileStorage:
                  ManagedFileStorageAdapter(managedRoot: managed),
              restoreRoot:
                  Directory(p.join(generated.temp.path, 'stage-restore')),
              managedFilesRoot: managed,
              diskSpaceProbe: _Disk()));
      final path = p.join(generated.temp.path, 'stage-synthetic.zip');
      await backup.exportTo(path);
      await backup.prepareRestore(path);
      await f.start();
      final old = f.view!.pending!;
      expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
      await backup.commitPreparedRestore();
      await f.finish();
      expect(f.handlers, 0);
      await expectLater(f.view!.confirm(old), throwsA(anything));
      final db = await generated.helper.database;
      expect(await db.query('generated_question_proposals'), isEmpty);
      expect(await db.query('external_client_profiles'), isEmpty);
    });

    for (final mode in [
      'reject',
      'timeout',
      'cancel',
      'disconnect',
      'revision',
      'revoke',
      'folder',
      'disable',
      'close',
      'view-close',
      'restore-maintenance'
    ]) {
      test('$mode invalidates the original request before STAGE handler entry',
          () async {
        await f.open();
        final cancellation = StreamController<void>();
        await f.start(cancelled: cancellation.stream);
        final old = f.view!.pending!;
        final local = f.h.pairing.local;
        switch (mode) {
          case 'reject':
            f.view!.reject(old);
          case 'timeout':
            f.advance(const Duration(seconds: 120));
          case 'cancel':
            cancellation.add(null);
          case 'disconnect':
            await f.connection.client.close();
          case 'revision':
            await local.save();
            f.advance(const Duration(seconds: 1));
          case 'revoke':
            final reference =
                await local.view.select(local.reference.profileId);
            final revision =
                (await local.view.read(reference)).profile.grantRevision;
            await local.view.revokeGrant(reference, revision);
            f.advance(const Duration(seconds: 1));
          case 'folder':
            await local.local.h.db.update(
                'bank_folders', {'folder_name': 'moved'},
                where: 'bank_name=?', whereArgs: ['bank']);
            f.advance(const Duration(seconds: 1));
          case 'disable':
            local.trust.disable(local.profile.principal);
            f.advance(const Duration(seconds: 1));
          case 'close':
            unawaited(f.controls.shutdown());
          case 'view-close':
            f.view!.close();
          case 'restore-maintenance':
            final gate = BackupRestoreMutationGate.instance;
            expect(gate.activeMutationCount, 0);
            await gate.enterQuiescence();
            try {
              await expectLater(f.view!.confirm(old), throwsA(anything));
              f.advance(const Duration(seconds: 1));
              await f.result;
            } finally {
              gate.exitQuiescence();
            }
        }
        await f.result;
        await f.finish();
        expect(f.handlers, 0);
        expect(await f.count('generated_question_proposals'), 0);
        await expectLater(f.view!.confirm(old), throwsA(anything));
        await cancellation.close();
        await f.close();
      });
    }
  });
}
