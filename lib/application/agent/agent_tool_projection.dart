/// Provider encoding is downstream of Application evidence.
library;

import '../capabilities/capability.dart';

final class AgentToolDispatchResult {
  const AgentToolDispatchResult({required this.json, required this.receipt});
  final String json;
  final ExecutionReceipt receipt;
}
