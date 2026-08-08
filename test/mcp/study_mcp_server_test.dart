// mcp.study.v0 stdio server lifecycle acceptance.
//
// Drives the real mcp_dart protocol over an in-memory transport pair: the
// initialize handshake, the exactly-six READ_ONLY registry, success and error
// envelope round-trips, and the close lifecycle. The stdio binding itself is
// exercised only through [StudyMcpServer.serveStdio] wiring and the
// composition root, since tests must not bind the process stdin/stdout.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/application/study_query/study_query_clock.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';
import 'package:shiroha_quiz/mcp/study_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/study_mcp_server.dart';

import '../application/study_query/study_query_test_support.dart';

final class _FixedClock implements StudyClock {
  const _FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}

final DateTime fixedNow = DateTime.utc(2026, 8, 8, 17);

StudyMcpServer _server() {
  return StudyMcpServer(
    adapter: StudyMcpAdapter(
      service: StudyQueryService(
        questionQuery: QuestionRepository(),
        metricsQuery: ReviewRepository(),
        clock: _FixedClock(fixedNow),
      ),
      clock: _FixedClock(fixedNow),
    ),
  );
}

Future<void> _seedMinimalDataset() async {
  final db = await openTestDatabase();
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': bankMath,
    'folder_name': 'Algebra',
  });
  await insertTypedQuestion(
    db,
    draft: makeDraft(
      'draft_alpha',
      stem: textContent('Synthetic stem alpha'),
      options: <QuestionOption>[optionA()],
      answer: ChoiceAnswer(optionIds: <String>['A']),
      explanation: textContent('Synthetic explanation alpha'),
    ),
    storageId: idTyped1,
    createdAt: 100,
    bankName: bankMath,
  );
  await insertReviewState(
    db,
    questionId: idTyped1,
    state: 3,
    nextReviewTime: unixSeconds('2026-08-08T15:59:59Z'),
  );
}

/// Minimal in-memory transport pair (one endpoint per side), mirroring the
/// mcp_dart package's own linked-transport test pattern.
final class _LinkedTransport implements Transport {
  _LinkedTransport? peer;

  void Function()? _onclose;
  void Function(Error error)? _onerror;
  void Function(JsonRpcMessage message)? _onmessage;

  @override
  void Function()? get onclose => _onclose;

  @override
  set onclose(void Function()? value) {
    _onclose = value;
  }

  @override
  void Function(Error error)? get onerror => _onerror;

  @override
  set onerror(void Function(Error error)? value) {
    _onerror = value;
  }

  @override
  void Function(JsonRpcMessage message)? get onmessage => _onmessage;

  @override
  set onmessage(void Function(JsonRpcMessage message)? value) {
    _onmessage = value;
  }

  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(
    JsonRpcMessage message, {
    int? relatedRequestId,
  }) async {
    scheduleMicrotask(() => peer?.onmessage?.call(message));
  }

  @override
  Future<void> close() async {
    onclose?.call();
  }
}

/// Records that [close] was invoked on the transport. The protocol replaces
/// the transport's `onclose` callback during [Protocol.connect], so the close
/// lifecycle is observed through the transport's own [close] method.
final class _RecordingTransport extends _LinkedTransport {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    await _seedMinimalDataset();
  });

  tearDown(resetTestDatabase);

  group('registry and lifecycle', () {
    test('the server exposes exactly the six frozen tool names', () {
      final server = _server();
      expect(
        server.toolNames,
        StudyMcpAdapter.toolNames,
      );
      expect(server.toolNames, hasLength(6));
      expect(server.isConnected, isFalse);
    });

    test('initialize handshake and six READ_ONLY tools/list', () async {
      final serverTransport = _LinkedTransport();
      final clientTransport = _LinkedTransport()..peer = serverTransport;
      serverTransport.peer = clientTransport;
      final server = _server();
      final client = McpClient(
        const Implementation(name: 'mcp_server_test', version: '0.1.0'),
      );

      await server.connect(serverTransport);
      expect(server.isConnected, isTrue);
      await client.connect(clientTransport);

      final tools = (await client.listTools()).tools;
      expect(
        tools.map((tool) => tool.name).toList(),
        unorderedEquals(StudyMcpAdapter.toolNames),
      );
      for (final tool in tools) {
        expect(tool.annotations, isNotNull);
        expect(tool.annotations!.readOnlyHint, isTrue);
        expect(tool.annotations!.destructiveHint, isFalse);
        expect(tool.annotations!.idempotentHint, isTrue);
      }

      await client.close();
      await server.close();
    });

    test('tools/call round-trips a frozen success envelope', () async {
      final serverTransport = _LinkedTransport();
      final clientTransport = _LinkedTransport()..peer = serverTransport;
      serverTransport.peer = clientTransport;
      final server = _server();
      final client = McpClient(
        const Implementation(name: 'mcp_server_test', version: '0.1.0'),
      );

      await server.connect(serverTransport);
      await client.connect(clientTransport);

      final result = await client.callTool(
        const CallToolRequest(name: 'list_question_banks'),
      );
      expect(result.isError, isFalse);
      expect(result.hasStructuredContent, isTrue);
      final envelope = result.structuredContent!;
      expect(envelope['schema_version'], 'mcp.study.v0');
      expect(
        envelope['generated_at'],
        '2026-08-08T17:00:00Z',
      );
      final items = envelope['items'] as List<Object?>;
      expect(items, hasLength(1));
      expect(
        (items.single as Map<String, Object?>)['bank_name'],
        bankMath,
      );
      expect(envelope['next_cursor'], isNull);

      final detail = await client.callTool(
        const CallToolRequest(
          name: 'get_question_detail',
          arguments: <String, dynamic>{'question_id': idTyped1},
        ),
      );
      expect(detail.isError, isFalse);
      final data = detail.structuredContent!['data'] as Map<String, Object?>;
      expect(data['question_id'], idTyped1);
      expect(data['source_kind'], 'typed');
      expect(
        (data['due_state'] as Map<String, Object?>)['due'],
        isTrue,
      );

      await client.close();
      await server.close();
    });

    test('tools/call round-trips the exact error envelope', () async {
      final serverTransport = _LinkedTransport();
      final clientTransport = _LinkedTransport()..peer = serverTransport;
      serverTransport.peer = clientTransport;
      final server = _server();
      final client = McpClient(
        const Implementation(name: 'mcp_server_test', version: '0.1.0'),
      );

      await server.connect(serverTransport);
      await client.connect(clientTransport);

      final result = await client.callTool(
        const CallToolRequest(name: 'get_question_detail'),
      );
      expect(result.isError, isTrue);
      final envelope = result.structuredContent!;
      expect(envelope.keys.toSet(), <String>{'schema_version', 'error'});
      final error = envelope['error'] as Map<String, Object?>;
      expect(error['code'], 'invalid_request');
      expect(error['message'], 'The request is invalid.');
      expect(error['retryable'], isFalse);

      await client.close();
      await server.close();
    });

    test('close tears down the transport and clears the connection state',
        () async {
      final serverTransport = _RecordingTransport();
      final clientTransport = _LinkedTransport()..peer = serverTransport;
      serverTransport.peer = clientTransport;
      final server = _server();

      await server.connect(serverTransport);
      expect(server.isConnected, isTrue);
      await server.close();
      expect(server.isConnected, isFalse);
      expect(serverTransport.closed, isTrue);
    });

    test('the composition root assembles a runnable stdio server', () {
      final server = buildStudyMcpServer();
      expect(server.toolNames, StudyMcpAdapter.toolNames);
      expect(server.isConnected, isFalse);
    });
  });
}
