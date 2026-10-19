// Shared synthetic App/SDK fixture. Installed Codex tests reuse the same owners.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import '../../application/external/local_host_test_support.dart';
import '../../application/external/external_question_read_test_support.dart';
import 'vnext_mcp_stdio_fixture.dart'
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
            'profileVersion': 2,
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

  Future<void> restart() async {
    await composition.close();
    await app.h.s.reopen();
    app.h.compose();
    app.compose();
    await app.startHost();
    auth.session = app.h.s.session;
    composition = VnextMcpAppComposition(
        host: app.host,
        reads: app.h.read,
        stages: app.h.s.service,
        authentication: auth,
        approvedTargets: []);
  }
}

Future<Map<String, dynamic>> call(McpClient client, String tool,
    [Map<String, dynamic> arguments = const {}]) async {
  final result =
      await client.callTool(CallToolRequest(name: tool, arguments: arguments));
  final envelope = result.structuredContent!;
  expect(jsonDecode((result.content.single as TextContent).text), envelope);
  expect(result.isError, envelope['error'] != null);
  expect(envelope['profileVersion'], 2);
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
