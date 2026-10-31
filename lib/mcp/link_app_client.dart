import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import 'vnext_app_owned_client.dart';

/// Keeps SDK cancellation types inside the MCP adapter boundary.
final class LinkAppClient {
  LinkAppClient(
      {required Stream<List<int>> input, required StreamSink<List<int>> output})
      : _client = VnextAppOwnedClient(
            input: input, output: output, profileVersion: 3);
  final VnextAppOwnedClient _client;
  Future<void> connect() => _client.connect();
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled}) async {
    final controller = BasicAbortController();
    final subscription = cancelled.listen((_) => controller.abort());
    try {
      return await _client.call(tool, arguments, signal: controller.signal);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> close() => _client.close();
}
