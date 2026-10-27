// Real stdio SDK + existing Fake TLS + the isolated original App/P10/P8.
// The existing test-only reverse notifications carry calls to this parent;
// no network socket, real credential operation or production startup is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_bridge_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_protocol_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import '../../data/external/fixtures/windows_tls_bridge_cases.dart';
import '../../data/external/windows_tls_transport_test.dart' as tls;
import 'codex_app_server_support.dart' show flutterDartExecutable;
import 'vnext_mcp_stdio_fixture.dart'
    show fixtureAppMethod, fixtureAppResultMethod;
import 'vnext_mcp_test_support.dart' show SubmissionEncodingProbe, batch, call;
import 'vnext_tls_file_fixture.dart';
import 'vnext_v3_app_link.dart';
import '../../application/external/external_question_read_test_support.dart'
    show submission;
import '../../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;

const _ref = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, dynamic> _v3Data(Map<String, Object?> value) {
  expect(value['profileVersion'], 2);
  expect(value['error'], isNull);
  return (value['data'] as Map).cast<String, dynamic>();
}

Future<String> _v3Context(VnextV3AppLink link) async {
  final targets = _v3Data(await link.invoke('open_generation_context'));
  final selected = (targets['items'] as List).single as Map;
  return _v3Data(await link.invoke('open_generation_context',
      {'targetRef': selected['targetRef']}))['contextRef'] as String;
}

Future<McpClient> _stdio(VnextMcpPort port, McpProtocol protocol) async {
  final client = McpClient(
      const Implementation(name: 'bridge_fixture', version: '1.0.0'),
      options: McpClientOptions(protocol: protocol));
  addTearDown(client.close);
  client.setNotificationHandler<JsonRpcNotification>(fixtureAppMethod,
      (notification) async {
    final result = await port.call(notification.params!['tool'] as String,
        (notification.params!['arguments'] as Map).cast<String, dynamic>(),
        cancelled: const Stream.empty(), available: () => client.isConnected);
    await client.notification(JsonRpcNotification(
        method: fixtureAppResultMethod,
        params: {'id': notification.params!['id'], 'result': result}));
  },
      (params, meta) => JsonRpcNotification(
          method: fixtureAppMethod, params: params, meta: meta));
  await client.connect(StdioClientTransport(StdioServerParameters(
      command: flutterDartExecutable(),
      args: ['test/mcp/fixtures/vnext_mcp_stdio_fixture.dart'],
      workingDirectory: Directory.current.path,
      stderrMode: ProcessStartMode.normal,
      restartOnUnexpectedExit: false)));
  return client;
}

void vnextBridgeCases(tls.TlsHarness Function() harness) {
  group('v3 Bridge selectors through real P10/P8/P7', () {
    late tls.TlsHarness h;
    late VnextV3AppLink link;
    setUp(() {
      h = harness();
      link = VnextV3AppLink(h);
    });

    for (final protocol in [McpProtocol.require2026, McpProtocol.legacy]) {
      test(
          'real stdio ${protocol.name}: fresh-connection target/search/detail and STAGE refusal',
          () async {
        await insertLegacyQuestion(h.pairing.local.local.h.db,
            id: 'v3-question',
            bankName: 'bank',
            createdAt: 1,
            content: 'Synthetic needle');
        final client = await _stdio(link, protocol);
        final targets = (await call(client, 'open_generation_context'))['data'];
        final target = (targets['items'] as List).single as Map;
        final opened = await call(client, 'open_generation_context',
            {'targetRef': target['targetRef']});
        final ref = opened['data']['contextRef'];
        final search = await call(
            client, 'search_questions', {'contextRef': ref, 'query': 'needle'});
        final hit = (search['data']['items'] as List).single as Map;
        final detail = await call(client, 'get_question_detail',
            {'contextRef': ref, 'questionRef': hit['questionRef']});
        expect(detail['data']['sourceKind'], 'legacy');
        expect(link.sessions.toSet(), hasLength(4));
        expect(link.contexts.toSet(), hasLength(4));
        for (final attempt in link.attempts) {
          final wire = jsonDecode(
              VnextMcpCommand.decodeFrame(attempt.client.writes.single)
                  .payload) as Map;
          expect(wire['schemaVersion'], 3);
        }
        expect(
            await call(client, 'propose_generated_questions',
                batch(ref as String, 'never-stage')),
            vnextFailure('capability.accessDenied'));
        expect(link.attempts.last.client.writes, isEmpty);
        expect(
            await h.pairing.local.local.h.count('generated_question_proposals'),
            0);
      });
    }

    test(
        'explicit File selections/context, retrieval and Passage use the same SQLite/F1/FTS',
        () async {
      final isolated = tls.TlsHarness();
      final files = VnextTlsFileFixture(isolated.pairing.local);
      isolated.pairing.local.fileReader = files.reader;
      await isolated.open();
      addTearDown(isolated.close);
      final fileLink = VnextV3AppLink(isolated);
      fileLink.configureGrant = () async {
        final local = isolated.pairing.local;
        final reference = await local.view.select(local.reference.profileId);
        final revision =
            (await local.view.read(reference)).profile.grantRevision;
        await local.view.save(reference, revision,
            permissions: [CapabilityPermission.read],
            targets: (await local.view.targets()).where((t) =>
                t.scope.projectId == null &&
                {'bank', VnextTlsFileFixture.fileId}
                    .contains(t.scope.targetId)),
            categories: [
              ExternalContentCategory.questionContent,
              ExternalContentCategory.fileContent
            ]);
      };
      final parent = await _v3Context(fileLink);
      final choices = _v3Data(await fileLink
          .invoke('open_generation_context', {'contextRef': parent}));
      final selected = (choices['items'] as List).single as Map;
      final ref = _v3Data(await fileLink.invoke('open_generation_context', {
        'contextRef': parent,
        'fileRefs': [selected['fileRef']]
      }))['contextRef'];
      expect(ref, isNot(parent));
      final search = _v3Data(await fileLink.invoke(
          'retrieve_file_content', {'contextRef': ref, 'query': 'needle'}));
      final hit = (search['items'] as List).single as Map;
      expect(hit['content'], contains('needle'));
      expect(search['startsAtDocumentBeginning'], isFalse);
      final passage = _v3Data(await fileLink.invoke('get_file_passage',
          {'contextRef': ref, 'passageRef': hit['passageRef']}));
      expect(passage['items'], isNotEmpty);
      expect(passage['hasMore'], isTrue);
      expect(passage['unsupportedExcluded'], isTrue);
      expect(files.index.searched.toSet(), {VnextTlsFileFixture.fileId});
      expect(files.source.reads, greaterThan(0));
      expect(
          (await fileLink.invoke('retrieve_file_content',
              {'contextRef': parent, 'query': 'needle'}))['data'],
          isNull);
      expect(
          await isolated.pairing.local.local.h
              .count('generated_question_proposals'),
          0);
    });

    test(
        'original-key lifecycle uses independent READ/metadata after all old READ handles are stale',
        () async {
      await _v3Context(link);
      final local = h.pairing.local;
      final channel = tls.MemoryTlsChannel();
      final authenticated = await h.verifier.authenticate(channel, h.plan);
      // Explicit synthetic App seed, never a Bridge approval or STAGE request.
      final approved = await local.stages
          .approveTarget(authenticated.session, local.local.h.target, []);
      await local.stages.stage(
          session: authenticated.session,
          context: approved,
          submissionJson: submission(key: 'original-tls-key'),
          control: ExternalCallControl(clock: local.clock),
          responseAvailable: () => true);
      h.verifier.invalidateChannel(channel);
      await channel.close();
      final reference = await local.view.select(local.reference.profileId);
      final revision = (await local.view.read(reference)).profile.grantRevision;
      await local.view.save(reference, revision,
          permissions: [CapabilityPermission.read],
          targets: (await local.view.targets()).where(
              (t) => t.scope.targetId == 'bank' && t.scope.projectId == null),
          categories: [ExternalContentCategory.proposalMetadata]);
      final status = _v3Data(await link.invoke(
          'get_question_proposal', {'submissionKey': 'original-tls-key'}));
      expect(status['submissionKey'], 'original-tls-key');
      expect(status['lifecycleStatus'], 'pending_review');
      final request =
          VnextMcpCommand.decodeFrame(link.attempts.last.client.writes.single);
      expect(request.requestId, isNot('original-tls-key'));
      expect((jsonDecode(request.payload) as Map)['input'],
          {'submissionKey': 'original-tls-key'});
      expect(
          (await link.invoke('get_question_proposal',
              {'submissionKey': request.requestId!}))['error'],
          'capability.generatedProposalUnavailable');
      expect(await local.local.h.count('generated_question_proposals'), 1);
    });

    for (final mode in [
      'wrong-kind',
      'foreign-execution',
      'revoked',
      'expired',
      'after-binding-disable'
    ]) {
      test('$mode cannot release data on a fresh TLS connection', () async {
        final ref = await _v3Context(link);
        String selected = ref;
        if (mode == 'wrong-kind') {
          selected = ((jsonDecode(
              VnextMcpCommand.decodeFrame(link.attempts[1].client.writes.single)
                  .payload) as Map)['input'] as Map)['targetRef'] as String;
        }
        if (mode == 'foreign-execution') link.foreignExecution = true;
        if (mode == 'revoked') {
          final local = h.pairing.local;
          final reference = await local.view.select(local.reference.profileId);
          final revision =
              (await local.view.read(reference)).profile.grantRevision;
          await local.view.revokeGrant(reference, revision);
        }
        if (mode == 'expired') {
          h.pairing.local.clock.current =
              h.pairing.local.clock.current.add(const Duration(minutes: 16));
        }
        if (mode == 'after-binding-disable') {
          link.afterBinding = () async =>
              h.pairing.local.trust.disable(link.sessions.last.principal);
        }
        final result = await link.invoke(
            'search_questions', {'contextRef': selected, 'query': 'needle'});
        expect(result['data'], isNull);
        expect(result['error'], isNotNull);
        expect(
            await h.pairing.local.local.h.count('generated_question_proposals'),
            0);
      });
    }

    test(
        'Bridge STAGE remains zero-write, zero-serialization and zero-publication under v3',
        () async {
      final ref = await _v3Context(link);
      final probe = SubmissionEncodingProbe();
      expect(
          await link.invoke('propose_generated_questions', {
            'contextRef': ref,
            'submission': {
              'schemaVersion': 1,
              'submissionKey': 'no-stage',
              'requestedCount': 1,
              'items': [probe]
            }
          }),
          vnextFailure('capability.accessDenied'));
      expect(probe.encoded, isFalse);
      expect(link.attempts.last.client.writes, isEmpty);
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          0);
    });
  });
  group('inactive vNext Bridge projection', () {
    late tls.TlsHarness h;
    late BridgeFixture f;
    late VnextMcpBridgePort port;
    late VnextMcpAppComposition app;
    Future<Map<String, Object?>> invoke(String tool,
            [Map<String, dynamic> arguments = const {}]) =>
        port.call(tool, arguments,
            cancelled: const Stream.empty(), available: () => true);
    setUp(() {
      h = harness();
      f = BridgeFixture(h);
      final local = h.pairing.local;
      app = VnextMcpAppComposition(
          host: local.coordinator.host,
          reads: local.reads,
          stages: local.stages,
          authentication: VnextMcpSessionAuthentication(() async => null),
          approvedTargets: const []);
    });
    Future<void> attach({bool host = true}) async {
      await f.open(attachHost: host, binding: app);
      port = VnextMcpBridgePort(f.bridge);
      addTearDown(port.close);
    }

    test('shared mapping retains defaults, selector modes and original key',
        () {
      final inputs = <String, Map<String, dynamic>>{
        'open_generation_context': {},
        'search_questions': {'contextRef': _ref, 'query': 'needle'},
        'get_question_detail': {'contextRef': _ref, 'questionRef': _ref},
        'retrieve_file_content': {'contextRef': _ref, 'query': 'needle'},
        'get_file_passage': {'contextRef': _ref, 'passageRef': _ref},
        'propose_generated_questions': batch(_ref, 'original-key'),
        'get_question_proposal': {'submissionKey': 'original-key'},
      };
      final capabilities = [
        'external_list_targets',
        'external_search_questions',
        'external_get_question_detail',
        'external_retrieve_file_content',
        'external_get_file_passage',
        'external_stage_generated_questions',
        'external_get_proposal_lifecycle',
      ];
      var index = 0;
      for (final entry in inputs.entries) {
        final command = VnextMcpCommand.parse(entry.key, entry.value);
        expect(command.capability, capabilities[index++]);
        expect(command.needsAppBinding, entry.key != 'open_generation_context');
        final wire =
            jsonDecode(command.request('correlation-only').payload) as Map;
        expect(wire.keys.toSet(),
            {'schemaVersion', 'type', 'capability', 'input'});
        expect(wire['schemaVersion'], 3);
        expect((wire['input'] as Map)['contextRef'], entry.value['contextRef']);
        if (command.contextKind == VnextMcpContextKind.stage) {
          expect(command.input['externalRequestId'], isNull);
          expect(
              jsonDecode(
                  command.input['submissionJson'] as String)['submissionKey'],
              'original-key');
        }
        if (command.contextKind == VnextMcpContextKind.proposalLifecycle) {
          expect(command.input, isEmpty);
          expect(command.submissionKey, 'original-key');
          expect(wire['input'], {'submissionKey': 'original-key'});
        }
      }
      expect(VnextMcpCommand.parse('open_generation_context', {}).input,
          {'pageSize': 20, 'cursor': null});
      expect(
          VnextMcpCommand.parse('search_questions', inputs['search_questions']!)
              .input,
          {'query': 'needle', 'pageSize': 20, 'cursor': null});
      expect(
          VnextMcpCommand.parse(
                  'retrieve_file_content', inputs['retrieve_file_content']!)
              .input,
          {'query': 'needle', 'limit': 8});
      expect(
          VnextMcpCommand.parse('open_generation_context', {'targetRef': _ref})
              .needsAppBinding,
          isFalse);
      expect(
          VnextMcpCommand.parse('open_generation_context', {'contextRef': _ref})
              .capability,
          'external_list_file_selections');
      expect(
          VnextMcpCommand.parse('open_generation_context', {
            'contextRef': _ref,
            'fileRefs': [_ref]
          }).capability,
          'external_create_file_context');
      for (final invalid in [
        {'targetRef': _ref, 'pageSize': 20},
        {'contextRef': _ref, 'targetRef': _ref},
        {
          'fileRefs': [_ref]
        },
        {'contextRef': null},
        {'profile': 'claimed'},
      ]) {
        expect(() => VnextMcpCommand.parse('open_generation_context', invalid),
            throwsA(anything));
      }
    });

    test(
        'STAGE classification materializes no payload for oversized or deep submissions',
        () async {
      await attach();
      final oversizedProbe = SubmissionEncodingProbe();
      final oversized = <String, dynamic>{
        'contextRef': _ref,
        'submission': {
          'schemaVersion': 1,
          'submissionKey': 'oversized',
          'requestedCount': 1,
          'items': [oversizedProbe],
          'padding': 'x' * (1024 * 1024 + 1),
        },
      };
      final command =
          VnextMcpCommand.parse('propose_generated_questions', oversized);
      expect(() => command.input, throwsA(isA<FormatException>()));
      expect(oversizedProbe.encoded, isFalse);
      expect(await invoke('propose_generated_questions', oversized),
          vnextFailure('capability.accessDenied'));
      expect(oversizedProbe.encoded, isFalse);

      final deepProbe = SubmissionEncodingProbe();
      Object nested = deepProbe;
      for (var i = 0; i < 20; i++) {
        nested = [nested];
      }
      final deep = <String, dynamic>{
        'contextRef': _ref,
        'submission': {
          'schemaVersion': 1,
          'submissionKey': 'deep',
          'requestedCount': 1,
          'items': [nested],
        },
      };
      expect(
          () =>
              VnextMcpCommand.parse('propose_generated_questions', deep).input,
          throwsA(isA<FormatException>()));
      expect(deepProbe.encoded, isFalse);
      expect(await invoke('propose_generated_questions', deep),
          vnextFailure('capability.accessDenied'));
      expect(deepProbe.encoded, isFalse);
      expect(f.client.writes, isEmpty);
    });

    for (final protocol in [McpProtocol.require2026, McpProtocol.legacy]) {
      test(
          'real stdio ${protocol.name}: seven unchanged schemas, safe READ and refusals',
          () async {
        await attach();
        final client = await _stdio(port, protocol);
        final tools = (await client.listTools()).tools;
        expect(tools.map((tool) => tool.name).toSet(),
            VnextMcpServer.inputSchemas.keys.toSet());
        for (final tool in tools) {
          expect(
              tool.inputSchema.toJson(),
              JsonObject.fromJson(VnextMcpServer.inputSchemas[tool.name]!)
                  .toJson());
        }
        expect(
            await call(client, 'propose_generated_questions',
                batch(_ref, 'never-sent')),
            vnextFailure('capability.accessDenied'));
        expect(f.client.writes, isEmpty);
        final result = await call(client, 'open_generation_context');
        expect(result['error'], isNull);
        expect((result['data']['items'] as List), isNotEmpty);
        expect(f.client.writes, hasLength(1));
        expect(await call(client, 'open_generation_context'),
            vnextFailure('unavailable'));
        expect(f.client.writes, hasLength(1));
        expect(
            await h.pairing.local.local.h.count('generated_question_proposals'),
            0);
        await h.candidate!.whenConnectionsSettled;
        f.released();
      });
    }

    test(
        'target selection remains an opaque App-minted reference, under fresh admission',
        () async {
      await attach();
      final binding =
          await h.verifier.authenticate(tls.MemoryTlsChannel(), h.plan);
      final targets =
          await h.pairing.local.reads.listTargets(session: binding.session);
      final result = await invoke('open_generation_context',
          {'targetRef': targets.items.single.targetRef});
      expect(result['error'], isNull);
      expect((result['data'] as Map)['contextRef'],
          matches(r'^[A-Za-z0-9_-]{43}$'));
    });

    test(
        'request before server verification never regains capability after connect',
        () async {
      late Future<Map<String, Object?>> pending;
      f.beforePeerPolicy = () {
        port = VnextMcpBridgePort(f.bridge);
        pending = invoke('open_generation_context');
      };
      await f.open(binding: app);
      addTearDown(port.close);
      expect(await pending, vnextFailure('unavailable'));
      expect(
          await invoke('open_generation_context'), vnextFailure('unavailable'));
      expect(f.client.writes, isEmpty);
    });

    for (final mode in [
      'closed-connection',
      'unauthenticated',
      'foreign-context',
      'revoked',
      'wrong-target'
    ]) {
      test('$mode releases no data or writes', () async {
        if (mode == 'closed-connection') {
          // Constructing the Port cannot bypass the transport's own verification.
          await f.open(attachHost: false);
          await f.bridge.close();
          port = VnextMcpBridgePort(f.bridge);
        } else {
          await f.open(
              enabled: mode != 'unauthenticated',
              context: mode == 'foreign-context'
                  ? (session) async {
                      final foreign = await h.verifier
                          .authenticate(tls.MemoryTlsChannel(), h.plan);
                      expect(identical(session, foreign.session), isFalse);
                      final host = h.pairing.local.coordinator.host;
                      return host
                          .openRead(await host.bindSession(foreign.session));
                    }
                  : null);
          port = VnextMcpBridgePort(f.bridge);
        }
        addTearDown(port.close);
        if (mode == 'revoked') {
          final local = h.pairing.local;
          final reference = await local.view.select(local.reference.profileId);
          final revision =
              (await local.view.read(reference)).profile.grantRevision;
          await local.view.revokeGrant(reference, revision);
        }
        final result = await invoke('open_generation_context',
            mode == 'wrong-target' ? {'targetRef': _ref} : {});
        expect(result['data'], isNull);
        expect(result['error'], isNotNull);
        expect(
            await h.pairing.local.local.h.count('generated_question_proposals'),
            0);
      });
    }

    test('STAGE refusal never invokes even an App-approved Context supplier',
        () async {
      var openings = 0;
      await f.open(context: (session) async {
        openings++;
        final local = h.pairing.local;
        final approved =
            await local.stages.approveTarget(session, local.local.h.target, []);
        return local.coordinator.host.openStage(
            await local.coordinator.host.bindSession(session), approved);
      });
      port = VnextMcpBridgePort(f.bridge);
      addTearDown(port.close);
      expect(
          await invoke(
              'propose_generated_questions', batch(_ref, 'original-key')),
          vnextFailure('capability.accessDenied'));
      expect(openings, 0);
      expect(f.client.writes, isEmpty);
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          0);
    });

    test(
        'caller withdrawal after response production withholds data and cannot reopen',
        () async {
      await attach();
      var available = true;
      f.server.transform = (frame) {
        available = false;
        return frame;
      };
      expect(
          await port.call('open_generation_context', {},
              cancelled: const Stream.empty(), available: () => available),
          vnextFailure('cancelled'));
      available = true;
      expect(
          await invoke('open_generation_context'), vnextFailure('unavailable'));
      expect(f.client.writes, hasLength(1));
    });

    for (final mode in [
      'extra-field',
      'wrong-capability',
      'wrong-version',
      'duplicate-key',
      'failure'
    ]) {
      test('strict correlated P10 response: $mode', () async {
        await attach();
        f.server.transform = (frame) {
          final envelope = VnextMcpCommand.decodeFrame(frame);
          final body = jsonDecode(envelope.payload) as Map;
          switch (mode) {
            case 'extra-field':
              (body['data'] as Map)['unexpected'] = true;
            case 'wrong-capability':
              body['capability'] = 'external_create_read_context';
              body['data'] = {'contextRef': _ref};
            case 'wrong-version':
              body['schemaVersion'] = 1;
            case 'failure':
              body['data'] = null;
              body['error'] = 'capability.accessDenied';
          }
          final payload = mode == 'duplicate-key'
              ? '${jsonEncode(body).substring(0, jsonEncode(body).length - 1)},"error":null}'
              : jsonEncode(body);
          return IpcEnvelopeCodec.encodeResponse(envelope.requestId!, payload);
        };
        expect(
            await invoke('open_generation_context'),
            vnextFailure(mode == 'failure'
                ? 'capability.accessDenied'
                : 'invalidResult'));
        expect(f.client.writes, hasLength(1));
      });
    }

    test('shared response rejects a substituted original lifecycle key', () {
      final command = VnextMcpCommand.parse(
          'get_question_proposal', {'submissionKey': 'original'});
      final frame = IpcEnvelopeCodec.encodeResponse(
          'id',
          jsonEncode({
            'schemaVersion': 3,
            'type': 'result',
            'capability': command.capability,
            'data': {
              'submissionKey': 'id',
              'lifecycleStatus': 'pending_review',
              'requestedCount': 1,
              'actualCount': 1,
              'committedCount': 0,
              'rejectedCount': 0
            },
            'error': null,
          }));
      expect(() => command.response(VnextMcpCommand.decodeFrame(frame), 'id'),
          throwsA(anything));
    });

    for (final mode in ['cancel', 'timeout', 'disconnect', 'close']) {
      test(
          '$mode consumes old capability and waits original close/write settlement',
          () async {
        await attach(host: false);
        f.client.writing = Completer<void>();
        final cancelled = StreamController<void>(sync: true);
        addTearDown(cancelled.close);
        final pending = port.call('open_generation_context', {},
            cancelled: cancelled.stream, available: () => true);
        await f.client.written.future;
        if (mode == 'cancel') cancelled.add(null);
        if (mode == 'timeout') h.deadlines.advance(const Duration(seconds: 2));
        if (mode == 'disconnect') await f.client.close();
        Future<void>? closing;
        if (mode == 'close') closing = port.close();
        if (mode != 'disconnect') {
          expect(await pending, vnextFailure('outcome_unknown'));
        }
        expect(await invoke('open_generation_context'),
            vnextFailure('unavailable'));
        expect(f.bridge.budget.used(TlsResource.pipeline), 1);
        var settled = false;
        closing ??= port.close();
        final drain = closing.then((_) => settled = true);
        await pumpEventQueue(times: 2);
        expect(settled, isFalse);
        f.client.writing!.complete();
        f.client.writing = null;
        expect(await pending, vnextFailure('outcome_unknown'));
        await drain;
        f.released();
      });
    }

    test(
        'unavailable caller cannot regain the old connection after restoration',
        () async {
      await attach(host: false);
      expect(
          await port.call('open_generation_context', {},
              cancelled: const Stream.empty(), available: () => false),
          vnextFailure('unavailable'));
      expect(
          await invoke('open_generation_context'), vnextFailure('unavailable'));
      expect(f.client.writes, isEmpty);
      await port.close();
      final rebuilt = VnextMcpBridgePort(f.bridge);
      expect(
          await rebuilt.call('open_generation_context', {},
              cancelled: const Stream.empty(), available: () => true),
          vnextFailure('unavailable'));
      await rebuilt.close();
    });

    test('concurrent requests never send another frame', () async {
      await attach(host: false);
      final pending = invoke('open_generation_context');
      await f.client.written.future;
      expect(
          await invoke('open_generation_context'), vnextFailure('unavailable'));
      await port.close();
      expect(await pending, vnextFailure('outcome_unknown'));
      expect(f.client.writes, hasLength(1));
    });
  });
}
