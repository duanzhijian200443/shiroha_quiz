/// Standalone vNext entrypoint. Production admission remains closed.
library;

import 'vnext_mcp_server.dart';

/// No production credential/transport composition is admitted yet. This endpoint
/// advertises the independent profile but cannot fall back to another writer.
final class UnavailableVnextApp implements VnextMcpPort {
  const UnavailableVnextApp();
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
          {required Stream<void> cancelled,
          required bool Function() available}) async =>
      vnextFailure('unavailable');
  @override
  Future<void> close() async {}
}

Future<void> main() => VnextMcpServer(const UnavailableVnextApp()).serveStdio();
