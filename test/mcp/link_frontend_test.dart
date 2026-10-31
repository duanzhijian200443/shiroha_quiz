import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';
import 'package:shiroha_quiz/mcp/link_frontend.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

/// Synthetic IPC only. MCP negotiation, validation and output use the real SDK.
final class Channel implements LocalRelayConnection {
  final messages = <Map<String, Object?>>[];
  final attachEntered = Completer<void>();
  final callEntered = Completer<void>();
  final attachGate = Completer<void>();
  final resultGate = Completer<void>();
  bool holdAttach = false, busy = false, closed = false;
  int receives = 0;
  @override
  bool get isCurrent => !closed;
  @override
  Future<void> accept() async {
    if (busy) throw const LocalRelayException(busy: true);
  }

  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async {
    messages.add(message);
    if (message['kind'] == 'call' && !callEntered.isCompleted) {
      callEntered.complete();
    }
  }

  @override
  Future<Map<String, Object?>> receive(Duration deadline) async {
    final envelope = <String, Object?>{
      'version': 1,
      'runId': 'test-run',
      'connectionId': 'test-connection'
    };
    switch (++receives) {
      case 1:
        return {
          ...envelope,
          'kind': 'hello',
          'capabilitySet': 'shiroha.profile3.base11'
        };
      case 2:
        attachEntered.complete();
        if (holdAttach) await attachGate.future;
        return {...envelope, 'kind': 'attached', 'leaseId': 'test-lease'};
      default:
        await resultGate.future;
        if (closed) throw const LocalRelayException();
        return {
          ...envelope,
          'kind': 'result',
          'id': messages.lastWhere((m) => m['kind'] == 'call')['id'],
          'result': vnextFailure('unavailable', profileVersion: 3)
        };
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!attachGate.isCompleted) attachGate.complete();
    if (!resultGate.isCompleted) resultGate.complete();
  }
}

final class ObservedOutput extends IOStreamTransport {
  ObservedOutput({required super.stream, required super.sink});
  Completer<void>? outputGate;
  final writing = Completer<void>();
  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    if (outputGate != null && message is JsonRpcResponse) {
      if (!writing.isCompleted) writing.complete();
      await outputGate!.future;
    }
    await super.send(message, relatedRequestId: relatedRequestId);
  }
}

void main() {
  test('cancellation during attach is buffered and correlated exactly once',
      () async {
    final channel = Channel()..holdAttach = true;
    final port = LinkFrontendPort(openChannel: () => channel);
    final result = port.call('open_context', {},
        cancelled: const Stream.empty(), available: () => true, responseId: 7);
    await channel.attachEntered.future;
    port.cancelRequest(8);
    port.cancelRequest(7);
    port.cancelRequest(7);
    expect(channel.messages.where((m) => m['kind'] == 'cancel'), isEmpty);
    channel.attachGate.complete();
    await channel.callEntered.future;
    await Future<void>.delayed(Duration.zero);
    expect(
        channel.messages.map((m) => m['kind']), ['attach', 'call', 'cancel']);
    expect(channel.messages.last['id'], 1);
    channel.resultGate.complete();
    await result;
    await port.close();
  });

  test('busy contender closes its failed pipe and can try a fresh one',
      () async {
    final first = Channel()..busy = true;
    final second = Channel()..resultGate.complete();
    var opens = 0;
    final port =
        LinkFrontendPort(openChannel: () => opens++ == 0 ? first : second);
    Future<Map<String, Object?>> call(int id) => port.call('open_context', {},
        cancelled: const Stream.empty(), available: () => true, responseId: id);
    expect((await call(1))['error'], 'busy');
    expect(first.closed, isTrue);
    expect((await call(2))['error'], 'unavailable');
    expect(second.messages.where((m) => m['kind'] == 'call'), hasLength(1));
    await port.close();
  });

  for (final eof in [false, true]) {
    test(
        'real SDK static discovery and ${eof ? 'EOF without cancellation' : 'delivery after output'}',
        () async {
      final channel = Channel();
      var opens = 0;
      final port = LinkFrontendPort(openChannel: () {
        opens++;
        return channel;
      });
      final toServer = StreamController<List<int>>();
      final toClient = StreamController<List<int>>();
      final protocol =
          McpServer(const Implementation(name: 'test-link', version: '1'));
      final server =
          VnextMcpServer(port, protocolServer: protocol, profileVersion: 3);
      final client = McpClient(
          const Implementation(name: 'test-client', version: '1'),
          options: const McpClientOptions(protocol: McpProtocol.require2026));
      final output =
          ObservedOutput(stream: toServer.stream, sink: toClient.sink);
      await protocol.connect(LinkFrontendTransport(output, port));
      await client.connect(
          IOStreamTransport(stream: toClient.stream, sink: toServer.sink));
      try {
        expect((await client.listTools()).tools.map((t) => t.name).toSet(),
            VnextMcpServer.schemasFor(3).keys.toSet());
        expect(opens, 0);
        final invalid = await client.callTool(const CallToolRequest(
            name: 'open_context', arguments: {'address': 'forbidden'}));
        expect(invalid.isError, isTrue);
        expect(opens, 0);
        output.outputGate = eof ? null : Completer<void>();
        final call = client.callTool(
            const CallToolRequest(name: 'open_context', arguments: {}));
        // Observe the expected SDK disconnection error before closing transport.
        final observed = call.then<Object?>((v) => v, onError: (Object e) => e);
        await channel.callEntered.future;
        if (eof) {
          await client.close();
          await server.close();
          await observed;
          expect(channel.closed, isTrue);
          expect(channel.messages.where((m) => m['kind'] == 'cancel'), isEmpty);
          expect(
              channel.messages.where((m) => m['kind'] == 'delivered'), isEmpty);
        } else {
          channel.resultGate.complete();
          await output.writing.future;
          expect(
              channel.messages.where((m) => m['kind'] == 'delivered'), isEmpty);
          output.outputGate!.complete();
          await observed;
          await Future<void>.delayed(Duration.zero);
          expect(channel.messages.where((m) => m['kind'] == 'delivered'),
              hasLength(1));
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
