import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/ui/dependencies/generated_question_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import '../application/external/local_host_test_support.dart';
import '../application/external/external_question_read_test_support.dart';
import '../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated, tapGenerated;
import 'fixtures/vnext_mcp_stdio_fixture.dart'
    show fixtureAppMethod, fixtureAppResultMethod;

final class AppAuthentication implements OfflineIpcAuthenticationPort {
  AppAuthentication(this.session);
  ExternalSession? session;
  @override
  Future<ExternalSession?> authenticate() async => session;
}

/// The App/test process alone owns SQLite, approval and all original services.
/// The subprocess is an actual SDK stdio server with a test-only App link.
final class EndToEndHarness {
  final app = OfflineHostHarness();
  late AppAuthentication auth;
  late VnextMcpAppComposition composition;
  final clients = <McpClient>[];
  bool loseResponse = false;
  int stageCalls = 0;

  Future<void> open({bool approve = true}) async {
    await app.open();
    auth = AppAuthentication(app.h.s.session);
    composition = VnextMcpAppComposition(
        host: app.host,
        reads: app.h.read,
        stages: app.h.s.service,
        authentication: auth,
        approvedTargets: [if (approve) await app.h.s.context()]);
  }

  Future<McpClient> connect(
      [McpProtocol protocol = McpProtocol.require2026,
      String? entrypoint]) async {
    final executable = Platform.isWindows ? 'dart.exe' : 'dart';
    final parts =
        p.split(File(Platform.resolvedExecutable).resolveSymbolicLinksSync());
    final flutterCache = p.joinAll(parts.take(parts.lastIndexOf('cache') + 1));
    final client = McpClient(
        const Implementation(name: 'synthetic_client', version: '1.0.0'),
        options: McpClientOptions(protocol: protocol));
    clients.add(client);
    if (entrypoint == null) {
      client.setNotificationHandler<JsonRpcNotification>(fixtureAppMethod,
          (notification) async {
        final tool = notification.params!['tool'] as String;
        if (tool == 'propose_generated_questions') stageCalls++;
        var response = await composition.call(tool,
            (notification.params!['arguments'] as Map).cast<String, dynamic>(),
            cancelled: const Stream.empty(),
            available: () => client.isConnected);
        if (tool == 'propose_generated_questions' && loseResponse) {
          loseResponse = false;
          response = {
            'profileVersion': 1,
            'data': null,
            'error': 'outcome_unknown'
          };
        }
        await client.notification(JsonRpcNotification(
            method: fixtureAppResultMethod,
            params: {'id': notification.params!['id'], 'result': response}));
      },
          (params, meta) => JsonRpcNotification(
              method: fixtureAppMethod, params: params, meta: meta));
    }
    await client.connect(StdioClientTransport(StdioServerParameters(
        command: p.join(flutterCache, 'dart-sdk', 'bin', executable),
        args: [
          entrypoint ?? 'test/mcp/fixtures/vnext_mcp_stdio_fixture.dart',
        ],
        workingDirectory: Directory.current.path,
        stderrMode: ProcessStartMode.normal,
        restartOnUnexpectedExit: false)));
    return client;
  }

  Future<void> close() async {
    for (final client in clients) {
      await client.close();
    }
    await composition.close();
    await app.close();
  }
}

Future<Map<String, dynamic>> call(McpClient client, String tool,
    [Map<String, dynamic> arguments = const {}]) async {
  final result =
      await client.callTool(CallToolRequest(name: tool, arguments: arguments));
  final envelope = result.structuredContent!;
  expect(jsonDecode((result.content.single as TextContent).text), envelope);
  expect(result.isError, envelope['error'] != null);
  return envelope;
}

Map<String, dynamic> batch(String context, String key, {String suffix = ''}) =>
    {
      'contextRef': context,
      'submission': jsonDecode(submission(key: key, items: [
        candidate(
            key: 'choice', kind: 'singleChoice', stem: 'Select one$suffix'),
        candidate(key: 'blank', kind: 'fillBlank', stem: 'Fill answer$suffix'),
        candidate(key: 'short', stem: 'Explain answer$suffix'),
      ])),
    };
Future<String> context(McpClient client) async {
  final targets = await call(client, 'open_generation_context');
  expect(targets['error'], isNull);
  final item = (targets['data']['items'] as List).single as Map;
  final opened = await call(
      client, 'open_generation_context', {'targetRef': item['targetRef']});
  expect(opened['error'], isNull);
  return opened['data']['contextRef'] as String;
}

void main() {
  initializeGeneratedTests();
  late EndToEndHarness h;
  setUp(() async {
    h = EndToEndHarness();
    await h.open();
  });
  tearDown(() async => h.close());

  for (final protocol in [McpProtocol.require2026, McpProtocol.legacy]) {
    test(
        'real stdio ${protocol.name}: stage, duplicate/conflict, reads and key recovery',
        () async {
      final client = await h.connect(protocol);
      final tools = await client.listTools();
      expect(tools.tools.map((t) => t.name).toSet(), {
        'open_generation_context',
        'search_questions',
        'get_question_detail',
        'retrieve_file_content',
        'get_file_passage',
        'propose_generated_questions',
        'get_question_proposal',
      });
      expect(tools.tools.every((t) => t.outputSchema != null), isTrue);
      expect(
          tools.tools
              .where((t) => t.annotations?.readOnlyHint == false)
              .map((t) => t.name),
          ['propose_generated_questions']);
      final byName = {for (final tool in tools.tools) tool.name: tool};
      expect(byName['open_generation_context']!.annotations?.idempotentHint,
          isFalse);
      expect(byName['propose_generated_questions']!.annotations?.idempotentHint,
          isTrue);
      final ref = await context(client);
      final before = await h.app.h.s.h.count('questions');
      final staged = await call(
          client, 'propose_generated_questions', batch(ref, 'batch'));
      expect(staged['error'], isNull);
      expect(staged['data']['publication'], 'STAGED');
      expect(staged['data']['formalCommit'], 'NOT_REPORTED');
      expect(await h.app.h.s.h.count('questions'), before);
      expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
      expect(
          await call(
              client, 'propose_generated_questions', batch(ref, 'batch')),
          staged);
      final conflict = await call(client, 'propose_generated_questions',
          batch(ref, 'batch', suffix: ' changed'));
      expect(conflict['error'], isNotNull);
      expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
      final queried = await call(
          client, 'get_question_proposal', {'submissionKey': 'batch'});
      expect(queried, staged);
      final inbox = GeneratedProposalInboxController(h.app.h.s.localFactory);
      await inbox.load();
      expect(inbox.lastError, isNull);
      expect(inbox.proposals.single.lifecycleStatus,
          GeneratedStatus.pendingReview);
      expect(inbox.proposals.single.items.length, 3);
      inbox.dispose();
      final search = await call(
          client, 'search_questions', {'contextRef': ref, 'query': 'needle'});
      final hit = (search['data']['items'] as List).single as Map;
      expect(
          (await call(client, 'get_question_detail',
              {'contextRef': ref, 'questionRef': hit['questionRef']}))['error'],
          isNull);
      final files =
          await call(client, 'open_generation_context', {'contextRef': ref});
      // This composition installs no File reader or fileContent authority.
      expect(files['data'], isNull);
      expect(files['error'], isNotNull);
      expect(
          (await call(client, 'retrieve_file_content', {
            'contextRef': ref,
            'query': 'not authorized by a source snapshot'
          }))['error'],
          isNotNull);
    });
  }

  test('lost response: new stdio client queries original key without restaging',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    h.loseResponse = true;
    expect(
        (await call(client, 'propose_generated_questions', batch(ref, 'lost')))[
            'error'],
        'outcome_unknown');
    await client.close();
    // Real close/reopen: no old handle, completed-call Map or pending slot can
    // supply this result. Fresh App authentication binds the original Profile.
    await h.composition.close();
    await h.app.h.s.reopen();
    h.app.h.compose();
    h.app.compose();
    await h.app.startHost();
    h.auth.session = h.app.h.s.session;
    h.composition = VnextMcpAppComposition(
        host: h.app.host,
        reads: h.app.h.read,
        stages: h.app.h.s.service,
        authentication: h.auth,
        approvedTargets: []);
    final next = await h.connect();
    final recovered =
        await call(next, 'get_question_proposal', {'submissionKey': 'lost'});
    expect(recovered['error'], isNull);
    expect(recovered['data']['publication'], 'STAGED');
    expect(h.stageCalls, 1);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
    expect(await h.app.h.s.h.count('questions'), 2);
  });

  test(
      'unauthorized, invalid content, expired Context, revoked and unavailable reject',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    h.auth.session = null;
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'denied')))['error'],
        'unauthenticated');
    h.auth.session = h.app.h.s.session;
    final invalid = batch(ref, 'invalid');
    ((invalid['submission'] as Map)['items'] as List).first['unexpected'] =
        true;
    expect(
        (await call(client, 'propose_generated_questions', invalid))['error'],
        isNotNull);
    h.app.h.s.clock.current =
        h.app.h.s.clock.current.add(const Duration(minutes: 16));
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'expired')))['error'],
        isNotNull);
    await h.app.h.s.management.revokeGrant(h.app.h.s.profile, 2);
    expect(
        (await call(client, 'get_question_proposal',
            {'submissionKey': 'denied'}))['error'],
        isNotNull);
    await h.composition.close();
    expect((await call(client, 'open_generation_context'))['error'],
        'unavailable');
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test(
      'READ handle without App approval and a fresh Session cannot inherit STAGE',
      () async {
    final client = await h.connect();
    final ref = await context(client);
    final original = h.app.h.s.session;
    final other = h.app.h.s.trust.openSession(
        h.app.h.s.trust.authenticate(h.app.h.s.credentials.authentication));
    h.auth.session = other;
    expect(
        (await call(client, 'propose_generated_questions',
            batch(ref, 'other-session')))['error'],
        isNotNull);
    h.auth.session = original;
    // A separate trusted composition with no approved target grants no STAGE.
    final unapproved = VnextMcpAppComposition(
        host: h.app.host,
        reads: h.app.h.read,
        stages: h.app.h.s.service,
        authentication: h.auth,
        approvedTargets: []);
    expect(
        (await unapproved.call(
            'propose_generated_questions', batch(ref, 'no-approval'),
            cancelled: const Stream.empty(), available: () => true))['error'],
        isNotNull);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test('COMMIT and claimed authority are absent from the protocol', () async {
    final client = await h.connect(McpProtocol.legacy);
    final ref = await context(client);
    await expectLater(
        client.callTool(CallToolRequest(
            name: 'commit_generated_questions',
            arguments: {'contextRef': ref})),
        throwsA(isA<McpError>()));
    final rejected = await client.callTool(
        CallToolRequest(name: 'propose_generated_questions', arguments: {
      ...batch(ref, 'forged'),
      'clientProfileId': 'forged',
      'trusted': true,
      'bankName': 'private-bank'
    }));
    expect(rejected.isError, isTrue);
    expect(h.stageCalls, 0);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  test(
      'standalone production entrypoint always refuses without admitted App transport',
      () async {
    final client = await h.connect(
        McpProtocol.require2026, 'lib/mcp/vnext_mcp_entrypoint.dart');
    expect((await client.listTools()).tools.length, 7);
    expect((await call(client, 'open_generation_context'))['error'],
        'unavailable');
    expect(
        (await call(client, 'get_question_proposal',
            {'submissionKey': 'absent'}))['error'],
        'unavailable');
    expect(h.stageCalls, 0);
    expect(await h.app.h.s.h.count('generated_question_proposals'), 0);
  });

  testWidgets(
      'stdio Proposal loads existing Review UI; only explicit UI confirmation commits',
      (tester) async {
    final data = (await tester.runAsync(() async {
      final client = await h.connect();
      final ref = await context(client);
      return call(client, 'propose_generated_questions', batch(ref, 'ui'));
    }))!;
    final id = data['data']['proposalId'] as String;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: GeneratedProposalReviewScreen(
              proposalId: id,
              dependencies: GeneratedQuestionDependenciesScope(
                  authority: h.app.h.s.localFactory,
                  service: h.app.h.s.h.service,
                  child: const SizedBox()))));
    });
    Future<void> tap(Finder finder) => tapGenerated(tester, finder);
    await settleGenerated(tester);
    expect(find.textContaining('Select one'), findsWidgets);
    final proposal =
        (await tester.runAsync(() => h.app.h.s.localSession.read(id)))!;
    for (final item in proposal.items) {
      final finder = find.byKey(ValueKey('generated-accepted-${item.itemId}'));
      await tester.scrollUntilVisible(finder, 250,
          scrollable: find.byType(Scrollable).first);
      await tap(finder);
    }
    expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 2);
    await tap(find.byKey(const ValueKey('generated-save')));
    await tap(find.byKey(const ValueKey('generated-confirm')));
    await tap(find.byKey(const ValueKey('generated-approve')));
    expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 2);
    await tap(find.byKey(const ValueKey('generated-confirm')));
    expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
    expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 5);
    expect(
        await tester.runAsync(
            () => h.app.h.s.h.count('generated_question_commit_receipts')),
        1);
    await tester.pumpWidget(const SizedBox());
  });
}
