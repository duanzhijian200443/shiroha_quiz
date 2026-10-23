// Opt-in installed Codex only: existing MCP server/mailbox, Fake TLS, first-party
// Widget and isolated SQLite. No provider/model turn or real Windows Host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_protocol_projection.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import '../application/external/external_question_read_test_support.dart';
import '../data/external/windows_tls_transport_test.dart' as tls;
import 'fixtures/codex_synthetic_app_support.dart';
import 'fixtures/vnext_v3_app_link.dart';
import 'fixtures/stage_cancellation_evidence.dart';

final class _InstalledStage {
  final h = tls.TlsHarness();
  late Directory home;
  late VnextV3AppLink bridge;
  late CodexSyntheticAppLink mailbox;
  late CodexSyntheticClient client;
  late String context;
  int handlers = 0;
  Future<Map<String, dynamic>>? result;
  final evidence = StageCancellationEvidence();
  final callElapsed = Stopwatch();

  Future<void> open(String executable, {int toolTimeout = 150}) async {
    final root = Directory(
        p.join(Directory.current.path, '.dart_tool', 'codex-client-tests'));
    await root.create(recursive: true);
    home = await root.createTemp('installed-stage-');
    await h.open();
    bridge =
        VnextV3AppLink(h, enableStageApprovalWait: true, evidence: evidence);
    final directory = await Directory(p.join(home.path, 'app-link')).create();
    mailbox = CodexSyntheticAppLink(directory, () => bridge, evidence: evidence)
      ..start();
    client = CodexSyntheticClient(executable, home, directory,
        toolTimeoutSeconds: toolTimeout, stageWait: true);
    await client.connect();
    expect(await client.effectiveToolTimeout(), toolTimeout);
    final targets = await client.call('open_generation_context');
    final target = ((targets['data'] as Map)['items'] as List).single as Map;
    final opened = await client
        .call('open_generation_context', {'targetRef': target['targetRef']});
    expect(opened['error'], isNull);
    context = (opened['data'] as Map)['contextRef'] as String;
    h.pairing.local.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeTransaction) handlers++;
    };
  }

  Future<void> start({String key = 'installed-human', bool raw = false}) async {
    final waiting = Completer<void>();
    final subscription = bridge.approval!.changes.listen((_) {
      if (bridge.approval!.waitingForUser && !waiting.isCompleted) {
        waiting.complete();
      }
    });
    final arguments = <String, dynamic>{
      'contextRef': context,
      'submission': jsonDecode(submission(key: key)),
    };
    callElapsed
      ..reset()
      ..start();
    result = raw
        ? client.rawCall('propose_generated_questions', arguments)
        : client.call('propose_generated_questions', arguments);
    try {
      await Future.any([waiting.future, result!.then((_) {})])
          .timeout(const Duration(seconds: 12));
      expect(bridge.approval!.waitingForUser, isTrue);
      expect(bridge.stageSessions, hasLength(1));
      expect(bridge.stageEntries, hasLength(1));
      expect(bridge.stageSessions.single, isNot(same(bridge.sessions.last)));
      expect(handlers, 0);
      expect(await count('generated_question_proposals'), 0);
      expect(bridge.attempts.last.client.writes, hasLength(1));
      expect(bridge.attempts.last.server.writes, isEmpty);
    } finally {
      await subscription.cancel();
    }
  }

  Future<int> count(String table) => h.pairing.local.local.h.count(table);

  void advance(Duration duration) {
    h.pairing.local.clock.current = h.pairing.local.clock.current.add(duration);
    h.deadlines.advance(duration);
  }

  Future<void> settled() async {
    await result;
    await h.candidate!.whenConnectionsSettled
        .timeout(const Duration(seconds: 8));
    await bridge.approval!.whenSettled;
    expect(bridge.approval!.pendingCount, 0);
    for (final attempt in bridge.attempts) {
      attempt.released();
    }
    for (final resource in TlsResource.values) {
      expect(h.candidate!.budget.used(resource), 0, reason: resource.name);
    }
    expect(mailbox.stageCalls, 1);
  }

  Future<void> diagnoseShortTimeout() async {
    final callerReturnedMs = callElapsed.elapsedMilliseconds;
    var owningSettled = false;
    final actualSettlement = h.candidate!.whenConnectionsSettled.then((_) {
      owningSettled = true;
    });
    final observation = Stopwatch()..start();
    await Future.any([
      actualSettlement,
      Future<void>.delayed(const Duration(seconds: 8)),
    ]);
    final atWindow = await StageCancellationEvidence.read(mailbox.directory);
    expect(atWindow.containsKey('wireStage'), isTrue);
    expect(atWindow.containsKey('mailboxStarted'), isTrue);
    if (owningSettled) {
      expect(
          atWindow.containsKey('wireCancel') ||
              atWindow.containsKey('transportClosed'),
          isTrue,
          reason:
              'Do not attribute test expiry/cleanup to client cancellation.');
      await settled();
      return;
    }
    expect(
        observation.elapsed, greaterThanOrEqualTo(const Duration(seconds: 8)));
    // A new real MCP call proves the original stdio connection remains usable.
    // It queries metadata only, and cannot approve or repeat the pending STAGE.
    final probe = await client.rawCall('get_question_proposal',
        {'submissionKey': 'probe-after-client-timeout'});
    final afterProbe = await StageCancellationEvidence.read(mailbox.directory);
    final missingClientSignal = !afterProbe.containsKey('wireCancel') &&
        !afterProbe.containsKey('transportClosed');
    final stageAttempt = bridge.attempts[2];
    if (missingClientSignal) {
      expect(afterProbe.containsKey('wireProbe'), isTrue);
      expect(afterProbe.containsKey('sdkAbort'), isFalse);
      expect(afterProbe.containsKey('mailboxExpired'), isFalse);
      expect(afterProbe.containsKey('cancelWritten'), isFalse);
      expect(mailbox.stageCancellationPresent, isFalse);
      expect(evidence.events.containsKey('parentCancel'), isFalse);
      expect(evidence.events.containsKey('bridgeCallReturned'), isFalse);
      expect(stageAttempt.client.closeCalls, 0);
      expect(stageAttempt.server.closeCalls, 0);
      expect(bridge.approval!.waitingForUser, isTrue);
      expect(bridge.approval!.pendingCount, 1);
      expect(h.candidate!.budget.used(TlsResource.pipeline), 1);
      expect(handlers, 0);
    }
    final beforeBound = <String, Object?>{
      'callerReturnedMs': callerReturnedMs,
      'probeReturnedRpcError': probe.containsKey('error'),
      'observedAfterCallerMs': observation.elapsedMilliseconds,
      'wire': afterProbe,
      'parent': evidence.events,
      'cancelFile': mailbox.stageCancellationPresent,
      'bridgeChannelCloseCalls': stageAttempt.client.closeCalls,
      'hostChannelCloseCalls': stageAttempt.server.closeCalls,
      'approvalWaiting': bridge.approval!.waitingForUser,
      'approvalSlots': bridge.approval!.pendingCount,
      'hostPipelines': h.candidate!.budget.used(TlsResource.pipeline),
      'handlerEntries': handlers,
    };
    // Observe the original App's fixed human bound using the existing fake clock.
    // This is explicitly NOT a Codex cancellation or a real 120s wall-time test.
    advance(const Duration(seconds: 120));
    await actualSettlement.timeout(const Duration(seconds: 8));
    await bridge.approval!.whenSettled;
    for (var i = 0; i < 100; i++) {
      if (mailbox.stageCancellationPresent) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final afterBound = await StageCancellationEvidence.read(mailbox.directory);
    expect(handlers, 0);
    expect(await count('generated_question_proposals'), 0);
    expect(bridge.approval!.pendingCount, 0);
    stageAttempt.released();
    for (final resource in TlsResource.values) {
      expect(h.candidate!.budget.used(resource), 0, reason: resource.name);
    }
    expect(evidence.events.containsKey('owningSettled'), isTrue);
    expect(afterBound.containsKey('mailboxResponse'), isTrue);
    expect(afterBound.containsKey('mailboxExpired'), isFalse);
    expect(afterBound.containsKey('cancelWritten'), isTrue);
    // Fixed phase names, counts and monotonic timings only; never print bodies.
    // ignore: avoid_print
    print('CANCELLATION_EVIDENCE ${jsonEncode({
          'classification':
              missingClientSignal ? 'CLIENT_NO_CANCEL' : 'DOWNSTREAM_GAP',
          'shortDeadlineAcceptance': 'FAIL',
          'mailboxStageLimitSeconds': 150,
          'ordinaryMailboxLimitSeconds': 8,
          'beforeAppBound': beforeBound,
          'afterSyntheticAppBound': {
            'wire': afterBound,
            'parent': evidence.events,
            'approvalSlots': bridge.approval!.pendingCount,
            'hostPipelines': h.candidate!.budget.used(TlsResource.pipeline),
          },
        })}');
    fail(missingClientSignal
        ? 'CLIENT_NO_CANCEL: tool timeout returned; no matching MCP cancellation '
            'or stdio close. Original human bound settled; short deadline NOT_ACCEPTED.'
        : 'DOWNSTREAM_GAP: client signal observed but owning settlement missing.');
  }

  Future<void> recovered(String key) async {
    final session = bridge.stageSessions.single;
    final status =
        await client.call('get_question_proposal', {'submissionKey': key});
    expect(status['error'], isNull);
    expect(status['data'], {
      'submissionKey': key,
      'lifecycleStatus': 'pending_review',
      'requestedCount': 1,
      'actualCount': 1,
      'committedCount': 0,
      'rejectedCount': 0,
    });
    expect(bridge.sessions.last, isNot(same(session)));
    expect(handlers, 1);
    expect(mailbox.stageCalls, 1);
    expect(await count('generated_question_proposals'), 1);
    expect(await count('generated_question_commit_receipts'), 0);
    expect(await count('questions'), 0);
    final frame =
        VnextMcpCommand.decodeFrame(bridge.attempts.last.client.writes.single);
    expect((jsonDecode(frame.payload) as Map)['input'], {'submissionKey': key});
    await h.candidate!.whenConnectionsSettled;
    bridge.attempts.last.released();
  }

  Future<void> close() async {
    // Let every request settle before checking EOF/process identity and deleting
    // this task-owned child home. No process-name kill or shared-home cleanup.
    await mailbox.close();
    await bridge.close();
    await client.disconnect();
    await h.close();
    expect(
        await home
            .list(recursive: true)
            .where((f) => f.path.endsWith('.pid'))
            .isEmpty,
        isTrue);
    expect(
        p.isWithin(
            p.join(Directory.current.path, '.dart_tool', 'codex-client-tests'),
            home.absolute.path),
        isTrue);
    await home.delete(recursive: true);
    expect(home.existsSync(), isFalse);
  }
}

void main() {
  initializeGeneratedTests();
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  if (!Platform.isWindows || executable == null) {
    test('installed Codex STAGE is UNVERIFIED', () {},
        skip: 'Windows + explicit installed SHIROHA_CODEX_EXE required.');
    return;
  }

  for (final mode in [
    'approve-after-default-timeout',
    'reject',
    'cancel',
    'timeout',
    'revision',
    'revoke',
    'target',
    'disconnect',
    'close',
    'published-response-loss',
    'short-client-timeout',
    'short-client-timeout-evidence',
  ]) {
    testWidgets('installed Codex STAGE $mode', (tester) async {
      final f = _InstalledStage();
      await tester.runAsync(() => f.open(executable,
          toolTimeout: mode.startsWith('short-client-timeout') ? 2 : 150));
      try {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: FirstPartyExternalControl(
                        access: f.bridge.controls!)))));
        await tester.runAsync(
            () => f.start(raw: mode.startsWith('short-client-timeout')));
        await tester.pump();
        final approve = find.widgetWithText(FilledButton, '批准本次暂存');
        expect(approve, findsOneWidget);
        expect(
            find.byKey(const Key('external-stage-approval')), findsOneWidget);
        final lateClick = tester.widget<FilledButton>(approve).onPressed!;
        final originalRevision = await tester.runAsync(() async {
          final local = f.h.pairing.local;
          final ref = await local.view.select(local.reference.profileId);
          return (await local.view.read(ref)).profile.grantRevision;
        });
        if (mode == 'approve-after-default-timeout') {
          // Real wall time crosses BOTH the old 10s Bridge and Codex's documented
          // 60s default. No fake-clock advance can stand in for this evidence.
          await tester.runAsync(() async {
            final elapsed = Stopwatch()..start();
            await Future<void>.delayed(const Duration(seconds: 61));
            expect(elapsed.elapsed, greaterThan(const Duration(seconds: 60)));
            f.advance(elapsed.elapsed);
            await f.bridge.approval!.whenSettled;
            expect(f.bridge.approval!.waitingForUser, isTrue);
            expect(f.handlers, 0);
            expect(await f.count('generated_question_proposals'), 0);
          });
          await tester.pump();
        }
        if (mode == 'approve-after-default-timeout' ||
            mode == 'published-response-loss') {
          if (mode == 'published-response-loss') {
            // Lose only the final TLS response after the real publication.
            f.bridge.attempts.last.server.transform = (_) => Uint8List(0);
          }
          await tester.tap(approve);
          await tester.runAsync(() async {
            final result = await f.result!;
            expect(result['error'],
                mode == 'published-response-loss' ? 'outcome_unknown' : isNull);
            expect(f.handlers, 1);
            final context = f.bridge.contexts.last;
            expect(context.session, same(f.bridge.stageSessions.single));
            expect(context.stageContext!.grantRevision, originalRevision);
            final expected = f.h.pairing.local.local.h.target;
            expect(context.stageContext!.target.bankName, expected.bankName);
            expect(context.stageContext!.target.projectId, expected.projectId);
            expect(
                context.stageContext!.target.folderName, expected.folderName);
            await f.settled();
            await f.recovered('installed-human');
          });
        } else {
          var shortSettled = false;
          if (mode == 'reject') {
            await tester.tap(find.text('拒绝本次暂存'));
          }
          await tester.runAsync(() async {
            final local = f.h.pairing.local;
            switch (mode) {
              case 'cancel':
                await f.mailbox.close();
              case 'timeout':
                f.advance(const Duration(seconds: 120));
              case 'revision':
                await local.save();
                f.advance(const Duration(seconds: 1));
              case 'revoke':
                final ref = await local.view.select(local.reference.profileId);
                await local.view.revokeGrant(ref, originalRevision!);
                f.advance(const Duration(seconds: 1));
              case 'target':
                await local.local.h.db.update(
                    'bank_folders', {'folder_name': 'moved'},
                    where: 'bank_name=?', whereArgs: ['bank']);
                f.advance(const Duration(seconds: 1));
              case 'disconnect':
                await f.bridge.attempts.last.client.close();
              case 'close':
                await f.bridge.controls!.shutdown();
            }
            final result = await f.result!.timeout(
                mode.startsWith('short-client-timeout')
                    ? const Duration(seconds: 8)
                    : const Duration(seconds: 20));
            if (mode.startsWith('short-client-timeout')) {
              // This must be Codex's actual tool timeout, not our 160s RPC
              // watchdog or the 150s test mailbox deadline.
              expect(result['error'], isA<Map>());
              expect(jsonEncode(result['error']), contains('timed out'));
              // A caller timeout is insufficient unless the original request
              // also receives cancellation and its owning connection drains.
            } else {
              expect(result['error'], isNotNull);
            }
            if (mode == 'short-client-timeout-evidence') {
              await f.diagnoseShortTimeout();
            }
            await f.settled();
            shortSettled = true;
            expect(f.handlers, 0);
            expect(await f.count('generated_question_proposals'), 0);
          });
          if (mode.startsWith('short-client-timeout') && !shortSettled) return;
          // A captured real Widget action after invalidation cannot revive S.
          lateClick();
          await tester.runAsync(() => f.bridge.approval!.whenSettled);
          await tester.pump();
          expect(f.handlers, 0);
        }
      } finally {
        // Explicit test cleanup while the Widget is still mounted. Never count
        // this teardown cancellation as a signal emitted by the installed client.
        await tester.runAsync(() => f.bridge.controls!.shutdown());
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(f.close);
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
