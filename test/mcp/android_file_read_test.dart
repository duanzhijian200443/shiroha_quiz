import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/mcp/android_mcp_transport.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import '../application/external/external_file_read_test_support.dart';
import '../application/external/local_host_test_support.dart'
    show OfflineReadiness;

/// Real F1/SQLite/FTS/P10 and pinned MCP SDK, synthetic native I/O/credentials.
/// This is adapter regression evidence, never physical-phone/Codex acceptance.
final class _Files {
  final files = FileReadHarness();
  late LocalHostDispatchCore host;
  late FirstPartyStageApproval approval;
  late AndroidMcpPort port;
  late AndroidMcpTransport transport;
  late VnextMcpServer server;
  late Future<bool> settled;
  final input = StreamController<(int, Map<String, dynamic>)>();
  final responses = <Object, Completer<Map<String, dynamic>>>{};
  final writes = <Object?>[];
  Future<void> Function(Object?)? beforeWrite;
  final closeEntered = Completer<void>();
  Completer<void>? closeGate;
  int sequence = 0;
  bool live = true;

  Future<void> policy({required bool fileContent}) async {
    final record = await files.s.management.read(files.s.profile);
    await files.s.management.replaceGrant(
        files.s.profile,
        record.profile.grantRevision,
        ExternalGrantPolicy(
            permissions: const [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            scopes: const [],
            allContent: true,
            categories: [
              ExternalContentCategory.questionContent,
              ExternalContentCategory.proposalMetadata,
              if (fileContent) ExternalContentCategory.fileContent
            ],
            generationMode: ExternalGenerationMode.review));
  }

  Future<void> open() async {
    await files.open(learningSpace: false);
    await policy(fileContent: false);
    host = LocalHostDispatchCore(
        gateway: ExternalCapabilityGateway(
            stages: files.s.service, reads: files.read),
        readiness: OfflineReadiness(() async {}));
    await host.startOffline();
    approval = FirstPartyStageApproval(
        host: host,
        stages: files.s.service,
        localOwner: files.s.localSession,
        compositionIsCurrent: () => true);
    port = AndroidMcpPort(
        VnextMcpAppComposition(
            host: host,
            reads: files.read,
            stages: files.s.service,
            stageApproval: approval,
            approvedTargets: const [],
            authentication: VnextMcpSessionAuthentication(
                () async => live ? files.s.session : null)),
        () => live);
    final reader = StreamIterator(input.stream);
    transport = AndroidMcpTransport(
        port: port,
        read: () async {
          if (!await reader.moveNext()) throw StateError('synthetic_eof');
          return reader.current;
        },
        newNonce: () => 'nonce',
        validNonce: (n) => n == 'nonce',
        write: (kind, message) async {
          if (kind != 2) return;
          await beforeWrite?.call(message['id']);
          writes.add(message['id']);
          responses.remove(message['id'])?.complete(message);
        },
        closeChannel: () async {
          unawaited(input.close());
          if (!closeEntered.isCompleted) closeEntered.complete();
          await closeGate?.future;
        },
        invalidate: () => live = false,
        connectionId: 'synthetic',
        current: () => live);
    server = androidDeviceServer(port);
    settled = server
        .serveTransport(transport)
        .then((_) => true, onError: (Object _, StackTrace __) => false);
    await request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'android-file-regression', 'version': '1'}
    });
    input.add((2, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
  }

  Future<Map<String, dynamic>> request(
      String method, Map<String, dynamic> params,
      {Object? id}) {
    id ??= ++sequence;
    final response = Completer<Map<String, dynamic>>();
    responses[id] = response;
    input.add(
        (2, {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return response.future;
  }

  Future<Map<String, dynamic>> call(String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final response =
        await request('tools/call', {'name': tool, 'arguments': arguments});
    expect(response['error'], isNull);
    await port.whenSettled;
    return (response['result'] as Map)['structuredContent']
        as Map<String, dynamic>;
  }

  Future<Map> data(String tool, [Map<String, dynamic> args = const {}]) async {
    final result = await call(tool, args);
    expect(result['error'], isNull);
    return result['data'] as Map;
  }

  Future<String> parent() async {
    final targets = await data('open_generation_context');
    final opened = await data('open_generation_context',
        {'targetRef': ((targets['items'] as List).single as Map)['targetRef']});
    return opened['contextRef'] as String;
  }

  Future<String> selected() async {
    await policy(fileContent: true);
    final context = await parent();
    final page = await data('open_generation_context', {'contextRef': context});
    final opened = await data('open_generation_context', {
      'contextRef': context,
      'fileRefs': [(page['items'] as List).first['fileRef']]
    });
    return opened['contextRef'] as String;
  }

  void cancel(Object id) => input.add((
        2,
        {
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': id}
        }
      ));

  Future<void> close() async {
    try {
      await server.close();
    } catch (_) {/* Assert clean/failure in each case. */}
    await settled;
    await approval.close();
    await host.shutdown();
    await files.close();
  }
}

void main() {
  initializeGeneratedTests();
  late _Files f;
  setUp(() async {
    f = _Files();
    await f.open();
  });
  tearDown(() => f.close());

  test(
      'phone file modes preserve permission, pagination, snapshots and passage coverage',
      () async {
    expect(VnextMcpServer.inputSchemas.length, 7);
    final old = await f.parent();
    final denied = await f.call('open_generation_context', {'contextRef': old});
    expect(denied['data'], isNull);
    expect(denied['error'], isNotNull);
    await f.files.seed('file-0', parsed: false);
    final parses = f.files.generation.calls;
    await f.policy(fileContent: true);
    expect(
        (await f.call('open_generation_context', {'contextRef': old}))['error'],
        isNotNull);
    final parent = await f.parent();
    final empty = await f
        .data('open_generation_context', {'contextRef': parent, 'pageSize': 1});
    expect(empty['items'], isEmpty);
    expect(empty['hasMore'], isTrue);
    expect(empty['unsupportedExcluded'], isTrue);
    final page = await f.data('open_generation_context',
        {'contextRef': parent, 'pageSize': 1, 'cursor': empty['nextCursor']});
    final choice = (page['items'] as List).single as Map;
    expect(choice.keys.toSet(), {'fileRef', 'selectionOrdinal'});
    expect(choice['selectionOrdinal'], 0);
    final second = await f.parent();
    expect(
        (await f.call('open_generation_context', {
          'contextRef': second,
          'fileRefs': [choice['fileRef']]
        }))['error'],
        isNotNull);
    final rawId = await f.request('tools/call', {
      'name': 'open_generation_context',
      'arguments': {
        'contextRef': parent,
        'fileRefs': ['file-a']
      }
    });
    expect((rawId['error'] as Map)['code'], -32602);
    final opened = await f.data('open_generation_context', {
      'contextRef': parent,
      'fileRefs': [choice['fileRef']]
    });
    final context = opened['contextRef'];
    expect(context, isNot(parent));
    expect(
        (await f.call('retrieve_file_content',
            {'contextRef': parent, 'query': 'needle'}))['error'],
        isNotNull);
    final search = await f.data(
        'retrieve_file_content', {'contextRef': context, 'query': 'needle'});
    expect(search['startsAtDocumentBeginning'], isFalse);
    final hit = (search['items'] as List).single as Map;
    expect(hit['content'], 'needle file-a');
    expect(hit.keys.toSet(), {
      'passageRef',
      'content',
      'contentKind',
      'locator',
      'chunkOrdinal',
      'partOrdinal',
      'windowOrdinal',
      'pageNumber'
    });
    final first = await f.data('get_file_passage',
        {'contextRef': context, 'passageRef': hit['passageRef']});
    expect(first['startsAtDocumentBeginning'], isTrue);
    expect(first['hasMore'], isTrue);
    expect(first['unsupportedExcluded'], isTrue);
    expect((first['items'] as List).length, 8);
    final next = await f.data('get_file_passage', {
      'contextRef': context,
      'passageRef': hit['passageRef'],
      'cursor': first['nextCursor']
    });
    expect(next['startsAtDocumentBeginning'], isFalse);
    expect(next['hasMore'], isFalse);
    expect((next['items'] as List).first['chunkOrdinal'], 8);
    expect(f.files.generation.calls, parses);
    expect(await f.files.s.h.count('retrieval_index_builds'), 1);
    expect(await f.files.s.h.count('questions'), 0);
    final key = 'android-file-synthetic';
    final staged = await f.data('propose_generated_questions', {
      'contextRef': parent,
      'submission': jsonDecode(submission(
          key: key, items: [candidate(stem: 'Synthetic file exercise')]))
    });
    expect(staged['publication'], 'STAGED');
    final status =
        await f.data('get_question_proposal', {'submissionKey': key});
    expect(status['lifecycleStatus'], 'pending_review');
    expect(await f.files.s.h.count('generated_question_proposals'), 1);
  });

  for (final revoke in [false, true]) {
    test(
        'Android final file release rejects ${revoke ? "revocation" : "changed F1 generation"} after FTS',
        () async {
      final context = await f.selected();
      final parses = f.files.generation.calls;
      f.files.index.afterSearch = () async {
        if (revoke) {
          await f.policy(fileContent: false);
        } else {
          await f.files.lifecycle.reparseArtifact(
              fileId: 'file-a',
              options: FileReadHarness.options,
              expectedRevision: 1);
        }
      };
      final result = await f.call(
          'retrieve_file_content', {'contextRef': context, 'query': 'needle'});
      expect(result['data'], isNull);
      expect(result['error'], isNotNull);
      expect(f.files.generation.calls, parses + (revoke ? 0 : 1));
    });
  }

  for (final explicitCancel in [false, true]) {
    test(
        'file index ${explicitCancel ? "SDK cancellation" : "disconnect"} joins original build and close I/O',
        () async {
      final context = await f.selected();
      final entered = Completer<void>(), release = Completer<void>();
      f.closeGate = Completer<void>();
      f.files.index.beforeBuild = () async {
        entered.complete();
        await release.future;
      };
      unawaited(f.request(
          'tools/call',
          {
            'name': 'retrieve_file_content',
            'arguments': {'contextRef': context, 'query': 'needle'}
          },
          id: 'read'));
      await entered.future;
      if (explicitCancel) {
        f.cancel('read');
      } else {
        unawaited(f.transport.close());
      }
      await f.closeEntered.future;
      var finished = false;
      final settling = f.port.whenSettled.then((_) => finished = true);
      f.closeGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse);
      expect(f.writes, isNot(contains('read')));
      release.complete();
      await settling;
      expect(await f.settled, explicitCancel);
      expect(f.writes, isNot(contains('read')));
      // The interrupted call may still commit its original derived build.
      expect(await f.files.s.h.count('retrieval_index_builds'), 1);
      expect(await f.files.s.h.count('questions'), 0);
    });
  }

  for (final fail in [false, true]) {
    test(
        'file output ${fail ? "failure poisons" : "flush retains"} the original invocation slot',
        () async {
      final context = await f.selected();
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeWrite = (id) async {
        if (id != 'read') return;
        entered.complete();
        await release.future;
        if (fail) throw StateError('synthetic_write_failure');
      };
      unawaited(f.request(
          'tools/call',
          {
            'name': 'retrieve_file_content',
            'arguments': {'contextRef': context, 'query': 'needle'}
          },
          id: 'read'));
      await entered.future;
      var idle = false;
      final done = f.port.whenSettled.then((_) => idle = true);
      final extra = await f.request('tools/call',
          {'name': 'open_generation_context', 'arguments': <String, dynamic>{}},
          id: 'extra');
      expect((extra['result'] as Map)['structuredContent']['error'],
          'resourceLimit');
      expect(idle, isFalse);
      release.complete();
      await done;
      if (fail) {
        expect(await f.settled, isFalse);
        expect(f.writes, isNot(contains('read')));
      } else {
        expect(f.writes, contains('read'));
        await f.data('open_generation_context');
      }
    });
  }
}
