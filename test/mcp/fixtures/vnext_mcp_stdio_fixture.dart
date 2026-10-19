// Test-only App link sharing the existing subprocess stdio pipes. No sockets,
// credentials, database, fallback writer or production transport.
import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

const fixtureAppMethod = 'test/shiroha_app_call';
const fixtureAppResultMethod = 'test/shiroha_app_result';

final class FixtureAppLink implements VnextMcpPort {
  FixtureAppLink(this.protocol) {
    protocol.server.setNotificationHandler<JsonRpcNotification>(
        fixtureAppResultMethod, (notification) async {
      final pending = _active[notification.params!['id']];
      if (pending != null && !pending.isCompleted) {
        pending.complete(
            (notification.params!['result'] as Map).cast<String, Object?>());
      }
    },
        (params, meta) => JsonRpcNotification(
            method: fixtureAppResultMethod, params: params, meta: meta));
  }
  final McpServer protocol;
  final _active = <int, Completer<Map<String, Object?>>>{};
  int _id = 0;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_active.length >= 16) return vnextFailure('busy');
    final id = ++_id;
    final result = Completer<Map<String, Object?>>();
    _active[id] = result;
    final subscription = cancelled.listen((_) {
      if (!result.isCompleted) result.complete(vnextFailure('outcome_unknown'));
    });
    try {
      if (!available()) return vnextFailure('unavailable');
      // Test-only notifications to the synthetic App in the parent harness.
      // No server-to-client request, sampling or shipping custom method.
      await protocol.server.notification(JsonRpcNotification(
          method: fixtureAppMethod,
          params: {'id': id, 'tool': tool, 'arguments': arguments}));
      return await result.future;
    } catch (_) {
      return vnextFailure('outcome_unknown');
    } finally {
      await subscription.cancel();
      _active.remove(id);
    }
  }

  @override
  Future<void> close() async {
    for (final result in _active.values.toList()) {
      if (!result.isCompleted) result.complete(vnextFailure('outcome_unknown'));
    }
  }
}

Future<void> main() async {
  final protocol = McpServer(
      const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
      options: const McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools())));
  await VnextMcpServer(FixtureAppLink(protocol), protocolServer: protocol)
      .serveStdio();
}
