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
  bool expectFailedSettlement = false;
  int responseSequence = 0;
  DurableStageHarness get s => app.h.s;
  Future<void> open() async {
    await app.open();
    await policy(ExternalGenerationMode.review);
    connect();
  }

  void connect({bool protocol = false}) {
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
    if (!protocol) {
      // Direct port fixtures explicitly acknowledge their synthetic I/O. The
      // protocol regressions below exercise the real SDK/transport boundary.
      port.attachTransport(() async {
        port.withdraw();
        port.channelSettled(clean: true);
      });
    }
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
    final id = ++responseSequence;
    final result = await port.call(name, args,
        responseId: id, cancelled: const Stream.empty(), available: () => true);
    port.responseWritten(id);
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
    if (expectFailedSettlement) {
      await expectLater(port.close(), throwsStateError);
      await expectLater(approval.close(), throwsA(isA<Exception>()));
    } else {
      await port.close();
      await approval.close();
    }
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

/// Synthetic native channel with separately controlled write and close ACKs.
/// All JSON-RPC dispatch, serialization and final send use the pinned MCP SDK.
final class _ProtocolLink {
  _ProtocolLink(this.phone, {VnextMcpPort? serverPort}) {
    reader = StreamIterator(input.stream);
    transport = AndroidMcpTransport(
        port: phone.port,
        read: () async {
          if (!await reader.moveNext()) throw StateError('test_eof');
          return reader.current;
        },
        newNonce: () => 'nonce',
        validNonce: (value) => value == 'nonce',
        write: (kind, message) async {
          if (kind != 2) return;
          final id = message['id'];
          writtenIds.add(id);
          if (id == blockedId) {
            writeEntered.complete();
            await releaseWrite.future;
          }
          responses.remove(id)?.complete(message);
        },
        closeChannel: () async {
          unawaited(input.close());
          if (!closeEntered.isCompleted) closeEntered.complete();
          await closeGate?.future;
          if (failClose) throw StateError('test_close_failed');
        },
        invalidate: () {},
        connectionId: 'test-connection',
        current: () => phone.live);
    server = androidDeviceServer(serverPort ?? phone.port);
    settled = server
        .serveTransport(transport)
        .then((_) => true, onError: (Object _, StackTrace __) => false);
  }
  final _Phone phone;
  final input = StreamController<(int, Map<String, dynamic>)>();
  late final StreamIterator<(int, Map<String, dynamic>)> reader;
  late final AndroidMcpTransport transport;
  late final VnextMcpServer server;
  late final Future<bool> settled;
  final responses = <Object?, Completer<Map<String, dynamic>>>{};
  final writtenIds = <Object?>[];
  Object? blockedId;
  final writeEntered = Completer<void>(), releaseWrite = Completer<void>();
  final closeEntered = Completer<void>();
  Completer<void>? closeGate;
  bool failClose = false;

  Future<Map<String, dynamic>> request(
      Object id, String method, Map<String, dynamic> params) {
    final reply = Completer<Map<String, dynamic>>();
    responses[id] = reply;
    input.add(
        (2, {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return reply.future;
  }

  void cancel(Object id) => input.add((
        2,
        {
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': id}
        }
      ));

  Future<Map<String, dynamic>> call(Object id, String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final response =
        await request(id, 'tools/call', {'name': tool, 'arguments': arguments});
    expect(response['error'], isNull);
    return (response['result'] as Map)['structuredContent']
        as Map<String, dynamic>;
  }

  Future<void> initialize() async {
    final result = await request('init', 'initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'offline-test', 'version': '1'}
    });
    expect(result['error'], isNull);
    input.add((2, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
  }
}

/// Hold the real SDK tool callback after the original business owners settle,
/// before it returns a result for SDK serialization/send. No production hook.
final class _BeforeResponsePort implements VnextMcpResponsePort {
  _BeforeResponsePort(this.original);
  final AndroidMcpPort original;
  final entered = Completer<void>(), release = Completer<void>();
  final returned = Completer<void>();

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId}) async {
    final result = await original.call(tool, arguments,
        cancelled: cancelled, available: available, responseId: responseId);
    if (tool == 'propose_generated_questions' && result['error'] == null) {
      await original.binding.whenStageApprovalSettled;
      await original.binding.host.whenSettled;
      entered.complete();
      await release.future;
      returned.complete();
    }
    return result;
  }

  @override
  Future<void> close() => original.close();
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
          responseId: 'cancelled-stage',
          cancelled: cancel.stream,
          available: () => f.live);
      await entered.future;
      expect(
          (await f.port.call('get_question_proposal', {'submissionKey': 'lost'},
              responseId: 'second',
              cancelled: const Stream.empty(),
              available: () => true))['error'],
          'resourceLimit');
      cancel.add(null);
      expect((await result)['error'], isNotNull);
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

  for (final mode in [
    ExternalGenerationMode.review,
    ExternalGenerationMode.direct
  ]) {
    test('SDK $mode retains approval and slot until its own response flush',
        () async {
      await f.policy(mode);
      final context = await f.context();
      final count = await f.s.h.count('questions');
      await f.disconnect();
      f.connect(protocol: true);
      final link = _ProtocolLink(f);
      await link.initialize();
      link.blockedId = 'stage';
      final staged = link.call(
          'stage', 'propose_generated_questions', f.batch(context, 'flush'));
      await link.writeEntered.future;
      expect(await f.s.h.count('generated_question_proposals'), 1);
      expect(await f.s.h.count('questions'),
          count + (mode == ExternalGenerationMode.direct ? 1 : 0));
      expect(f.approval.pendingCount, 1);
      var settled = false;
      final original = f.port.whenSettled.then((_) => settled = true);
      final refused = await link.call(
          2, 'propose_generated_questions', f.batch(context, 'excess'));
      expect(refused['error'], 'resourceLimit');
      expect(f.approval.pendingCount, 1);
      expect(settled, isFalse);
      expect(await f.s.h.count('generated_question_proposals'), 1);
      link.releaseWrite.complete();
      expect((await staged)['error'], isNull);
      await original;
      expect(f.approval.pendingCount, 0);
      expect(
          (await link.call('query', 'get_question_proposal',
              {'submissionKey': 'flush'}))['error'],
          isNull);
      await f.port.whenSettled;
      await link.server.close();
      expect(await link.settled, isTrue);
    });
  }

  for (final failure in ['output', 'close', 'duplicate-id']) {
    test(
        'SDK $failure failure retains non-clean approval after original I/O joins',
        () async {
      await f.policy(ExternalGenerationMode.direct);
      final context = await f.context();
      final count = await f.s.h.count('questions');
      await f.disconnect();
      f.connect(protocol: true);
      final link = _ProtocolLink(f)
        ..closeGate = Completer<void>()
        ..failClose = failure == 'close';
      await link.initialize();
      link.blockedId = 7;
      unawaited(link.call(
          7, 'propose_generated_questions', f.batch(context, 'failed-output')));
      await link.writeEntered.future;
      expect(await f.s.h.count('questions'), count + 1);
      expect(
          (await link.call('excess', 'propose_generated_questions',
              f.batch(context, 'must-not-enter')))['error'],
          'resourceLimit');
      f.expectFailedSettlement = true;
      if (failure == 'close') {
        unawaited(link.transport.close().catchError((Object _) {}));
      } else if (failure == 'duplicate-id') {
        link.input
            .add((2, {'jsonrpc': '2.0', 'id': 7, 'method': 'tools/list'}));
      } else {
        link.releaseWrite.completeError(StateError('test_write_failed'));
      }
      await link.closeEntered.future;
      var settled = false;
      final original = f.port.whenSettled.then((_) => settled = true);
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      expect(f.approval.pendingCount, 1);
      if (failure != 'output') link.releaseWrite.complete();
      link.closeGate!.complete();
      expect(await link.settled, isFalse);
      await original;
      expect(f.approval.pendingCount, 1);
      expect(f.app.host.isReady, isTrue);
      expect(await f.s.h.count('questions'), count + 1);
      expect(await f.s.h.count('generated_question_proposals'), 1);
      expect(await f.s.h.count('generated_question_commit_receipts'), 1);
    });
  }

  for (final scenario in [
    (ExternalGenerationMode.review, 'eof'),
    (ExternalGenerationMode.direct, 'eof'),
    (ExternalGenerationMode.direct, 'protocol'),
    (ExternalGenerationMode.direct, 'wrong-cancel'),
    (ExternalGenerationMode.direct, 'cancel'),
  ]) {
    test(
        'SDK pre-send ${scenario.$1}/${scenario.$2} distinguishes cancellation from lost output',
        () async {
      await f.policy(scenario.$1);
      final context = await f.context();
      final count = await f.s.h.count('questions');
      await f.disconnect();
      f.connect(protocol: true);
      final paused = _BeforeResponsePort(f.port);
      final link = _ProtocolLink(f, serverPort: paused)
        ..closeGate = Completer<void>();
      await link.initialize();
      unawaited(link.call('unwritten', 'propose_generated_questions',
          f.batch(context, 'unwritten')));
      await paused.entered.future;
      expect(await f.s.h.count('generated_question_proposals'), 1);
      expect(await f.s.h.count('questions'),
          count + (scenario.$1 == ExternalGenerationMode.direct ? 1 : 0));
      expect(link.writtenIds, isNot(contains('unwritten')));
      var settled = false;
      final original = f.port.whenSettled.then((_) => settled = true);
      final explicitlyCancelled = scenario.$2 == 'cancel';
      f.expectFailedSettlement = !explicitlyCancelled;
      try {
        if (explicitlyCancelled) {
          link.cancel('unwritten');
        } else if (scenario.$2 == 'protocol') {
          link.input.add((
            2,
            {'jsonrpc': '2.0', 'id': 'unwritten', 'method': 'tools/list'}
          ));
        } else {
          if (scenario.$2 == 'wrong-cancel') link.cancel('unrelated-request');
          unawaited(link.input.close());
        }
        await link.closeEntered.future;
        expect(settled, isFalse);
        expect(f.approval.pendingCount, 1);
        if (scenario.$2 == 'protocol') {
          // SDK still owns the live callback while native close is awaiting
          // acknowledgement. Its late send hits the transport's closed guard.
          paused.release.complete();
          await paused.returned.future;
          await Future<void>.delayed(Duration.zero);
          expect(link.writtenIds, isNot(contains('unwritten')));
        }
        link.closeGate!.complete();
        expect(await link.settled, explicitlyCancelled);
        await original;
        expect(f.approval.pendingCount, explicitlyCancelled ? 0 : 1);
        expect(
            (await f.port.call(
                'propose_generated_questions', f.batch(context, 'replacement'),
                responseId: 'replacement',
                cancelled: const Stream.empty(),
                available: () => true))['error'],
            'unavailable');
        if (!paused.release.isCompleted) paused.release.complete();
        await paused.returned.future;
        await Future<void>.delayed(Duration.zero);
        expect(link.writtenIds, isNot(contains('unwritten')));
        expect(await f.s.h.count('generated_question_proposals'), 1);
        expect(f.app.host.isReady, isTrue);
      } finally {
        if (!link.closeGate!.isCompleted) link.closeGate!.complete();
        if (!paused.release.isCompleted) paused.release.complete();
      }
    });
  }

  test(
      'SDK cancellation suppresses output but waits for business and acknowledged close',
      () async {
    await f.policy(ExternalGenerationMode.direct);
    final context = await f.context();
    await f.disconnect();
    f.connect(protocol: true);
    final link = _ProtocolLink(f)..closeGate = Completer<void>();
    await link.initialize();
    final entered = Completer<void>(), release = Completer<void>();
    f.s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeCommit) {
        entered.complete();
        await release.future;
      }
    };
    unawaited(link.call(
        'cancel', 'propose_generated_questions', f.batch(context, 'cancel')));
    await entered.future;
    link.cancel('cancel');
    await link.closeEntered.future;
    var settled = false;
    final original = f.port.whenSettled.then((_) => settled = true);
    release.complete();
    await f.app.host.whenSettled;
    expect(settled, isFalse);
    expect(f.approval.pendingCount, 1);
    link.closeGate!.complete();
    expect(await link.settled, isTrue);
    await original;
    expect(f.approval.pendingCount, 0);
    expect(await f.s.h.count('generated_question_proposals'), 0);
    f.s.checkpoint = null;
  });
}
