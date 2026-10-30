import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_study_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_protocol_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/mcp/vnext_app_owned_client.dart';
import '../application/external/external_question_read_test_support.dart';
import '../application/external/local_host_test_support.dart';
import '../application/study_query/study_query_test_support.dart'
    show insertReviewState;
import 'fixtures/vnext_mcp_test_support.dart' show AppAuthentication, batch;

void main() {
  initializeGeneratedTests();
  late QuestionReadHarness h;
  late ExternalReadContextService reads;
  late LocalHostDispatchCore host;
  late AppAuthentication authentication;
  late VnextMcpAppComposition app;

  Future<void> grant({bool statistics = true}) async {
    final revision =
        (await h.s.management.read(h.s.profile)).profile.grantRevision;
    await h.s.management.replaceGrant(
        h.s.profile,
        revision,
        h.s.policy(permissions: [
          CapabilityPermission.read,
          CapabilityPermission.stage
        ], categories: [
          ExternalContentCategory.questionContent,
          ExternalContentCategory.proposalMetadata,
          if (statistics) ExternalContentCategory.studyStatistics,
        ]));
  }

  setUp(() async {
    h = QuestionReadHarness();
    await h.open();
    await h.legacy('one');
    await insertReviewState(h.s.h.db,
        questionId: 'one', lapses: 2, lastLapseTime: 5);
    await grant();
    reads = ExternalReadContextService(
        admission: h.s.service.runtimeAdmission,
        targets:
            SqliteExternalTargetReadRepository(databaseHelper: h.s.h.helper),
        questions:
            SqliteExternalQuestionReadRepository(databaseHelper: h.s.h.helper),
        study: SqliteExternalStudyReadRepository(databaseHelper: h.s.h.helper));
    host = LocalHostDispatchCore(
        gateway: ExternalCapabilityGateway(
            stages: h.s.service, reads: reads, enableStudyQueries: true),
        readiness: OfflineReadiness(() async {}));
    await host.startOffline();
    authentication = AppAuthentication(h.s.session);
    app = VnextMcpAppComposition(
        host: host,
        reads: reads,
        stages: h.s.service,
        authentication: authentication,
        profileVersion: 3,
        source: const VnextDataSource('windows', 'local'),
        approvedTargets: [await h.s.context()]);
  });
  tearDown(() async {
    await app.close();
    await host.shutdown();
    reads.close();
    await reads.whenIdle;
    await h.close();
  });

  Future<Map<String, Object?>> invoke(String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final result = await app.call(tool, arguments,
        cancelled: const Stream.empty(), available: () => true);
    expect(result['profileVersion'], 3);
    expect(result['source'], {'kind': 'windows', 'deviceRef': 'local'});
    return result;
  }

  Future<Map> data(String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final result = await invoke(tool, arguments);
    expect(result['error'], isNull, reason: '$tool: $result');
    return result['data'] as Map;
  }

  Future<String> context() async =>
      (await data('open_context'))['contextRef'] as String;

  test('explicit profile exposes eleven tools and retains seven-tool profile',
      () {
    expect(VnextMcpServer.schemasFor(3).keys.toSet(), {
      'open_context',
      'list_question_banks',
      'get_study_overview',
      'get_due_review_summary',
      'get_weak_questions',
      'search_questions',
      'get_question_detail',
      'retrieve_file_content',
      'get_file_passage',
      'propose_generated_questions',
      'get_question_proposal',
    });
    expect(VnextMcpServer.schemasFor(2), hasLength(7));
    expect(() => VnextMcpServer.schemasFor(4), throwsArgumentError);
    expect(
        () => VnextMcpCommand.parse('open_context', {}), throwsFormatException);
  });

  test('full v4 dispatch queries aggregate, bank and opaque weak details',
      () async {
    final ref = await context();
    final banks = await data('list_question_banks', {'contextRef': ref});
    expect(banks['statisticsAuthorized'], true);
    expect(banks['items'], hasLength(1));
    final bank = (banks['items'] as List).single as Map;
    final single = await data(
        'open_context', {'scope': 'bank', 'targetRef': bank['targetRef']});
    expect(
        (await data('get_study_overview',
            {'contextRef': single['contextRef']}))['questionCount'],
        1);
    final weak = await data('get_weak_questions', {'contextRef': ref});
    final item = (weak['items'] as List).single as Map;
    final detail = await data('get_question_detail',
        {'contextRef': ref, 'questionRef': item['questionRef']});
    expect(detail['sourceKind'], 'legacy');
    final due = await data('get_due_review_summary', {
      'contextRef': ref,
      'from': '2026-01-01T00:00:00Z',
      'to': '2026-01-02T00:00:00Z',
      'timezone': 'Asia/Shanghai',
    });
    expect(due['scheduledCount'], 0);
  });

  test(
      'SDK discovery and original App-owned client enforce the eleven-tool profile',
      () async {
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final protocol =
        McpServer(const Implementation(name: 'shiroha', version: '0.1.0'));
    final server =
        VnextMcpServer(app, protocolServer: protocol, profileVersion: 3);
    final client = VnextAppOwnedClient(
        input: toClient.stream, output: toServer.sink, profileVersion: 3);
    try {
      await protocol.connect(
          IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
      await client.connect();
      final opened = await client.call('open_context', {});
      expect(opened['error'], isNull);
      final ref = (opened['data'] as Map)['contextRef'];
      final result =
          await client.call('get_study_overview', {'contextRef': ref});
      expect((result['data'] as Map)['questionCount'], 1);
      expect(result['source'], {'kind': 'windows', 'deviceRef': 'local'});
    } finally {
      await client.close();
      await server.close();
      await toServer.close();
      await toClient.close();
    }
  });

  test('aggregate context refuses generation while a bank permits it',
      () async {
    final ref = await context();
    expect(
        (await invoke(
            'propose_generated_questions', batch(ref, 'aggregate')))['error'],
        isNotNull);
    expect(await h.s.h.count('generated_question_proposals'), 0);
    final banks = await data('list_question_banks', {'contextRef': ref});
    final bank = (banks['items'] as List).single as Map;
    final single = await data('open_context', {'targetRef': bank['targetRef']});
    await data('propose_generated_questions',
        batch(single['contextRef'] as String, 'single-bank'));
    expect(
        (await data('get_question_proposal', {'submissionKey': 'single-bank'}))[
            'lifecycleStatus'],
        'pending_review');
  });

  test('consent revision invalidates old contexts and omits progress',
      () async {
    final old = await context();
    await grant(statistics: false);
    expect((await invoke('get_study_overview', {'contextRef': old}))['error'],
        isNotNull);
    final ref = await context();
    final banks = await data('list_question_banks', {'contextRef': ref});
    expect(banks['statisticsAuthorized'], false);
    expect(
        ((banks['items'] as List).single as Map).containsKey('questionCount'),
        false);
    expect((await invoke('get_study_overview', {'contextRef': ref}))['data'],
        isNull);
  });

  test('settled connection invalidates handles without revoking its grant',
      () async {
    final old = await context();
    final banks = await data('list_question_banks', {'contextRef': old});
    final target = ((banks['items'] as List).single as Map)['targetRef'];
    final weak = await data('get_weak_questions', {'contextRef': old});
    final question = ((weak['items'] as List).single as Map)['questionRef'];
    reads.invalidateConnectionContexts(h.s.session);
    expect((await invoke('get_study_overview', {'contextRef': old}))['data'],
        isNull);
    expect(
        (await invoke('open_context', {'targetRef': target}))['data'], isNull);
    expect(
        (await invoke('get_question_detail',
            {'contextRef': old, 'questionRef': question}))['data'],
        isNull);
    final fresh = await context();
    expect(fresh, isNot(old));
    expect(
        (await data(
            'get_study_overview', {'contextRef': fresh}))['questionCount'],
        1);
  });

  test('malformed selectors and windows fail without exposing business data',
      () async {
    final ref = await context();
    for (final arguments in [
      {'contextRef': ref, 'from': '2026-01-01', 'to': '2026-01-02'},
      {
        'contextRef': ref,
        'from': '2026-01-02T00:00:00Z',
        'to': '2026-01-01T00:00:00Z'
      },
      {
        'contextRef': ref,
        'from': '2026-01-01T00:00:00Z',
        'to': '2027-01-01T00:00:00Z'
      },
    ]) {
      expect(
          (await invoke('get_due_review_summary', arguments))['data'], isNull);
    }
    expect(
        (await invoke('open_context', {'scope': 'bank'}))['error'], isNotNull);
    expect(
        (await invoke('open_context', {'databasePath': 'forbidden'}))['error'],
        isNotNull);
  });

  test('new commands require explicitly selected internal version four',
      () async {
    final projection =
        OfflineIpcCommandProjection(host: host, authentication: authentication);
    final command = VnextMcpCommand.parseUnified('open_context', {});
    final envelope = command.request('version-test');
    expect((jsonDecode(envelope.payload) as Map)['schemaVersion'], 4);
    final refused = await projection.invokeV3(envelope, binding: app);
    expect(refused.failure, IpcCommandFailure.unsupportedVersion.name);
    await projection.shutdown();
  });
}
