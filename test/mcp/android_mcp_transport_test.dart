import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/android_device_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/mcp/android_mcp_transport.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import '../application/external/local_host_test_support.dart';
import '../application/external/durable_stage_test_support.dart';

/// Original P10/Application/SQLite owners with synthetic credentials. No device,
/// network, saved key or model is used here.
final class _Phone {
  final app = OfflineHostHarness();
  late FirstPartyStageApproval approval;
  late AndroidMcpPort port;
  bool live = true;
  DurableStageHarness get s => app.h.s;
  Future<void> open() async {
    await app.open();
    await policy(ExternalGenerationMode.review);
    connect();
  }

  void connect() {
    live = true;
    approval = FirstPartyStageApproval(
        host: app.host,
        stages: s.service,
        localOwner: s.localSession,
        compositionIsCurrent: () => true);
    final session = s.session;
    port = AndroidMcpPort(
        VnextMcpAppComposition(
            host: app.host,
            reads: app.h.read,
            stages: s.service,
            authentication: VnextMcpSessionAuthentication(
                () async => live ? session : null),
            stageApproval: approval,
            approvedTargets: const []),
        () => live);
  }

  Future<void> policy(ExternalGenerationMode? mode) async {
    final revision = (await s.management.read(s.profile)).profile.grantRevision;
    await s.management.replaceGrant(
        s.profile,
        revision,
        mode == null
            ? androidQuestionReadPolicy()
            : ExternalGrantPolicy(permissions: const [
                CapabilityPermission.read,
                CapabilityPermission.stage
              ], scopes: [
                s.bank
              ], categories: const [
                ExternalContentCategory.questionContent,
                ExternalContentCategory.proposalMetadata
              ], generationMode: mode));
  }

  Future<Map<String, Object?>> call(String name,
      [Map<String, dynamic> args = const {}]) async {
    final result = await port.call(name, args,
        cancelled: const Stream.empty(), available: () => true);
    await port.whenSettled;
    return result;
  }

  Future<String> context() async {
    final listed = await call('open_generation_context');
    expect(listed['error'], isNull);
    final target = ((listed['data'] as Map)['items'] as List)
        .cast<Map>()
        .firstWhere((item) => item['bankName'] == 'bank');
    final opened = await call(
        'open_generation_context', {'targetRef': target['targetRef']});
    expect(opened['error'], isNull);
    return (opened['data'] as Map)['contextRef'] as String;
  }

  Map<String, dynamic> batch(String context, String key, {String? stem}) => {
        'contextRef': context,
        'submission': jsonDecode(submission(
            key: key,
            items: [candidate(stem: stem ?? 'Android candidate $key')]))
      };
  Future<Map> query(String key) async {
    final result = await call('get_question_proposal', {'submissionKey': key});
    expect(result['error'], isNull);
    final data = result['data'] as Map;
    expect(data.keys.toSet(), {
      'submissionKey',
      'lifecycleStatus',
      'requestedCount',
      'actualCount',
      'committedCount',
      'rejectedCount'
    });
    return data;
  }

  Future<void> disconnect() async {
    live = false;
    await port.close();
    await approval.close();
    expect(app.host.isReady, isTrue);
  }

  Future<void> reopen() async {
    await disconnect();
    await app.host.shutdown();
    app.h.read.close();
    await s.reopen();
    app.h.compose();
    app.compose();
    await app.startHost();
    connect();
  }

  Future<void> close() async {
    await disconnect();
    await app.close();
  }
}

void main() {
  initializeGeneratedTests();
  late _Phone f;
  setUp(() async {
    f = _Phone();
    await f.open();
  });
  tearDown(() => f.close());

  test('seven schemas; old READ grant and all file modes refuse', () async {
    expect(VnextMcpServer.inputSchemas.length, 7);
    await f.policy(null);
    final context = await f.context();
    expect(
        (await f.call('propose_generated_questions',
            f.batch(context, 'old-read')))['error'],
        isNotNull);
    expect(
        (await f.call(
            'get_question_proposal', {'submissionKey': 'old-read'}))['error'],
        isNotNull);
    for (final tool in ['retrieve_file_content', 'get_file_passage']) {
      expect((await f.call(tool))['error'], 'unavailable');
    }
    for (final args in [
      {'contextRef': context},
      {
        'contextRef': context,
        'fileRefs': [context]
      }
    ]) {
      expect((await f.call('open_generation_context', args))['error'],
          'unavailable');
    }
    expect(await f.s.h.count('generated_question_proposals'), 0);
    await f.reopen();
    expect(
        (await f.call(
            'get_question_proposal', {'submissionKey': 'old-read'}))['error'],
        isNotNull);
  });

  test(
      'review publishes without a view; reopen and local Review retain authority',
      () async {
    final count = await f.s.h.count('questions');
    final context = await f.context();
    for (final key in ['A', 'B']) {
      final result =
          await f.call('propose_generated_questions', f.batch(context, key));
      expect(result['error'], isNull);
      expect((result['data'] as Map)['publication'], 'STAGED');
      expect((result['data'] as Map)['formalCommit'], 'NOT_REPORTED');
      expect((await f.query(key))['lifecycleStatus'], 'pending_review');
    }
    expect(await f.s.h.count('questions'), count);
    await f.reopen();
    expect((await f.query('A'))['lifecycleStatus'], 'pending_review');
    expect((await f.query('B'))['lifecycleStatus'], 'pending_review');
    await f.disconnect();
    final proposals = await f.s.localSession.pending();
    final a = proposals.firstWhere((p) => p.submissionKey == 'A');
    final local = f.s.localSession.confirmDisplayedTarget(a.target);
    final reviewed = await f.s.h.service.flush(
        GeneratedReviewFlush.fromJson({
          'proposalId': a.proposalId,
          'expectedReviewRevision': a.reviewRevision,
          'operations': [
            for (final item in a.items)
              {'type': 'decide', 'itemId': item.itemId, 'decision': 'accepted'}
          ]
        }),
        local);
    await f.s.h.service.approve(f.s.h.approval(reviewed), local);
    final b = proposals.firstWhere((p) => p.submissionKey == 'B');
    final rejected = await f.s.h.service.flush(
        GeneratedReviewFlush.fromJson({
          'proposalId': b.proposalId,
          'expectedReviewRevision': b.reviewRevision,
          'operations': [
            for (final item in b.items)
              {'type': 'decide', 'itemId': item.itemId, 'decision': 'rejected'}
          ]
        }),
        f.s.localSession.confirmDisplayedTarget(b.target));
    await f.s.h.service.reject(
        RejectGeneratedProposalCommand.fromJson({
          'proposalId': b.proposalId,
          'expectedReviewRevision': rejected.reviewRevision
        }),
        f.s.localSession.confirmDisplayedTarget(b.target));
    expect(await f.s.h.count('questions'), count + 1);
    f.connect();
    expect((await f.query('A'))['committedCount'], 1);
    expect((await f.query('B'))['lifecycleStatus'], 'rejected');
    expect((await f.query('B'))['rejectedCount'], 1);
  });

  test(
      'revision invalidates old context; direct changes only new keys with original conflicts',
      () async {
    final count = await f.s.h.count('questions');
    final old = await f.context();
    expect(
        (await f.call(
            'propose_generated_questions', f.batch(old, 'B')))['error'],
        isNull);
    await f.policy(ExternalGenerationMode.direct);
    expect(
        (await f.call(
            'propose_generated_questions', f.batch(old, 'C')))['error'],
        isNotNull);
    expect((await f.query('B'))['lifecycleStatus'], 'pending_review');
    expect(await f.s.h.count('questions'), count);
    final context = await f.context();
    expect(
        (await f.call(
            'propose_generated_questions', f.batch(context, 'B')))['error'],
        isNull);
    expect((await f.query('B'))['lifecycleStatus'], 'pending_review');
    final batch = f.batch(context, 'C');
    expect(
        (await f.call('propose_generated_questions', batch))['error'], isNull);
    expect((await f.query('C'))['committedCount'], 1);
    expect(
        (await f.call('propose_generated_questions', batch))['error'], isNull);
    expect(
        (await f.call('propose_generated_questions',
            f.batch(context, 'C', stem: 'conflicting content')))['error'],
        isNotNull);
    expect(await f.s.h.count('questions'), count + 1);
    expect(await f.s.h.count('generated_question_commit_receipts'), 1);
  });

  for (final afterCommit in [false, true]) {
    test(
        'cancel ${afterCommit ? 'after' : 'before'} commit retains original settlement and durable outcome',
        () async {
      await f.policy(ExternalGenerationMode.direct);
      final count = await f.s.h.count('questions');
      final context = await f.context();
      final entered = Completer<void>(), release = Completer<void>();
      f.s.checkpoint = (point) async {
        if (point ==
            (afterCommit
                ? ExternalStageCheckpoint.afterCommit
                : ExternalStageCheckpoint.beforeCommit)) {
          entered.complete();
          await release.future;
        }
      };
      final cancel = StreamController<void>.broadcast(sync: true);
      final result = f.port.call(
          'propose_generated_questions', f.batch(context, 'lost'),
          cancelled: cancel.stream, available: () => f.live);
      await entered.future;
      cancel.add(null);
      expect((await result)['error'], isNotNull);
      expect(
          (await f.port.call('get_question_proposal', {'submissionKey': 'lost'},
              cancelled: const Stream.empty(), available: () => true))['error'],
          'resourceLimit');
      var closed = false;
      final closing = f.port.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(f.approval.pendingCount, 1);
      release.complete();
      await closing;
      await cancel.close();
      expect(f.approval.pendingCount, 0);
      expect(f.app.host.isReady, isTrue);
      f.s.checkpoint = null;
      await f.reopen();
      if (afterCommit) {
        expect((await f.query('lost'))['lifecycleStatus'], 'committed');
      } else {
        expect(
            (await f.call(
                'get_question_proposal', {'submissionKey': 'lost'}))['error'],
            isNotNull);
      }
      expect(await f.s.h.count('questions'), count + (afterCommit ? 1 : 0));
      expect(await f.s.h.count('generated_question_proposals'),
          afterCommit ? 1 : 0);
    });
  }

  test('legacy confirm needs its own view; leaving cannot approve', () async {
    await f.policy(ExternalGenerationMode.confirm);
    final context = await f.context();
    expect(
        (await f.call('propose_generated_questions',
            f.batch(context, 'no-view')))['error'],
        isNotNull);
    final view = f.approval.openView();
    final waiting = Completer<void>();
    final subscription = view.changes.listen((_) {
      if (view.pending != null && !waiting.isCompleted) waiting.complete();
    });
    final result =
        f.call('propose_generated_questions', f.batch(context, 'cancel-view'));
    await waiting.future;
    view.close();
    expect((await result)['error'], isNotNull);
    await subscription.cancel();
    expect(await f.s.h.count('generated_question_proposals'), 0);
  });
}
