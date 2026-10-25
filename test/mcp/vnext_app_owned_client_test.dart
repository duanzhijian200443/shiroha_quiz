import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/vnext_app_owned_client.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_entrypoint.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

void main() {
  test('App protocol client preserves the formal refusal through real SDK',
      () async {
    // Model process I/O event delivery. Synchronous reentrant delivery can send
    // notifications back before the SDK finishes handling initialize itself.
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final protocol =
        McpServer(const Implementation(name: 'formal-refusal', version: '1'));
    final server =
        VnextMcpServer(const UnavailableVnextApp(), protocolServer: protocol);
    final client =
        VnextAppOwnedClient(input: toClient.stream, output: toServer.sink);
    try {
      await protocol.connect(
          IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
      await client.connect();
      final result = await client.call('open_generation_context', {});
      expect(
          result, {'profileVersion': 2, 'data': null, 'error': 'unavailable'});
      // Reuse the same stream/connection; no alternate server or Writer.
      expect(
          await client
              .call('get_question_proposal', {'submissionKey': 'unknown'}),
          result);
    } finally {
      await client.close().timeout(const Duration(seconds: 2));
      await server.close();
      await toServer.close();
      await toClient.close();
    }
  });

  test('an unexpected adjacent tool inventory refuses business forwarding',
      () async {
    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final server = McpServer(
        const Implementation(name: 'wrong-profile', version: '1'),
        options: const McpServerOptions(
            capabilities:
                ServerCapabilities(tools: ServerCapabilitiesTools())));
    var dispatched = false;
    server.registerTool('unexpected', inputSchema: const ToolInputSchema(),
        callback: (arguments, extra) async {
      dispatched = true;
      return const CallToolResult(content: []);
    });
    final client =
        VnextAppOwnedClient(input: toClient.stream, output: toServer.sink);
    try {
      await server.connect(
          IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
      await expectLater(client.connect(), throwsStateError);
      expect(dispatched, isFalse);
    } finally {
      await client.close().timeout(const Duration(seconds: 2));
      await server.close();
      await toServer.close();
      await toClient.close();
    }
  });
}
