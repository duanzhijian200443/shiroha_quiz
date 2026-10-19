// Explicitly opt in with SHIROHA_CODEX_EXE pointing to an installed codex.exe.
// This is Codex's real MCP client, exercised without a model or credentials.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

import 'fixtures/codex_app_server_support.dart';

void unavailable(Map<String, dynamic> response) {
  expect(response.containsKey('error'), isFalse);
  final result = response['result'] as Map;
  const envelope = {'profileVersion': 2, 'data': null, 'error': 'unavailable'};
  expect(result['isError'], isTrue);
  expect(result['structuredContent'], envelope);
  expect(jsonDecode(result['content'].single['text'] as String), envelope);
}

void main() {
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  final enabled = Platform.isWindows && executable != null;
  final repo = Directory.current.path;
  late Directory home;
  InstalledCodex? codex;

  setUp(() async {
    // Non-ASCII and spaces exercise Windows argument/path handling. Keep the
    // home inside the repository and never change the parent process env.
    final root = Directory(p.join(repo, '.dart_tool', 'codex-client-tests'));
    await root.create(recursive: true);
    home = await root.createTemp('Codex 合成 ');
  });
  tearDown(() async {
    if (codex != null) {
      final exit = await codex!.rpc.close();
      expect(codex!.rpc.forcedClose, isFalse,
          reason: 'Codex must close on EOF.');
      expect(exit, 0);
      expect(codex!.rpc.protocolClean, isTrue);
      codex = null;
    }
    final pidFiles = await home
        .list()
        .where((file) =>
            file is File &&
            RegExp(r'^server-[0-9]+\.pid$').hasMatch(p.basename(file.path)))
        .cast<File>()
        .toList();
    for (final file in pidFiles) {
      final serverPid = int.parse(await file.readAsString());
      final status = await Process.run(
          'tasklist.exe', ['/FI', 'PID eq $serverPid', '/FO', 'CSV', '/NH']);
      expect(status.exitCode, 0);
      expect(status.stdout as String, isNot(contains('"$serverPid"')),
          reason: 'Owned Dart server must exit when Codex closes.');
    }
    await home.delete(recursive: true);
  });

  Future<InstalledCodex> start({String? command, String? entrypoint}) async {
    if (executable == null ||
        !File(executable).existsSync() ||
        p.extension(executable).toLowerCase() != '.exe') {
      fail('SHIROHA_CODEX_EXE must name an existing installed codex.exe.');
    }
    final client = InstalledCodex(executable, repo, home);
    codex = client;
    await client.configure(command: command, entrypoint: entrypoint);
    await client.start();
    return client;
  }

  test('Dart production stdio is JSON-only and exits on EOF', () async {
    final rpc = await JsonLineProcess.start(
        flutterDartExecutable(), ['lib/mcp/vnext_mcp_entrypoint.dart'],
        cwd: repo, home: home.path);
    try {
      final initialized = await rpc.request(
          'initialize',
          {
            'protocolVersion': '2025-11-25',
            'capabilities': {},
            'clientInfo': {'name': 'stdout_probe', 'version': '1'}
          },
          mcp: true);
      expect(initialized['result']['serverInfo']['version'], '0.2.0');
      rpc.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      final response = await rpc.request(
          'tools/call', {'name': 'open_generation_context', 'arguments': {}},
          mcp: true);
      unavailable(response);
    } finally {
      expect(await rpc.close(), 0);
      expect(rpc.forcedClose, isFalse);
      expect(rpc.protocolClean, isTrue);
    }
  });

  test(
      'installed Codex: seven tools, schemas, real calls, sessions and reconnect',
      () async {
    var client = await start();
    Future<void> discover() async {
      final response = await client.inventory();
      expect(response.containsKey('error'), isFalse);
      final server = response['result']['data'].single as Map;
      expect(server['name'], 'shiroha_vnext');
      expect(server['serverInfo']['version'], '0.2.0');
      final tools = server['tools'] as Map;
      expect(tools.keys.toSet(), {
        'open_generation_context',
        'search_questions',
        'get_question_detail',
        'retrieve_file_content',
        'get_file_passage',
        'propose_generated_questions',
        'get_question_proposal',
      });
      for (final entry in VnextMcpServer.inputSchemas.entries) {
        final actual = tools[entry.key] as Map;
        // SDK omits an empty required list when encoding JsonObject.
        final expected = Map<String, dynamic>.from(entry.value);
        if ((expected['required'] as List).isEmpty) expected.remove('required');
        expect(actual['inputSchema'], expected, reason: entry.key);
        expect(actual['outputSchema']['properties']['profileVersion'],
            {'type': 'integer', 'minimum': 2, 'maximum': 2});
        expect(actual['annotations'], {
          'readOnlyHint': entry.key != 'propose_generated_questions',
          'destructiveHint': false,
          'idempotentHint': entry.key != 'open_generation_context',
          'openWorldHint': false,
        });
      }
    }

    await discover();
    unavailable(await client.call('open_generation_context', {}));
    unavailable(
        await client.call('get_question_proposal', {'submissionKey': 'probe'}));
    unavailable(await client.call('propose_generated_questions', {
      'contextRef': 'A' * 43,
      'submission': {
        'schemaVersion': 1,
        'submissionKey': 'probe',
        'requestedCount': 1,
        'items': [{}]
      }
    }));
    // Input-schema rejection and unknown tool remain distinct protocol failures.
    final invalid = await client.call('search_questions', {'query': 'probe'});
    expect(invalid['error'], isNotNull);
    final unknown = await client.call('commit_generated_questions', {});
    expect(unknown['error'], isNotNull);
    unavailable(await client.call('open_generation_context', {}));
    final first = client.threadId;
    await client.newThread();
    expect(client.threadId, isNot(first));
    await discover();
    unavailable(await client.call('open_generation_context', {}));
    expect(await client.rpc.close(), 0);
    expect(client.rpc.forcedClose, isFalse);
    expect(client.rpc.protocolClean, isTrue);
    // Reopen using the same isolated registered configuration, a fresh process
    // and fresh session. No business result is reused.
    client = await start();
    await discover();
    unavailable(await client.call('open_generation_context', {}));
  },
      skip: enabled ? false : 'Windows + explicit SHIROHA_CODEX_EXE required.',
      timeout: const Timeout(Duration(minutes: 2)));

  for (final missingCommand in [true, false]) {
    test(
        'installed Codex: missing ${missingCommand ? 'executable' : 'script'} fails closed',
        () async {
      final client = await start(
          command:
              missingCommand ? p.join(home.path, 'missing-dart.exe') : null,
          entrypoint:
              missingCommand ? null : 'test/mcp/fixtures/missing-entry.dart');
      final response = await client.inventory();
      expect(response.containsKey('error'), isFalse);
      final server = response['result']['data'].single as Map;
      expect(server['tools'], isEmpty);
      final result = await client.call('open_generation_context', {});
      expect(result['error'], isNotNull);
    },
        skip:
            enabled ? false : 'Windows + explicit SHIROHA_CODEX_EXE required.',
        timeout: const Timeout(Duration(minutes: 1)));
  }
}
