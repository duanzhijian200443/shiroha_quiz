// Actual installed Codex -> existing mailbox -> Bridge -> P9/P10 v3 -> P8/P7.
// Public mathematical credentials, Fake TLS and isolated SQLite only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_protocol_projection.dart';
import '../application/external/external_question_read_test_support.dart';
import '../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import '../data/external/windows_tls_transport_test.dart' as tls;
import 'fixtures/codex_synthetic_app_support.dart';
import 'fixtures/vnext_mcp_test_support.dart'
    show batch, SubmissionEncodingProbe;
import 'fixtures/vnext_tls_file_fixture.dart';
import 'fixtures/vnext_v3_app_link.dart';

const _unknownRef = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, dynamic> _data(Map<String, dynamic> result) {
  expect(result['error'], isNull);
  return (result['data'] as Map).cast<String, dynamic>();
}

/// Authorization results only. Transport/local outcomes (`outcome_unknown`,
/// `unavailable`, `cancelled`, `invalidRequest`, `invalidResult`) are never a
/// refusal: counting one would turn an unknown outcome into an authorization
/// PASS.
const _capabilityRefused = {
  'capability.accessDenied',
  'capability.externalReadDenied',
  'capability.externalReadStale',
  'capability.externalReadDataCorrupt',
};

void _denied(Map<String, dynamic> result,
    {Set<String> codes = _capabilityRefused}) {
  expect(result['data'], isNull);
  expect(codes, contains(result['error']), reason: '${result['error']}');
}

void main() {
  initializeGeneratedTests();
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  final skip = Platform.isWindows && executable != null
      ? false
      : 'UNVERIFIED: Windows + explicit SHIROHA_CODEX_EXE required.';
  late tls.TlsHarness h;
  late VnextTlsFileFixture files;
  late VnextV3AppLink bridge;
  late CodexSyntheticAppLink mailbox;
  late CodexSyntheticClient client;
  late Directory home;

  setUp(() async {
    final root = Directory(
        p.join(Directory.current.path, '.dart_tool', 'codex-client-tests'));
    await root.create(recursive: true);
    home = await root.createTemp('Codex Bridge v3 合成 ');
    h = tls.TlsHarness();
    files = VnextTlsFileFixture(h.pairing.local);
    h.pairing.local.fileReader = files.reader;
    await h.open();
    await insertLegacyQuestion(h.pairing.local.local.h.db,
        id: 'codex-v3-question',
        bankName: 'bank',
        createdAt: 1,
        content: 'Synthetic needle');
    bridge = VnextV3AppLink(h);
    bridge.configureGrant = () async {
      final local = h.pairing.local;
      final ref = await local.view.select(local.reference.profileId);
      final revision = (await local.view.read(ref)).profile.grantRevision;
      await local.view.save(ref, revision,
          permissions: [CapabilityPermission.read, CapabilityPermission.stage],
          targets: (await local.view.targets()).where((t) =>
              t.scope.projectId == null &&
              {'bank', VnextTlsFileFixture.fileId}.contains(t.scope.targetId)),
          categories: ExternalContentCategory.values);
    };
    final directory = await Directory(p.join(home.path, 'app-link')).create();
    mailbox = CodexSyntheticAppLink(directory, () => bridge)..start();
    client = CodexSyntheticClient(executable!, home, directory);
    await client.connect();
  });

  tearDown(() async {
    try {
      await client.disconnect();
    } finally {
      try {
        await mailbox.close();
        await bridge.close();
        await h.close();
      } finally {
        await home.delete(recursive: true);
        expect(home.existsSync(), isFalse);
      }
    }
  });

  Future<String> parent() async {
    final targets = _data(await client.call('open_generation_context'));
    final target = (targets['items'] as List).single as Map;
    return _data(await client.call('open_generation_context',
        {'targetRef': target['targetRef']}))['contextRef'] as String;
  }

  Future<String> selected(String context) async {
    final choices = _data(
        await client.call('open_generation_context', {'contextRef': context}));
    return _data(await client.call('open_generation_context', {
      'contextRef': context,
      'fileRefs': [(choices['items'] as List).single['fileRef']]
    }))['contextRef'] as String;
  }

  void assertV3() {
    expect(bridge.sessions.toSet(), hasLength(bridge.sessions.length));
    expect(bridge.contexts.toSet(), hasLength(bridge.contexts.length));
    expect(bridge.sessions, hasLength(bridge.attempts.length));
    expect(bridge.contexts, hasLength(bridge.attempts.length));
    for (final attempt in bridge.attempts) {
      final wire = VnextMcpCommand.decodeFrame(attempt.client.writes.single);
      expect((jsonDecode(wire.payload) as Map)['schemaVersion'], 3);
      attempt.released();
    }
  }

  test(
      'six non-STAGE tools use fresh authenticated v3 bindings and real F1/FTS',
      () async {
    final context = await parent();
    final search = _data(await client
        .call('search_questions', {'contextRef': context, 'query': 'needle'}));
    final hit = (search['items'] as List).single as Map;
    final detail = _data(await client.call('get_question_detail',
        {'contextRef': context, 'questionRef': hit['questionRef']}));
    expect(detail['sourceKind'], 'legacy');
    expect(jsonEncode(detail['stem']), contains('Synthetic needle'));
    final fileContext = await selected(context);
    expect(fileContext, isNot(context));
    final retrieved = _data(await client.call('retrieve_file_content',
        {'contextRef': fileContext, 'query': 'needle'}));
    final fileHit = (retrieved['items'] as List).single as Map;
    expect(fileHit['content'], contains('needle'));
    var passage = _data(await client.call('get_file_passage',
        {'contextRef': fileContext, 'passageRef': fileHit['passageRef']}));
    expect(passage['unsupportedExcluded'], isTrue);
    var pages = 1;
    while (passage['hasMore'] == true) {
      expect(pages++, lessThan(20));
      passage = _data(await client.call('get_file_passage', {
        'contextRef': fileContext,
        'passageRef': fileHit['passageRef'],
        'cursor': passage['nextCursor']
      }));
    }
    expect(pages, greaterThan(1));
    expect(files.index.searched.toSet(), {VnextTlsFileFixture.fileId});
    expect(files.source.reads, greaterThan(0));
    // Seed only via the original App service; no Bridge STAGE or approval bypass.
    final local = h.pairing.local;
    final seedChannel = tls.MemoryTlsChannel();
    final seed = await h.verifier.authenticate(seedChannel, h.plan);
    final approved = await local.stages
        .approveTarget(seed.session, local.local.h.target, []);
    await local.stages.stage(
        session: seed.session,
        context: approved,
        submissionJson: submission(key: 'codex-original-key'),
        control: ExternalCallControl(clock: local.clock),
        responseAvailable: () => true);
    h.verifier.invalidateChannel(seedChannel);
    await seedChannel.close();
    // Change policy: every old READ handle is stale; lifecycle needs READ only.
    final ref = await local.view.select(local.reference.profileId);
    final revision = (await local.view.read(ref)).profile.grantRevision;
    await local.view.save(ref, revision,
        permissions: [CapabilityPermission.read],
        targets: (await local.view.targets()).where(
            (t) => t.scope.targetId == 'bank' && t.scope.projectId == null),
        categories: [ExternalContentCategory.proposalMetadata]);
    final status = _data(await client.call(
        'get_question_proposal', {'submissionKey': 'codex-original-key'}));
    expect(status, {
      'submissionKey': 'codex-original-key',
      'lifecycleStatus': 'pending_review',
      'requestedCount': 1,
      'actualCount': 1,
      'committedCount': 0,
      'rejectedCount': 0
    });
    final wire =
        VnextMcpCommand.decodeFrame(bridge.attempts.last.client.writes.single);
    expect((jsonDecode(wire.payload) as Map)['input'],
        {'submissionKey': 'codex-original-key'});
    expect(wire.requestId, isNot('codex-original-key'));
    expect(
        (await client.call('get_question_proposal',
            {'submissionKey': wire.requestId}))['error'],
        'capability.generatedProposalUnavailable');
    assertV3();
    expect(mailbox.stageCalls, 0);
  }, skip: skip);

  for (final mode in [
    'forged',
    'wrong-kind',
    'cross-context',
    'foreign-principal',
    'foreign-execution',
    'expired',
    'revoked',
    'after-binding-disable'
  ]) {
    test(
        mode == 'after-binding-disable'
            ? 'after-binding-disable releases no data but no business result'
            : '$mode safely withholds data through actual Codex call',
        () async {
      void expectBridgeRefusal(int attemptsBefore) {
        // A refusal only counts once the request actually crossed the Bridge.
        expect(bridge.attempts, hasLength(attemptsBefore + 1),
            reason: 'refusal must use one fresh Bridge connection');
        final frame = VnextMcpCommand.decodeFrame(
            bridge.attempts.last.client.writes.single);
        expect((jsonDecode(frame.payload) as Map)['schemaVersion'], 3);
      }

      final codes = switch (mode) {
        'revoked' => const {'unauthenticated'},
        // Trust withdrawal closes the owning connection before any business
        // frame is produced. The caller outcome is unknown, NOT an
        // authorization refusal; no data or publication is released.
        'after-binding-disable' => const {'outcome_unknown'},
        _ => _capabilityRefused,
      };
      final context = await parent();
      var selectedContext = context;
      if (mode == 'forged') selectedContext = _unknownRef;
      if (mode == 'wrong-kind') {
        final wire = VnextMcpCommand.decodeFrame(
            bridge.attempts[1].client.writes.single);
        selectedContext =
            (jsonDecode(wire.payload) as Map)['input']['targetRef'];
      }
      if (mode == 'foreign-principal') {
        // A second isolated App authenticates its own Principal normally. The
        // original App's READ handle must not authorize that Principal.
        final other = tls.TlsHarness();
        await other.open();
        final foreign = VnextV3AppLink(other);
        final original = bridge;
        bridge = foreign;
        try {
          final attempts = foreign.attempts.length;
          _denied(
              await client.call('search_questions',
                  {'contextRef': context, 'query': 'needle'}),
              codes: codes);
          expectBridgeRefusal(attempts);
          expect(foreign.sessions.single.principal,
              isNot(same(original.sessions.first.principal)));
          expect(
              await other.pairing.local.local.h
                  .count('generated_question_proposals'),
              0);
        } finally {
          await foreign.close();
          await other.close();
          bridge = original;
        }
        return;
      }
      if (mode == 'foreign-execution') bridge.foreignExecution = true;
      if (mode == 'expired') {
        // Expire P4's handle while independently re-enabling fresh Sessions.
        h.pairing.local.clock.current =
            h.pairing.local.clock.current.add(const Duration(minutes: 16));
        await h.pairing.local.coordinator
            .enable(h.pairing.local.profile, const Duration(minutes: 5));
      }
      if (mode == 'revoked') {
        final local = h.pairing.local;
        final ref = await local.view.select(local.reference.profileId);
        await local.view.revokeGrant(
            ref, (await local.view.read(ref)).profile.grantRevision);
      }
      if (mode == 'after-binding-disable') {
        bridge.afterBinding = () async =>
            h.pairing.local.trust.disable(bridge.sessions.last.principal);
      }
      if (mode == 'cross-context') {
        final first = _data(await client.call(
            'search_questions', {'contextRef': context, 'query': 'needle'}));
        final second = await parent();
        final attempts = bridge.attempts.length;
        _denied(
            await client.call('get_question_detail', {
              'contextRef': second,
              'questionRef': (first['items'] as List).single['questionRef']
            }),
            codes: codes);
        expectBridgeRefusal(attempts);
      } else {
        final attempts = bridge.attempts.length;
        _denied(
            await client.call('search_questions',
                {'contextRef': selectedContext, 'query': 'needle'}),
            codes: codes);
        expectBridgeRefusal(attempts);
      }
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          0);
    }, skip: skip);
  }

  test('forged File/Passage/cursor and parent File access reject', () async {
    Future<void> refused(Future<Map<String, dynamic>> request) async {
      final attempts = bridge.attempts.length;
      _denied(await request);
      expect(bridge.attempts, hasLength(attempts + 1));
      final frame = VnextMcpCommand.decodeFrame(
          bridge.attempts.last.client.writes.single);
      expect((jsonDecode(frame.payload) as Map)['schemaVersion'], 3);
    }

    final context = await parent();
    await refused(client.call('open_generation_context', {
      'contextRef': context,
      'fileRefs': [_unknownRef]
    }));
    final fileContext = await selected(context);
    await refused(client.call(
        'retrieve_file_content', {'contextRef': context, 'query': 'needle'}));
    await refused(client.call('get_file_passage',
        {'contextRef': fileContext, 'passageRef': _unknownRef}));
    final found = _data(await client.call('retrieve_file_content',
        {'contextRef': fileContext, 'query': 'needle'}));
    final ref = (found['items'] as List).single['passageRef'];
    await refused(client.call('get_file_passage',
        {'contextRef': fileContext, 'passageRef': ref, 'cursor': _unknownRef}));
  }, skip: skip);

  test(
      'Bridge STAGE sends no frame, serializes no Submission, publishes nothing',
      () async {
    final context = await parent();
    final before = bridge.sessions.length;
    expect(
        (await client.call('propose_generated_questions',
            batch(context, 'codex-never-stage')))['error'],
        'capability.accessDenied');
    expect(bridge.attempts.last.client.writes, isEmpty);
    expect(bridge.sessions, hasLength(before));
    // JSON RPC necessarily serializes its input. Observe the separate Bridge
    // Submission encoder at the same port boundary with an object probe.
    final probe = SubmissionEncodingProbe();
    expect(
        (await bridge.invoke('propose_generated_questions', {
          'contextRef': context,
          'submission': {
            'schemaVersion': 1,
            'submissionKey': 'probe',
            'requestedCount': 1,
            'items': [probe]
          }
        }))['error'],
        'capability.accessDenied');
    expect(probe.encoded, isFalse);
    expect(bridge.attempts.last.client.writes, isEmpty);
    expect(
        await h.pairing.local.local.h.count('generated_question_proposals'), 0);
  }, skip: skip);

  test('lost Bridge response stays unknown; EOF/reconnect authenticates afresh',
      () async {
    final context = await parent();
    final sessions = bridge.sessions.toSet();
    bridge.configureAttempt = (f) {
      f.server.transform = (_) => Uint8List(0);
    };
    expect(
        (await client.call('search_questions',
            {'contextRef': context, 'query': 'needle'}))['error'],
        'outcome_unknown');
    bridge.configureAttempt = null;
    expect(bridge.attempts.last.client.writes, hasLength(1));
    await client.disconnect();
    await client.connect();
    final result = _data(await client
        .call('search_questions', {'contextRef': context, 'query': 'needle'}));
    expect(result['items'], hasLength(1));
    expect(sessions.contains(bridge.sessions.last), isFalse);
    assertV3();
    expect(
        await h.pairing.local.local.h.count('generated_question_proposals'), 0);
  }, skip: skip);

  test('mailbox withdrawal cancels binding and drains before fresh reconnect',
      () async {
    final context = await parent();
    final reached = Completer<void>(), resume = Completer<void>();
    bridge.afterBinding = () async {
      reached.complete();
      await resume.future;
    };
    final pending = client
        .call('search_questions', {'contextRef': context, 'query': 'needle'});
    await reached.future;
    final closing = mailbox.close();
    // Let the existing mailbox forward cancellation before binding completes.
    // The connection owner closes on cancellation; observe it deterministically.
    final attempt = bridge.attempts.last;
    final waiting = Stopwatch()..start();
    try {
      while (attempt.client.isOpen &&
          waiting.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(attempt.client.isOpen, isFalse);
    } finally {
      // A failed assertion must still release the original binding owner.
      resume.complete();
    }
    await closing;
    expect((await pending)['error'], 'outcome_unknown');
    bridge.afterBinding = null;
    await client.disconnect();
    final directory =
        await Directory(p.join(home.path, 'reconnected-link')).create();
    mailbox = CodexSyntheticAppLink(directory, () => bridge)..start();
    client = CodexSyntheticClient(executable!, home, directory);
    await client.connect();
    expect(
        _data(await client.call('search_questions',
            {'contextRef': context, 'query': 'needle'}))['items'],
        hasLength(1));
  }, skip: skip);
}
