import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/vnext_app_owned_client.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_entrypoint.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

void main() {
  for (final failure in [
    'none',
    'missing',
    'shape',
    'profile',
    'source',
    'data',
    'errorType',
    'errorFlag',
    'handler',
    'disconnected'
  ]) {
    for (final mode in ['off', 'observe', 'throw']) {
      test(
          'shared client $failure with $mode observer preserves original result/type',
          () async {
        const sentinel = 'SENTINEL_PRIVATE_RESPONSE';
        final toServer = StreamController<List<int>>(),
            toClient = StreamController<List<int>>();
        final server =
            McpServer(const Implementation(name: 'synthetic', version: '1'));
        final value = <String, dynamic>{
          'profileVersion': 3,
          'data': <String, dynamic>{},
          'error': null,
          'source': {'kind': 'android', 'deviceRef': 'synthetic'}
        };
        switch (failure) {
          case 'shape':
            value.remove('data');
          case 'profile':
            value['profileVersion'] = 2;
          case 'source':
            value['source'] = sentinel;
          case 'data':
            value['data'] = sentinel;
          case 'errorType':
            value['error'] = {'private': sentinel};
          case 'errorFlag':
            value['error'] = sentinel;
        }
        for (final tool in VnextMcpServer.schemasFor(3).keys) {
          server.registerTool(tool, inputSchema: const ToolInputSchema(),
              callback: (arguments, extra) async {
            if (failure == 'handler') throw StateError(sentinel);
            return CallToolResult(
                content: [],
                structuredContent: failure == 'missing' ? null : value);
          });
        }
        final client = VnextAppOwnedClient(
            input: toClient.stream, output: toServer.sink, profileVersion: 3);
        final phases = <VnextClientCallPhase>[];
        try {
          await server.connect(
              IOStreamTransport(stream: toServer.stream, sink: toClient.sink));
          await client.connect();
          if (failure == 'disconnected') await server.close();
          final future = client.call('open_context', {},
              observer: mode == 'off'
                  ? null
                  : (phase) {
                      if (mode == 'throw') {
                        throw StateError('SENTINEL_OBSERVER');
                      }
                      phases.add(phase);
                    });
          if (failure == 'none') {
            expect(await future, value);
          } else if (failure == 'disconnected') {
            await expectLater(future, throwsA(isA<McpError>()));
          } else {
            await expectLater(future, throwsStateError);
          }
          if (mode == 'observe') {
            expect(phases.first, VnextClientCallPhase.entered);
            expect(
                phases.last,
                switch (failure) {
                  'none' => VnextClientCallPhase.validated,
                  'disconnected' => VnextClientCallPhase.failed,
                  'handler' => VnextClientCallPhase.missing,
                  'missing' => VnextClientCallPhase.missing,
                  'shape' => VnextClientCallPhase.shape,
                  'profile' => VnextClientCallPhase.profile,
                  'source' => VnextClientCallPhase.source,
                  'data' => VnextClientCallPhase.data,
                  'errorType' => VnextClientCallPhase.errorType,
                  _ => VnextClientCallPhase.errorFlag,
                });
          }
        } finally {
          await client.close();
          await server.close();
          await toServer.close();
          await toClient.close();
        }
      });
    }
  }
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
