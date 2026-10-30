import 'dart:async';
import 'dart:convert';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
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
import '../application/external/external_question_read_test_support.dart';
import '../application/external/local_host_test_support.dart';
import '../application/study_query/study_query_test_support.dart'
    show insertReviewState;
import 'fixtures/vnext_mcp_test_support.dart' show AppAuthentication, batch;
import 'fixtures/unified_sdk_transport.dart';

// Injects a second real SQLite handle; all business reads/writes remain the
// production repositories. No canned result or alternate identity is supplied.
final class _BoundDatabase implements DatabaseHelper {
  _BoundDatabase(this.db);
  final Database db;
  @override
  Future<Database> get database async => db;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  test('SDK statistics reservation remains held until response output finishes',
      () async {
    final sdk = UnifiedSdkHarness(app);
    await sdk.connect();
    final opened = await sdk.call('open_context', {});
    final ref = opened['data']['contextRef'];
    final writing = Completer<void>(), finish = Completer<void>();
    var first = true;
    sdk.beforeResponseWrite = () async {
      if (first) {
        first = false;
        writing.complete();
        await finish.future;
      }
    };
    try {
      final pending = sdk.call('get_study_overview', {'contextRef': ref});
      await writing.future;
      final blocked = await sdk.client.callTool(CallToolRequest(
          name: 'get_study_overview', arguments: {'contextRef': ref}));
      expect(blocked.structuredContent!['error'], 'resourceLimit');
      finish.complete();
      expect((await pending)['data']['questionCount'], 1);
      expect(
          (await sdk.call('get_study_overview', {'contextRef': ref}))['error'],
          isNull);
    } finally {
      if (!finish.isCompleted) finish.complete();
      await sdk.close();
    }
  });

  test('real SDK connection replacement invalidates its old references',
      () async {
    final first = UnifiedSdkHarness(app);
    await first.connect();
    final old = (await first.call('open_context', {}))['data']['contextRef'];
    await first.close();
    final replacement = UnifiedSdkHarness(app);
    await replacement.connect();
    try {
      expect(
          (await replacement
              .call('get_study_overview', {'contextRef': old}))['data'],
          isNull);
      final fresh =
          (await replacement.call('open_context', {}))['data']['contextRef'];
      expect(
          (await replacement
                  .call('get_study_overview', {'contextRef': fresh}))['data']
              ['questionCount'],
          1);
    } finally {
      await replacement.close();
    }
  });

  test(
      'independent databases and runtimes reject each other despite matching profile IDs',
      () async {
    final old = await context();
    final db = await h.s.h.helper.openPathForTesting(
        h.s.h.temp.uri.resolve('other-target.db').toFilePath());
    final helper = _BoundDatabase(db);
    await db
        .insert('bank_folders', {'bank_name': 'bank', 'folder_name': 'folder'});
    final authorization =
        SqliteExternalAuthorizationRepository(databaseHelper: helper);
    final management = ExternalAuthorizationManagement(
        repository: authorization,
        compositionIsCurrent: () => db.isOpen,
        mintProfileId: () => h.s.profile.profileId,
        clock: h.s.clock.now);
    final profile = await management.createProfile(
        displayName: 'Other synthetic target',
        adapter: 'android',
        protocol: 'synthetic');
    await management.replaceGrant(
        profile,
        0,
        h.s.policy(
            permissions: [CapabilityPermission.read],
            categories: [ExternalContentCategory.studyStatistics]));
    final local = GeneratedLocalAuthorityRepository(databaseHelper: helper);
    final factory = GeneratedLocalAuthorityFactory(
        identity: local,
        proposals: local,
        compositionIsCurrent: () => db.isOpen);
    final owner = await factory.openSession();
    final credentials = StageCredentials();
    final trust = ExternalTrustCore(
        credentials: credentials,
        clock: h.s.clock,
        mintProfileId: () => profile.profileId);
    final stages = ExternalGeneratedStageService(
        trust: trust,
        management: management,
        localOwner: owner,
        persistence: GeneratedProposalRepository(databaseHelper: helper),
        admission: GeneratedQuestionAdmission(idFactory: const Uuid().v4));
    final principal = trust.createProfile();
    await stages.bindIdentity(profile, principal);
    trust.requestPairing(principal,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    trust.approvePairing(principal);
    trust.completePairing(principal, credentials.proof);
    trust.enable(principal, const Duration(minutes: 30));
    final session =
        trust.openSession(trust.authenticate(credentials.authentication));
    final otherReads = ExternalReadContextService(
        admission: stages.runtimeAdmission,
        targets: SqliteExternalTargetReadRepository(databaseHelper: helper),
        questions: SqliteExternalQuestionReadRepository(databaseHelper: helper),
        study: SqliteExternalStudyReadRepository(databaseHelper: helper));
    final otherHost = LocalHostDispatchCore(
        gateway: ExternalCapabilityGateway(
            stages: stages, reads: otherReads, enableStudyQueries: true),
        readiness: OfflineReadiness(() async {}));
    await otherHost.startOffline();
    final other = VnextMcpAppComposition(
        host: otherHost,
        reads: otherReads,
        stages: stages,
        authentication: VnextMcpSessionAuthentication(() async => session),
        approvedTargets: const [],
        profileVersion: 3,
        source: const VnextDataSource('android', 'synthetic-target'));
    Future<Map<String, Object?>> call(String name, Map<String, dynamic> args) =>
        other.call(name, args,
            cancelled: const Stream.empty(), available: () => true);
    try {
      expect((await call('get_study_overview', {'contextRef': old}))['data'],
          isNull);
      final fresh = (await call('open_context', {}))['data'] as Map;
      final result =
          await call('get_study_overview', {'contextRef': fresh['contextRef']});
      expect((result['data'] as Map)['questionCount'], 0);
      expect(result['source'],
          {'kind': 'android', 'deviceRef': 'synthetic-target'});
      expect(
          (await invoke('get_study_overview',
              {'contextRef': fresh['contextRef']}))['data'],
          isNull);
      expect(
          (await data(
              'get_study_overview', {'contextRef': old}))['questionCount'],
          1);
    } finally {
      await other.close();
      otherReads.close();
      stages.close();
      await stages.whenIdle;
      owner.close();
      factory.invalidate();
      await db.close();
    }
  });

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

  test(
      'injecting statistics does not select Profile 3 or admit unknown versions',
      () async {
    final legacy = VnextMcpAppComposition(
        host: host,
        reads: reads,
        stages: h.s.service,
        authentication: authentication,
        approvedTargets: const []);
    expect(legacy.profileVersion, 2);
    final denied = await legacy.call('open_context', {},
        cancelled: const Stream.empty(), available: () => true);
    expect(denied['profileVersion'], 2);
    expect(denied['data'], isNull);
    expect(
        () => VnextMcpAppComposition(
            host: host,
            reads: reads,
            stages: h.s.service,
            authentication: authentication,
            approvedTargets: const [],
            profileVersion: 4),
        throwsArgumentError);
    await legacy.close();
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

  test('SDK initialization, discovery and calls enter the production profile',
      () async {
    final revision =
        (await h.s.management.read(h.s.profile)).profile.grantRevision;
    await h.s.management.replaceGrant(
        h.s.profile,
        revision,
        ExternalGrantPolicy(
            permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            scopes: [
              h.s.bank
            ],
            categories: ExternalContentCategory.values,
            generationMode: ExternalGenerationMode.review));
    app = VnextMcpAppComposition(
        host: host,
        reads: reads,
        stages: h.s.service,
        authentication: authentication,
        approvedTargets: const [],
        profileVersion: 3,
        source: const VnextDataSource('windows', 'local'),
        stageApproval: FirstPartyStageApproval(
            host: host,
            stages: h.s.service,
            localOwner: h.s.localSession,
            compositionIsCurrent: () => true));
    final sdk = UnifiedSdkHarness(app);
    final call = sdk.call;
    try {
      await sdk.connect();
      final tools = await sdk.client.listTools();
      expect(tools.tools.map((t) => t.name).toSet(),
          VnextMcpServer.schemasFor(3).keys.toSet());
      final opened = await call('open_context', {});
      expect(opened['error'], isNull);
      final ref = (opened['data'] as Map)['contextRef'];
      final result = await call('get_study_overview', {'contextRef': ref});
      expect((result['data'] as Map)['questionCount'], 1);
      expect(result['source'], {'kind': 'windows', 'deviceRef': 'local'});
      final banks = await call('list_question_banks', {'contextRef': ref});
      final target =
          ((banks['data'] as Map)['items'] as List).single['targetRef'];
      final selected = await call('open_context', {'targetRef': target});
      final single = selected['data']['contextRef'] as String;
      expect(
          (await call('get_weak_questions', {'contextRef': ref}))['data']
              ['items'],
          hasLength(1));
      expect(
          (await call('get_due_review_summary', {
            'contextRef': ref,
            'from': '2026-01-01T00:00:00Z',
            'to': '2026-01-02T00:00:00Z'
          }))['error'],
          isNull);
      final search = await call(
          'search_questions', {'contextRef': single, 'query': 'needle'});
      final question = (search['data']['items'] as List).single['questionRef'];
      expect(
          (await call('get_question_detail',
              {'contextRef': single, 'questionRef': question}))['error'],
          isNull);
      expect(
          (await call('retrieve_file_content',
              {'contextRef': single, 'query': 'needle'}))['error'],
          isNotNull);
      expect(
          (await call('get_file_passage',
              {'contextRef': single, 'passageRef': question}))['error'],
          isNotNull);
      expect(
          (await call('propose_generated_questions',
              batch(single, 'sdk-batch')))['data']['publication'],
          'STAGED');
      final lifecycle =
          await call('get_question_proposal', {'submissionKey': 'sdk-batch'});
      expect(lifecycle['data']['lifecycleStatus'], 'pending_review');
      expect(
          (await call('propose_generated_questions',
              batch(single, 'sdk-batch')))['error'],
          isNull);
      expect(
          (await call('propose_generated_questions',
              batch(single, 'sdk-batch', suffix: ' changed')))['error'],
          isNotNull);
      expect(await h.s.h.count('generated_question_proposals'), 1);
      // SDK argument validation and the authenticated decoder both stay strict.
      final malformed = await call('get_due_review_summary', {
        'contextRef': ref,
        'from': '2026-02-30T00:00:00Z',
        'to': '2026-03-03T00:00:00Z'
      });
      expect(malformed['data'], isNull);
    } finally {
      await sdk.close();
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

  test('SDK saved review/direct use the original approval and atomic writer',
      () async {
    Future<void> policy(ExternalGenerationMode mode) async {
      final revision =
          (await h.s.management.read(h.s.profile)).profile.grantRevision;
      await h.s.management.replaceGrant(
          h.s.profile,
          revision,
          ExternalGrantPolicy(
              permissions: [
                CapabilityPermission.read,
                CapabilityPermission.stage
              ],
              scopes: [h.s.bank],
              generationMode: mode,
              categories: [
                ExternalContentCategory.questionContent,
                ExternalContentCategory.proposalMetadata,
                ExternalContentCategory.studyStatistics
              ]));
    }

    await policy(ExternalGenerationMode.review);
    app = VnextMcpAppComposition(
        host: host,
        reads: reads,
        stages: h.s.service,
        authentication: authentication,
        approvedTargets: const [],
        profileVersion: 3,
        source: const VnextDataSource('windows', 'local'),
        stageApproval: FirstPartyStageApproval(
            host: host,
            stages: h.s.service,
            localOwner: h.s.localSession,
            compositionIsCurrent: () => true));
    final sdk = UnifiedSdkHarness(app);
    Future<Map> call(String name, Map<String, dynamic> args) async {
      final result = await sdk.call(name, args);
      expect(result['error'], isNull, reason: '$name: $result');
      return result['data'] as Map;
    }

    Future<String> bankContext() async {
      final root = await call('open_context', {});
      final banks =
          await call('list_question_banks', {'contextRef': root['contextRef']});
      return (await call('open_context', {
        'targetRef': (banks['items'] as List).single['targetRef']
      }))['contextRef'] as String;
    }

    try {
      await sdk.connect();
      final first = await bankContext();
      await call('propose_generated_questions', batch(first, 'policy-review'));
      expect(
          (await call('get_question_proposal',
              {'submissionKey': 'policy-review'}))['lifecycleStatus'],
          'pending_review');
      await policy(ExternalGenerationMode.direct);
      final next = await bankContext();
      await call('propose_generated_questions', batch(next, 'policy-review'));
      expect(
          (await call('get_question_proposal',
              {'submissionKey': 'policy-review'}))['lifecycleStatus'],
          'pending_review');
      await call('propose_generated_questions',
          batch(next, 'policy-direct', suffix: ' direct'));
      final saved = await call(
          'get_question_proposal', {'submissionKey': 'policy-direct'});
      expect(saved['lifecycleStatus'], 'committed');
      expect(saved['committedCount'], 3);
      await call('propose_generated_questions',
          batch(next, 'policy-direct', suffix: ' direct'));
      expect(await h.s.h.count('questions'), 4);
      expect(await h.s.h.count('generated_question_proposals'), 2);
    } finally {
      await sdk.close();
    }
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
    await app.settleConnection(h.s.session);
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
        'from': '2026-02-30T00:00:00Z',
        'to': '2026-03-03T00:00:00Z'
      },
      {
        'contextRef': ref,
        'from': '2026-01-01T24:00:00Z',
        'to': '2026-01-03T00:00:00Z'
      },
      {
        'contextRef': ref,
        'from': '2026-01-01T00:00:00+24:00',
        'to': '2026-01-03T00:00:00Z'
      },
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
