/// Explicit inactive Windows attachment; normal startup never imports this file.
library;

import '../data/external/windows_tls_transport.dart';
import '../mcp/vnext_mcp_composition_root.dart';
import 'mcp_vnext_app_integration.dart';

/// Joins the App's database-close barrier to the original TLS Host drain.
/// The caller constructs the Host with the exact binding supplied by the App's
/// attachment factory. Protected owners remain with WindowsTlsHost.owned.
final class McpVnextWindowsTransport implements McpVnextAppTransport {
  McpVnextWindowsTransport({required this.binding, required this.transport}) {
    if (!identical(transport.binding, binding) ||
        !identical(transport.host, binding.host) ||
        transport.phase != WindowsTlsHostPhase.inactive) {
      throw ArgumentError('Mismatched inactive transport');
    }
  }

  @override
  final VnextMcpAppComposition binding;
  final WindowsTlsHost transport;

  @override
  Future<void> start() => transport.start();

  @override
  Future<void> close() => transport.shutdown();
}
