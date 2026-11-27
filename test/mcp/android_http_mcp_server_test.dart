import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/external/android_association_store.dart';
import 'package:shiroha_quiz/data/external/android_http_token_codec.dart';
import 'package:shiroha_quiz/data/external/external_certificate_der.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_study_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/mcp/android_http_mcp_server.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:uuid/uuid.dart';

import '../application/external/local_host_test_support.dart';
import '../application/generated_question/generated_test_support.dart';
import '../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion, insertReviewState;

final class _Clock implements ExternalClock {
  _Clock(this.current);
  DateTime current;
  @override
  DateTime now() => current;
}

final class _MemoryBackend implements AndroidAssociationBackend {
  @override
  bool isCurrent = true;
  Uint8List? bytes;
  bool failCommit = false;
  bool occupied = false;

  @override
  Future<AndroidAssociationLease> begin() async {
    if (occupied) throw StateError('overlap');
    occupied = true;
    return _MemoryLease(this);
  }
}

final class _MemoryLease implements AndroidAssociationLease {
  _MemoryLease(this.owner);
  final _MemoryBackend owner;

  @override
  bool get isCurrent => owner.isCurrent && owner.occupied;

  @override
  Uint8List? get plaintext =>
      owner.bytes == null ? null : Uint8List.fromList(owner.bytes!);

  @override
  Future<void> commit(Uint8List plaintext) async {
    if (owner.failCommit) {
      credentialFail(ExternalCredentialFailure.commitUnknown);
    }
    owner.bytes = Uint8List.fromList(plaintext);
  }

  @override
  Future<void> close() async {
    owner.occupied = false;
  }
}

final class _NoopResources implements AndroidAccessResources {
  @override
  void withdraw() {}
  @override
  Future<void> close() async {}
}

final class _ImmediatePreparation implements AndroidAccessPreparation {
  _ImmediatePreparation() {
    _result.complete(_NoopResources());
    _settled.complete();
  }
  final _result = Completer<AndroidAccessResources>();
  final _settled = Completer<void>();
  @override
  Future<AndroidAccessResources> get result => _result.future;
  @override
  Future<void> get settled => _settled.future;
  @override
  void cancel() {}
}

final class _HttpReply {
  const _HttpReply({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final HttpHeaders headers;
  final String body;

  Map<String, dynamic> get jsonBody => jsonDecode(body) as Map<String, dynamic>;
}

final class _DirectLoopbackHttpOverrides extends HttpOverrides {}

final class _AndroidHttpHarness {
  static const installationId = '40000000-0000-4000-8000-000000000001';
  static const syntheticStem = 'Synthetic HTTP stem: What is 2 + 3?';
  static const syntheticAnswer = '5';

  final db = GeneratedHarness();
  final clock = _Clock(DateTime.utc(2026, 11, 26, 12, 0));
  final backend = _MemoryBackend();
  final events = <(String, Map<String, Object?>)>[];
  final httpClient = _DirectLoopbackHttpOverrides().createHttpClient(null);

  Duration elapsed = Duration.zero;
  int _obsSeq = 0;
  int _reqSeq = 0;

  late AndroidAssociationStore store;
  late ExternalAuthorizationManagement management;
  late AndroidHttpCredentialPort credPort;
  late ExternalTrustCore trust;
  late ExternalGeneratedStageService stages;
  late ExternalReadContextService reads;
  late LocalHostDispatchCore host;
  late AndroidForegroundAccess foreground;
  late AndroidHttpClientCredentials credentials;
  AndroidHttpMcpServer? server;

  Future<void> Function(String profileId, String tool)? beforeResponseRelease;

  Future<void> open() async {
    await db.open();
    await insertLegacyQuestion(
      db.db,
      id: 'http-q-1',
      createdAt: 1000,
      bankName: 'bank',
      content: syntheticStem,
      answer: syntheticAnswer,
    );
    await insertReviewState(
      db.db,
      questionId: 'http-q-1',
      lapses: 2,
      lastLapseTime: 5,
    );
    store = AndroidAssociationStore.forHttp(
      backend,
      nowUtcMs: () => clock.now().millisecondsSinceEpoch,
    );
    management = ExternalAuthorizationManagement(
      repository: SqliteExternalAuthorizationRepository(
        databaseHelper: db.helper,
      ),
      compositionIsCurrent: () => db.db.isOpen,
      mintProfileId: const Uuid().v4,
      clock: clock.now,
    );
    foreground = AndroidForegroundAccess(elapsed: () => elapsed);
    await _composeRuntime();
  }

  Future<void> _composeRuntime() async {
    final local = GeneratedLocalAuthorityRepository(databaseHelper: db.helper);
    final localFactory = GeneratedLocalAuthorityFactory(
      identity: local,
      proposals: local,
      compositionIsCurrent: () => db.db.isOpen,
    );
    final localSession = await localFactory.openSession();
    credPort = AndroidHttpCredentialPort();
    trust = ExternalTrustCore(
      credentials: credPort,
      clock: clock,
      mintProfileId: const Uuid().v4,
      maxProfiles: 64,
      maxEnableDuration: const Duration(hours: 8),
    );
    stages = ExternalGeneratedStageService(
      trust: trust,
      management: management,
      localOwner: localSession,
      persistence: GeneratedProposalRepository(databaseHelper: db.helper),
      admission: GeneratedQuestionAdmission(idFactory: const Uuid().v4),
    );
    reads = ExternalReadContextService(
      admission: stages.runtimeAdmission,
      targets: SqliteExternalTargetReadRepository(databaseHelper: db.helper),
      questions:
          SqliteExternalQuestionReadRepository(databaseHelper: db.helper),
      study: SqliteExternalStudyReadRepository(databaseHelper: db.helper),
    );
    host = LocalHostDispatchCore(
      gateway: ExternalCapabilityGateway(
        stages: stages,
        reads: reads,
        enableStudyQueries: true,
      ),
      readiness: OfflineReadiness(() async {}),
    );
    await host.startOffline();
    credentials = AndroidHttpClientCredentials(
      associations: store,
      management: management,
      trust: trust,
      credentialPort: credPort,
      admission: stages.runtimeAdmission,
      foreground: foreground,
      installationId: installationId,
      mintRequestId: () => 'http-req-${++_reqSeq}',
      onRevokeFailureWithdrawEnable: () async {
        await disableAccess();
      },
      onProfileRevoked: (profileId, session) async {
        await server?.revokeProfile(profileId, session: session);
      },
    );
  }

  void observe({
    bool visible = true,
    bool resumed = true,
    bool focused = true,
    bool interactive = true,
    bool unlocked = true,
    bool backgroundRead = true,
    String? network = 'wifi-1',
  }) {
    foreground.observe(AndroidForegroundObservation(
      sequence: ++_obsSeq,
      resumed: resumed,
      focused: focused,
      interactive: interactive,
      unlocked: unlocked,
      visible: visible,
      backgroundRead: backgroundRead,
      network: network,
    ));
  }

  VnextMcpPort _openPort(
    ExternalSession session,
    bool Function() isSessionCurrent,
  ) =>
      VnextMcpAppComposition(
        host: host,
        reads: reads,
        stages: stages,
        authentication: VnextMcpSessionAuthentication(() async {
          return isSessionCurrent() ? session : null;
        }),
        profileVersion: 3,
        source: const VnextDataSource('android', 'phone-1'),
        approvedTargets: const [],
      );

  Future<void> enableAccess({
    Duration? duration = const Duration(hours: 1),
    bool allowBackgroundRead = true,
    bool continueWhileLocked = false,
  }) async {
    observe(
      visible: true,
      resumed: true,
      focused: true,
      interactive: true,
      unlocked: true,
      backgroundRead: allowBackgroundRead,
      network: 'wifi-1',
    );
    await foreground.enable(
      (_) => _ImmediatePreparation(),
      duration: duration,
      allowBackgroundRead: allowBackgroundRead,
      continueWhileLocked: continueWhileLocked,
    );
    await credentials.enableActiveClients();
    await _startServer();
  }

  Future<void> _startServer() async {
    final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final created = AndroidHttpMcpServer(
      listener: listener,
      bindAddress: '127.0.0.1',
      isTls: false,
      openPort: _openPort,
      invalidateSessionContexts: reads.invalidateConnectionContexts,
      drainReads: () => reads.whenIdle,
      deviceRef: 'phone-1',
      authenticateBearer: credentials.authenticateRequest,
      foreground: foreground,
      runtimeAdmission: stages.runtimeAdmission,
      now: clock.now,
      beforeResponseRelease: (profileId, tool) async {
        if (beforeResponseRelease != null) {
          await beforeResponseRelease!(profileId, tool);
        }
      },
      onEvent: (event, fields) => events.add((event, fields)),
    );
    created.start();
    server = created;
  }

  Future<void> disableAccess() async {
    credentials.disableAllActiveClients();
    await foreground.disable();
    final active = server;
    server = null;
    if (active != null) {
      await active.close();
    }
  }

  Future<void> restartServerOnly() async {
    final active = server;
    server = null;
    if (active != null) {
      await active.close();
    }
    await _startServer();
  }

  Future<void> close() async {
    httpClient.close(force: true);
    await disableAccess();
    await host.shutdown();
    reads.close();
    await reads.whenIdle;
    await store.close();
    await db.close();
  }

  Future<_HttpReply> send({
    String method = 'POST',
    String path = '/mcp',
    String? token,
    String? sessionId,
    String? protocolVersion,
    String? origin,
    Object? jsonBody,
    List<int>? rawBody,
  }) async {
    final activePort = server!.port;
    final uri =
        Uri(scheme: 'http', host: '127.0.0.1', port: activePort, path: path);
    final req = await httpClient.openUrl(method, uri);
    req.headers
        .set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (sessionId != null) {
      req.headers.set('mcp-session-id', sessionId);
    }
    if (protocolVersion != null) {
      req.headers.set('mcp-protocol-version', protocolVersion);
    }
    if (sessionId == null &&
        protocolVersion == '2026-07-28' &&
        jsonBody is Map &&
        jsonBody['method'] is String) {
      req.headers.set('mcp-method', jsonBody['method'] as String);
      final params = jsonBody['params'];
      if (params is Map && params['name'] is String) {
        req.headers.set('mcp-name', params['name'] as String);
      }
    }
    if (origin != null) {
      req.headers.set('origin', origin);
    }
    if (rawBody != null) {
      req.headers.contentType = ContentType.json;
      req.add(rawBody);
    } else if (jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(jsonBody));
    }
    final res = await req.close();
    final body = await utf8.decoder.bind(res).join();
    return _HttpReply(
        statusCode: res.statusCode, headers: res.headers, body: body);
  }

  Future<_HttpReply> initialize(String token,
          {String protocolVersion = '2025-06-18'}) =>
      send(
        token: token,
        jsonBody: {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': protocolVersion,
            'capabilities': {},
            'clientInfo': {'name': 'test-client', 'version': '1.0'},
          },
        },
      );

  Future<String> initializeLegacy(String token,
      {String protocolVersion = '2025-06-18'}) async {
    final init = await initialize(token, protocolVersion: protocolVersion);
    expect(init.statusCode, HttpStatus.ok, reason: init.body);
    final sessionId = init.headers.value('mcp-session-id');
    expect(sessionId, isNotNull);
    final notif = await send(
      token: token,
      sessionId: sessionId,
      protocolVersion: protocolVersion,
      jsonBody: {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
    );
    expect(notif.statusCode, HttpStatus.accepted);
    return sessionId!;
  }

  Future<_HttpReply> callTool({
    required String token,
    required String name,
    Map<String, Object?> arguments = const {},
    String? sessionId,
    String protocolVersion = '2026-07-28',
    int id = 2,
  }) =>
      send(
        token: token,
        sessionId: sessionId,
        protocolVersion: protocolVersion,
        jsonBody: {
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/call',
          'params': {
            'name': name,
            'arguments': arguments,
            if (sessionId == null && protocolVersion == '2026-07-28')
              '_meta': {
                'io.modelcontextprotocol/protocolVersion': protocolVersion,
                'io.modelcontextprotocol/clientCapabilities':
                    const <String, Object?>{},
              },
          },
        },
      );

  Map<String, dynamic> structuredResult(_HttpReply reply) {
    expect(reply.statusCode, HttpStatus.ok, reason: reply.body);
    final root = reply.jsonBody;
    expect(root['error'], isNull, reason: reply.body);
    final result = root['result'] as Map<String, dynamic>;
    return result['structuredContent'] as Map<String, dynamic>;
  }
}

void main() {
  initializeGeneratedTests();

  late _AndroidHttpHarness h;

  setUp(() async {
    h = _AndroidHttpHarness();
    await h.open();
  });

  tearDown(() async {
    await h.close();
  });

  test(
      'Profile 3 exposes exact 9 READ tools, denies statistics/file by default, and enforces HTTP guards',
      () async {
    final client = await h.credentials.issueClient(displayName: 'Codex A');
    await h.enableAccess();

    // HTTP transport guards: 404 wrong path, 403 foreign Origin, 405 GET,
    // 401 missing/wrong Bearer, 413 > 64 KiB body.
    expect((await h.send(path: '/other', token: client.token)).statusCode, 404);
    expect(
      (await h.send(token: client.token, origin: 'https://evil.example'))
          .statusCode,
      403,
    );
    final getReply = await h.send(method: 'GET', token: client.token);
    expect(getReply.statusCode, 405);
    expect(getReply.headers.value(HttpHeaders.allowHeader), 'POST, DELETE');

    final noAuth = await h.send(jsonBody: {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': {},
    });
    expect(noAuth.statusCode, 401);
    expect(noAuth.headers.value('www-authenticate'), contains('Bearer'));

    final badAuth = await h.send(
      token: '${client.token.substring(0, 45)}AA',
      jsonBody: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        'params': {},
      },
    );
    expect(badAuth.statusCode, 401);

    final oversized = await h.send(
      token: client.token,
      rawBody:
          List<int>.filled(AndroidHttpMcpServer.defaultMaxBodyBytes + 1, 0x20),
    );
    expect(oversized.statusCode, 413);

    // Exact 9 Profile 3 READ tools (no propose_generated_questions / get_question_proposal).
    final listReply = await h.send(
      token: client.token,
      protocolVersion: '2026-07-28',
      jsonBody: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        'params': {
          '_meta': {
            'io.modelcontextprotocol/protocolVersion': '2026-07-28',
            'io.modelcontextprotocol/clientCapabilities':
                const <String, Object?>{},
          },
        },
      },
    );
    expect(listReply.statusCode, 200, reason: listReply.body);
    final tools = (listReply.jsonBody['result']['tools'] as List)
        .map((t) => (t as Map)['name'] as String)
        .toSet();
    expect(tools, {
      'open_context',
      'list_question_banks',
      'get_study_overview',
      'get_due_review_summary',
      'get_weak_questions',
      'search_questions',
      'get_question_detail',
      'retrieve_file_content',
      'get_file_passage',
    });
    expect(tools, isNot(contains('propose_generated_questions')));
    expect(tools, isNot(contains('get_question_proposal')));

    // Default READ + questionContent grant allows question READ and bank listing
    // without statistics, while denying studyStatistics and fileContent tools.
    final openAgg = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
    ));
    expect(openAgg['profileVersion'], 3);
    expect(openAgg['source'], {'kind': 'android', 'deviceRef': 'phone-1'});
    expect(openAgg['error'], isNull);
    final aggRef = openAgg['data']['contextRef'] as String;

    final banks = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'list_question_banks',
      arguments: {'contextRef': aggRef},
    ));
    expect(banks['error'], isNull);
    expect(banks['data']['statisticsAuthorized'], isFalse);
    final bankItem = (banks['data']['items'] as List).single as Map;
    expect(bankItem['bankName'], 'bank');
    expect(bankItem.containsKey('questionCount'), isFalse);

    final overview = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'get_study_overview',
      arguments: {'contextRef': aggRef},
    ));
    expect(overview['error'], isNotNull);
    expect(overview['data'], isNull);

    final dueSummary = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'get_due_review_summary',
      arguments: {
        'contextRef': aggRef,
        'from': '2026-11-26T00:00:00Z',
        'to': '2026-11-27T00:00:00Z',
      },
    ));
    expect(dueSummary['error'], isNotNull);

    final weak = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'get_weak_questions',
      arguments: {'contextRef': aggRef},
    ));
    expect(weak['error'], isNotNull);

    // File listing under default questionContent-only grant is also denied.
    final bankCtx = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
      arguments: {
        'targetRef': bankItem['targetRef'],
        'scope': 'bank',
      },
    ));
    expect(bankCtx['error'], isNull);
    final bankRef = bankCtx['data']['contextRef'] as String;

    final fileChoices = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
      arguments: {'contextRef': bankRef},
    ));
    expect(fileChoices['error'], isNotNull);

    // Stateless 2026-07-28 preserves contextRef across requests: search -> detail.
    final search = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'search_questions',
      arguments: {'contextRef': bankRef, 'query': 'Synthetic HTTP'},
    ));
    expect(search['error'], isNull);
    final hit = (search['data']['items'] as List).single as Map;
    final detail = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'get_question_detail',
      arguments: {
        'contextRef': bankRef,
        'questionRef': hit['questionRef'],
      },
    ));
    expect(detail['error'], isNull);
    expect(jsonEncode(detail['data']),
        contains(_AndroidHttpHarness.syntheticStem));
  });

  test(
      'legacy 2025-06-18 sessions enforce cross-token 403, caps 4/8, 15m idle TTL, DELETE, and restart 404',
      () async {
    final clientA = await h.credentials.issueClient(displayName: 'Codex A');
    final clientB = await h.credentials.issueClient(displayName: 'Codex B');
    final clientC = await h.credentials.issueClient(displayName: 'Codex C');
    await h.enableAccess();

    final sessionA1 = await h.initializeLegacy(clientA.token);
    expect(h.server!.activeLegacySessionCount, 1);

    // Cross-token hijacking of A's legacy session using B's valid token -> 403.
    final hijack = await h.callTool(
      token: clientB.token,
      sessionId: sessionA1,
      protocolVersion: '2025-06-18',
      name: 'open_context',
    );
    expect(hijack.statusCode, 403);

    // Valid call on A's legacy session succeeds.
    final ctxReply = h.structuredResult(await h.callTool(
      token: clientA.token,
      sessionId: sessionA1,
      protocolVersion: '2025-06-18',
      name: 'open_context',
    ));
    expect(ctxReply['error'], isNull);

    // Per-profile cap = 4; 5th initialize for A returns 429.
    final sessionA2 = await h.initializeLegacy(clientA.token);
    final sessionA3 = await h.initializeLegacy(clientA.token);
    final sessionA4 = await h.initializeLegacy(clientA.token);
    expect(h.server!.activeLegacySessionsFor(clientA.clientProfileId), 4);
    final fifthA = await h.send(
      token: clientA.token,
      jsonBody: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 'a5', 'version': '1'},
        },
      },
    );
    expect(fifthA.statusCode, 429);

    // Global cap = 8: B opens 4 sessions (total 8); C's 1st initialize gets 429.
    for (var i = 0; i < 4; i++) {
      await h.initializeLegacy(clientB.token, protocolVersion: '2025-11-25');
    }
    expect(h.server!.activeLegacySessionCount, 8);
    final ninthGlobal = await h.send(
      token: clientC.token,
      jsonBody: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-11-25',
          'capabilities': {},
          'clientInfo': {'name': 'c1', 'version': '1'},
        },
      },
    );
    expect(ninthGlobal.statusCode, 429);

    final refusedDelete = await h.send(
      method: 'DELETE',
      token: clientA.token,
      sessionId: sessionA2,
      protocolVersion: 'unsupported-version',
    );
    expect(refusedDelete.statusCode, HttpStatus.badRequest);
    expect(h.server!.activeLegacySessionCount, 8);
    final stillOpen = await h.callTool(
      token: clientA.token,
      sessionId: sessionA2,
      protocolVersion: '2025-06-18',
      name: 'open_context',
    );
    expect(h.structuredResult(stillOpen)['error'], isNull);

    // DELETE /mcp closes A2 cleanly; reusing A2 returns 404.
    final deleted = await h.send(
      method: 'DELETE',
      token: clientA.token,
      sessionId: sessionA2,
      protocolVersion: '2025-06-18',
    );
    expect(deleted.statusCode, anyOf(200, 204));
    expect(
      (await h.callTool(
        token: clientA.token,
        sessionId: sessionA2,
        protocolVersion: '2025-06-18',
        name: 'open_context',
      ))
          .statusCode,
      404,
    );

    // Idle expiry after 15 minutes removes idle sessions -> 404 on reuse.
    h.clock.current = h.clock.current.add(const Duration(minutes: 15));
    expect(
      (await h.callTool(
        token: clientA.token,
        sessionId: sessionA3,
        protocolVersion: '2025-06-18',
        name: 'open_context',
      ))
          .statusCode,
      404,
    );
    expect(h.server!.activeLegacySessionCount, 0);

    // Restart server: old session ID returns 404, fresh initialize with same token works.
    final freshA = await h.initializeLegacy(clientA.token);
    await h.restartServerOnly();
    expect(
      (await h.callTool(
        token: clientA.token,
        sessionId: freshA,
        protocolVersion: '2025-06-18',
        name: 'open_context',
      ))
          .statusCode,
      404,
    );
    final afterRestart = await h.initializeLegacy(clientA.token);
    expect(afterRestart, isNot(freshA));
    expect(sessionA4, isNotEmpty);
  });

  test(
      'multi-client alternating calls, single-client revoke isolation, revoke error fail-closed, and stop/IP survival',
      () async {
    final clientA = await h.credentials.issueClient(displayName: 'Client A');
    final clientB = await h.credentials.issueClient(displayName: 'Client B');
    final clientC = await h.credentials.issueClient(displayName: 'Client C');
    await h.enableAccess();

    final sessionA = await h.initializeLegacy(clientA.token);
    final sessionB = await h.initializeLegacy(clientB.token);

    // Alternating A -> B -> A.
    final ctxA = h.structuredResult(await h.callTool(
      token: clientA.token,
      sessionId: sessionA,
      protocolVersion: '2025-06-18',
      name: 'open_context',
    ))['data']['contextRef'] as String;
    final ctxB = h.structuredResult(await h.callTool(
      token: clientB.token,
      sessionId: sessionB,
      protocolVersion: '2025-06-18',
      name: 'open_context',
    ))['data']['contextRef'] as String;

    // Cross-profile contextRef borrowing fails closed at Application layer.
    final borrowed = h.structuredResult(await h.callTool(
      token: clientB.token,
      sessionId: sessionB,
      protocolVersion: '2025-06-18',
      name: 'list_question_banks',
      arguments: {'contextRef': ctxA},
    ));
    expect(borrowed['error'], isNotNull);

    // Revoke A only: A gets 401; B continues reading with its existing session & contextRef.
    await h.credentials.revokeClient(clientA.clientProfileId);
    expect(
      (await h.callTool(
        token: clientA.token,
        sessionId: sessionA,
        protocolVersion: '2025-06-18',
        name: 'list_question_banks',
        arguments: {'contextRef': ctxA},
      ))
          .statusCode,
      401,
    );
    final bBanks = h.structuredResult(await h.callTool(
      token: clientB.token,
      sessionId: sessionB,
      protocolVersion: '2025-06-18',
      name: 'list_question_banks',
      arguments: {'contextRef': ctxB},
    ));
    expect(bBanks['error'], isNull);

    // Stop / IP change -> re-enable: B's original token still works, old contextRef invalid.
    await h.disableAccess();
    await h.enableAccess();
    final staleCtx = h.structuredResult(await h.callTool(
      token: clientB.token,
      name: 'list_question_banks',
      arguments: {'contextRef': ctxB},
    ));
    expect(staleCtx['error'], isNotNull);
    final freshB = h.structuredResult(await h.callTool(
      token: clientB.token,
      name: 'open_context',
    ));
    expect(freshB['error'], isNull);

    // Durable revoke failure on B fails closed -> withdraws whole Enable -> C also denied.
    h.backend.failCommit = true;
    await expectLater(
      h.credentials.revokeClient(clientB.clientProfileId),
      throwsA(isA<ExternalCredentialException>()),
    );
    expect(h.server, isNull);
    expect(h.foreground.phase, AndroidAccessPhase.off);
    expect(
      await h.credentials
          .authenticateAuthorizationHeader(['Bearer ${clientC.token}']),
      isNull,
    );
  });

  test(
      'continueWhileLocked admits already-authenticated client and rejects brand-new client while locked',
      () async {
    final clientA = await h.credentials.issueClient(displayName: 'Client A');
    final clientB = await h.credentials.issueClient(displayName: 'Client B');
    await h.enableAccess(
      duration: AndroidAccessDuration.untilAppStops.limit,
      allowBackgroundRead: true,
      continueWhileLocked: true,
    );

    // Client A authenticates and opens context while device is unlocked.
    final openA = h.structuredResult(await h.callTool(
      token: clientA.token,
      name: 'open_context',
    ));
    expect(openA['error'], isNull);
    final ctxA = openA['data']['contextRef'] as String;

    // Device locks; foreground service remains active (`backgroundRead: true`).
    h.observe(
      visible: false,
      resumed: false,
      focused: false,
      interactive: false,
      unlocked: false,
      backgroundRead: true,
      network: 'wifi-1',
    );
    expect(h.foreground.allowsAuthenticatedUse, isTrue);
    expect(h.foreground.acceptsNew, isFalse);

    // Already-authenticated Client A continues reading while locked.
    final lockedReadA = h.structuredResult(await h.callTool(
      token: clientA.token,
      name: 'list_question_banks',
      arguments: {'contextRef': ctxA},
    ));
    expect(lockedReadA['error'], isNull);

    final advance = const Duration(hours: 9);
    h.elapsed += advance;
    h.clock.current = h.clock.current.add(advance);
    final beyondFiniteLimit = h.structuredResult(await h.callTool(
      token: clientA.token,
      name: 'open_context',
    ));
    expect(beyondFiniteLimit['error'], isNull);

    // Brand-new Client B (never authenticated while unlocked) is refused 403
    // without opening or caching a P0 ExternalSession in credentials.
    expect(h.credentials.activeSessionFor(clientB.clientProfileId), isNull);
    final lockedNewB = await h.callTool(
      token: clientB.token,
      name: 'open_context',
    );
    expect(lockedNewB.statusCode, 403);
    expect(h.credentials.activeSessionFor(clientB.clientProfileId), isNull);
    expect(
      await h.credentials
          .authenticateAuthorizationHeader(['Bearer ${clientB.token}']),
      isNull,
    );
    expect(h.credentials.activeSessionFor(clientB.clientProfileId), isNull);
    expect(h.credentials.activeSessionFor(clientA.clientProfileId), isNotNull);
    expect(
      h.events.any((e) =>
          e.$1 == 'LOCKED_NEW_CLIENT_REFUSED' &&
          e.$2['profileId'] == clientB.clientProfileId),
      isTrue,
    );

    h.observe(
      visible: false,
      resumed: false,
      focused: false,
      interactive: false,
      unlocked: false,
      backgroundRead: false,
    );
    expect(
      (await h.callTool(token: clientA.token, name: 'open_context')).statusCode,
      HttpStatus.unauthorized,
    );
  });

  test('concurrent legacy initialization obeys Profile and server limits',
      () async {
    final a = await h.credentials.issueClient(displayName: 'Profile A');
    final b = await h.credentials.issueClient(displayName: 'Profile B');
    final c = await h.credentials.issueClient(displayName: 'Profile C');
    await h.enableAccess();

    final first =
        await Future.wait(List.generate(6, (_) => h.initialize(a.token)));
    expect(first.where((reply) => reply.statusCode == 200), hasLength(4));
    expect(first.where((reply) => reply.statusCode == 429), hasLength(2));

    final other = await Future.wait([
      for (var i = 0; i < 3; i++) h.initialize(b.token),
      for (var i = 0; i < 3; i++) h.initialize(c.token),
    ]);
    expect(other.where((reply) => reply.statusCode == 200), hasLength(4));
    expect(other.where((reply) => reply.statusCode == 429), hasLength(2));
    expect(h.server!.activeLegacySessionCount, 8);
  });

  test(
      'a Grant expanded during an opted-in background window withholds the result',
      () async {
    final client = await h.credentials.issueClient(displayName: 'Scoped READ');
    final widerPolicy = ExternalGrantPolicy(
      permissions: const [CapabilityPermission.read],
      categories: const [
        ExternalContentCategory.questionContent,
        ExternalContentCategory.studyStatistics,
      ],
      scopes: const [],
      allContent: true,
    );
    final statsClient = await h.credentials.issueClient(
      displayName: 'Statistics READ',
      initialPolicy: widerPolicy,
    );
    await h.enableAccess(continueWhileLocked: true);
    final foregroundRefusal = await h.callTool(
      token: statsClient.token,
      name: 'open_context',
    );
    expect(foregroundRefusal.statusCode, HttpStatus.unauthorized);

    final opened = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
    ));
    final contextRef = opened['data']['contextRef'] as String;

    h.beforeResponseRelease = (_, tool) async {
      if (tool == 'list_question_banks') {
        await h.management
            .replaceGrant(client.profileReference, 1, widerPolicy);
        h.observe(
          visible: false,
          resumed: false,
          focused: false,
          interactive: false,
          unlocked: false,
        );
      }
    };
    final result = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'list_question_banks',
      arguments: {'contextRef': contextRef},
    ));
    expect(result['error'], 'unavailable');
    expect(result['data'], isNull);
    expect(h.events.any((event) => event.$1 == 'OUTPUT_WITHHELD'), isTrue);

    final lockedRefusal = await h.callTool(
      token: client.token,
      name: 'get_study_overview',
      arguments: {'contextRef': contextRef},
    );
    expect(lockedRefusal.statusCode, HttpStatus.unauthorized);

    await h.disableAccess();
    await h.enableAccess(
      allowBackgroundRead: false,
      duration: const Duration(minutes: 30),
    );
    final foregroundContext = h.structuredResult(await h.callTool(
      token: statsClient.token,
      name: 'open_context',
    ));
    final overview = h.structuredResult(await h.callTool(
      token: statsClient.token,
      name: 'get_study_overview',
      arguments: {'contextRef': foregroundContext['data']['contextRef']},
    ));
    expect(overview['error'], isNull);
  });

  test('OUTPUT_WITHHELD intercepts in-flight question detail on revoke/disable',
      () async {
    final client = await h.credentials.issueClient(displayName: 'Codex A');
    await h.enableAccess();

    final openAgg = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
    ));
    final banks = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'list_question_banks',
      arguments: {'contextRef': openAgg['data']['contextRef']},
    ));
    final targetRef = (banks['data']['items'] as List).single['targetRef'];
    final bankRef = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'open_context',
      arguments: {'targetRef': targetRef, 'scope': 'bank'},
    ))['data']['contextRef'] as String;
    final search = h.structuredResult(await h.callTool(
      token: client.token,
      name: 'search_questions',
      arguments: {'contextRef': bankRef, 'query': 'Synthetic HTTP'},
    ));
    final qRef = (search['data']['items'] as List).single['questionRef'];

    // Right after Application finishes reading the question detail and right
    // before HTTP response release, withdraw the Enable window.
    h.beforeResponseRelease = (profileId, tool) async {
      if (tool == 'get_question_detail') {
        h.credentials.disableAllActiveClients();
        await h.foreground.disable();
      }
    };

    final withheld = await h.callTool(
      token: client.token,
      name: 'get_question_detail',
      arguments: {'contextRef': bankRef, 'questionRef': qRef},
    );
    expect(withheld.statusCode, 200);
    expect(withheld.body, isNot(contains(_AndroidHttpHarness.syntheticStem)));
    expect(withheld.body, isNot(contains('What is 2 + 3')));
    final structured = h.structuredResult(withheld);
    expect(structured['data'], isNull);
    expect(structured['error'], 'unavailable');
    expect(
      h.events.any((e) =>
          e.$1 == 'OUTPUT_WITHHELD' &&
          e.$2['profileId'] == client.clientProfileId &&
          e.$2['tool'] == 'get_question_detail'),
      isTrue,
    );
  });

  // Deliberately public P-256 test keys (leaf scalar 1, CA scalar 2). The
  // synthetic certificate chain is scoped to loopback and only trusted here.
  const leafPkcs8Base64 =
      'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAGhRANCAARrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0'
      'oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1';
  const rootDerBase64 =
      'MIIBSjCB8aADAgECAgEBMAoGCCqGSM49BAMCMCMxITAfBgNVBAMMGFNoaXJvaGEgbG'
      '9vcGJhY2sgdGVzdCBDQTAeFw0yMDAxMDEwMDAwMDBaFw00MDAxMDEwMDAwMDBaMCMx'
      'ITAfBgNVBAMMGFNoaXJvaGEgbG9vcGJhY2sgdGVzdCBDQTBZMBMGByqGSM49AgEGCC'
      'qGSM49AwEHA0IABHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO'
      '0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9GjFjAUMBIGA1UdEwEB/wQIMAYBAf8CAQ'
      'AwCgYIKoZIzj0EAwIDSAAwRQIgZ1ZPFDYWyRl+Y195/N86hgRD9ISdgAoNMAFY+3ev'
      'RF8CIQCvbGTXo9Mp+OSlb0bT8ujxdtpMgZFgcsoOUWOHiFGsTw==';
  const leafDerBase64 =
      'MIIBbTCCAROgAwIBAgIBAjAKBggqhkjOPQQDAjAjMSEwHwYDVQQDDBhTaGlyb2hhIG'
      'xvb3BiYWNrIHRlc3QgQ0EwHhcNMjAwMTAxMDAwMDAwWhcNNDAwMTAxMDAwMDAwWjAl'
      'MSMwIQYDVQQDDBpTaGlyb2hhIGxvb3BiYWNrIHRlc3QgbGVhZjBZMBMGByqGSM49Ag'
      'EGCCqGSM49AwEHA0IABGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC'
      '4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfWjNjA0MAwGA1UdEwEB/wQCMAAwDw'
      'YDVR0RBAgwBocEfwAAATATBgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNI'
      'ADBFAiABNU8LryXKOgSXasi7RqXOmnGdbq8lQU29G8z2voM/HgIhAMDYpeP8FynMsg'
      'pzyVmArgaCsibwNODITWzKLIQmMJEv';

  test('bindSecure completes a trusted TLS handshake with Native-format PKCS#8',
      () async {
    final leaf = ExternalCertificateDer.encodePemCertificate(
        base64Decode(leafDerBase64));
    final root = ExternalCertificateDer.encodePemCertificate(
        base64Decode(rootDerBase64));
    final leafKey = base64Decode(leafPkcs8Base64);
    final listener = await AndroidHttpMcpServer.bindSecure(
      ipv4Address: '127.0.0.1',
      port: 0,
      certificateChainPemBytes: Uint8List.fromList(ascii.encode(leaf + root)),
      privateKeyPemOrPkcs8Bytes: leafKey,
      allowLoopbackForTest: true,
    );
    addTearDown(() => listener.close(force: true));
    leafKey.fillRange(0, leafKey.length, 0);
    listener.listen((request) async {
      request.response.write('synthetic TLS');
      await request.response.close();
    });

    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..setTrustedCertificatesBytes(ascii.encode(root));
    final client = _DirectLoopbackHttpOverrides().createHttpClient(context);
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri(
      scheme: 'https',
      host: '127.0.0.1',
      port: listener.port,
      path: '/',
    ));
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(await utf8.decoder.bind(response).join(), 'synthetic TLS');
  });

  test('bindSecure rejects public/wildcard IPv4 addresses before socket bind',
      () async {
    for (final forbidden in ['0.0.0.0', '8.8.8.8', '127.0.0.1']) {
      await expectLater(
        AndroidHttpMcpServer.bindSecure(
          ipv4Address: forbidden,
          port: 0,
          certificateChainPemBytes: Uint8List(0),
          privateKeyPemOrPkcs8Bytes: Uint8List(0),
        ),
        throwsFormatException,
        reason: forbidden,
      );
    }
  });
}
