import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/android_mcp_transport.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

/// Real SDK framing over synthetic memory streams. Only transport is synthetic;
/// the original response-aware port and supplied App business owners execute.
final class UnifiedSdkHarness {
  UnifiedSdkHarness(VnextMcpAppComposition binding)
      : port = VnextMcpBusinessPort(binding, () => true),
        profileVersion = binding.profileVersion;
  final VnextMcpBusinessPort port;
  final int profileVersion;
  final _toServer = StreamController<List<int>>();
  final _toClient = StreamController<List<int>>();
  late McpClient client;
  late VnextMcpServer server;
  Future<void> Function()? beforeResponseWrite;

  Future<void> connect({McpProtocol protocol = McpProtocol.require2026}) async {
    final sdk =
        McpServer(const Implementation(name: 'synthetic-target', version: '1'));
    server = VnextMcpServer(port,
        protocolServer: sdk, profileVersion: profileVersion);
    client = McpClient(
        const Implementation(name: 'synthetic-client', version: '1'),
        options: McpClientOptions(protocol: protocol));
    final transport = _ObservedOutput(port,
        beforeResponseWrite: () async => beforeResponseWrite?.call(),
        stream: _toServer.stream,
        sink: _toClient.sink);
    port.attachTransport(() async {
      await transport.close();
      port.channelSettled(clean: true);
    });
    await sdk.connect(transport);
    await client.connect(
        IOStreamTransport(stream: _toClient.stream, sink: _toServer.sink));
  }

  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> arguments) async {
    final result = await client
        .callTool(CallToolRequest(name: name, arguments: arguments));
    await port.whenSettled;
    return result.structuredContent!;
  }

  Future<void> close() async {
    await client.close();
    await server.close();
    await _toServer.close();
    await _toClient.close();
  }
}

final class _ObservedOutput extends IOStreamTransport {
  _ObservedOutput(this.port,
      {required this.beforeResponseWrite,
      required super.stream,
      required super.sink});
  final VnextMcpBusinessPort port;
  final Future<void> Function() beforeResponseWrite;

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    try {
      if (message is JsonRpcResponse || message is JsonRpcError) {
        await beforeResponseWrite();
      }
      await super.send(message, relatedRequestId: relatedRequestId);
      final id = switch (message) {
        JsonRpcResponse() => message.id,
        JsonRpcError() => message.id,
        _ => null,
      };
      if (id != null) port.responseWritten(id);
    } catch (_) {
      port.outputFailed();
      rethrow;
    }
  }
}
