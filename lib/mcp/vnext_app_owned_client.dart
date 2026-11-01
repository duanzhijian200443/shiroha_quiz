import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import 'vnext_mcp_server.dart';

/// Client-local phases only; the shared client has no Link logging dependency.
enum VnextClientCallPhase {
  entered,
  returned,
  missing,
  shape,
  profile,
  source,
  data,
  errorType,
  errorFlag,
  validated,
  failed
}

typedef VnextClientCallObserver = void Function(VnextClientCallPhase);
void _observe(VnextClientCallObserver? observer, VnextClientCallPhase phase) {
  try {
    observer?.call(phase);
  } catch (_) {/* Diagnostics have no protocol authority. */}
}

/// Protocol client over original App-owned streams; never launches a process.
final class VnextAppOwnedClient {
  VnextAppOwnedClient(
      {required Stream<List<int>> input,
      required StreamSink<List<int>> output,
      this.profileVersion = 2})
      : _transport = IOStreamTransport(stream: _bounded(input), sink: output);
  final int profileVersion;

  final IOStreamTransport _transport;
  final _client = McpClient(
      const Implementation(name: 'shiroha_app_owned_bridge', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.legacy));

  static Stream<List<int>> _bounded(Stream<List<int>> input) {
    var lineBytes = 0;
    // A synchronous transformer forwards cancellation to the original source.
    // An async* wrapper can wait for another input event during SDK close.
    return input.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
      for (final byte in chunk) {
        lineBytes = byte == 10 ? 0 : lineBytes + 1;
        if (lineBytes > 2 * 1024 * 1024) {
          sink.addError(StateError('Bridge protocol unavailable'));
          return;
        }
      }
      sink.add(chunk);
    }));
  }

  Future<void> connect() async {
    await _client.connect(_transport);
    final listed = (await _client.listTools()).tools.map((t) => t.name).toSet();
    final expected = VnextMcpServer.schemasFor(profileVersion);
    if (listed.length != expected.length ||
        !listed.containsAll(expected.keys)) {
      throw StateError('Bridge protocol unavailable');
    }
  }

  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {AbortSignal? signal, VnextClientCallObserver? observer}) async {
    _observe(observer, VnextClientCallPhase.entered);
    late CallToolResult response;
    try {
      response = await _client.callTool(
          CallToolRequest(name: tool, arguments: arguments),
          options: RequestOptions(
              signal: signal,
              timeout: tool == 'propose_generated_questions'
                  ? const Duration(seconds: 145)
                  : const Duration(seconds: 12)));
    } catch (_) {
      _observe(observer, VnextClientCallPhase.failed);
      rethrow;
    }
    _observe(observer, VnextClientCallPhase.returned);
    final value = response.structuredContent;
    final invalid = value == null
        ? VnextClientCallPhase.missing
        : value.length != (profileVersion == 3 ? 4 : 3) ||
                !value.containsKey('data') ||
                !value.containsKey('error')
            ? VnextClientCallPhase.shape
            : value['profileVersion'] != profileVersion
                ? VnextClientCallPhase.profile
                : profileVersion == 3 && !validVnextSource(value['source'])
                    ? VnextClientCallPhase.source
                    : value['data'] != null && value['data'] is! Map
                        ? VnextClientCallPhase.data
                        : value['error'] != null && value['error'] is! String
                            ? VnextClientCallPhase.errorType
                            : (response.isError == true) !=
                                    (value['error'] != null)
                                ? VnextClientCallPhase.errorFlag
                                : null;
    if (invalid != null) {
      _observe(observer, invalid);
      throw StateError('Bridge protocol unavailable');
    }
    _observe(observer, VnextClientCallPhase.validated);
    return value!;
  }

  /// The owning composition calls this only AFTER original child settlement.
  Future<void> close() => _client.close();
}
