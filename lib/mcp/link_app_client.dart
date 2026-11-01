import 'dart:async';
import 'package:mcp_dart/mcp_dart.dart';
import 'vnext_app_owned_client.dart';
import '../data/external/link/link_call_diagnostics.dart';

/// Keeps SDK cancellation types inside the MCP adapter boundary.
final class LinkAppClient {
  LinkAppClient(
      {required Stream<List<int>> input, required StreamSink<List<int>> output})
      : _client = VnextAppOwnedClient(
            input: input, output: output, profileVersion: 3);
  final VnextAppOwnedClient _client;
  Future<void> connect() => _client.connect();
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled, LinkCallTrace? diagnostic}) async {
    final controller = BasicAbortController();
    final subscription = cancelled.listen((_) => controller.abort());
    try {
      return await _client.call(tool, arguments,
          signal: controller.signal,
          observer: diagnostic == null
              ? null
              : (phase) {
                  switch (phase) {
                    case VnextClientCallPhase.entered:
                      diagnostic.stage(
                          LinkCallStage.backendCall, LinkCallOutcome.entered);
                    case VnextClientCallPhase.returned:
                      diagnostic.stage(
                          LinkCallStage.backendCall, LinkCallOutcome.succeeded);
                    case VnextClientCallPhase.failed:
                      diagnostic.stage(LinkCallStage.backendCall,
                          LinkCallOutcome.failed, LinkCallCause.clientFailure);
                    case VnextClientCallPhase.validated:
                      diagnostic.stage(LinkCallStage.resultValidate,
                          LinkCallOutcome.succeeded);
                    default:
                      diagnostic.stage(
                          LinkCallStage.resultValidate,
                          LinkCallOutcome.rejected,
                          switch (phase) {
                            VnextClientCallPhase.missing =>
                              LinkCallCause.resultMissing,
                            VnextClientCallPhase.shape =>
                              LinkCallCause.resultShape,
                            VnextClientCallPhase.profile =>
                              LinkCallCause.resultProfile,
                            VnextClientCallPhase.source =>
                              LinkCallCause.resultSource,
                            VnextClientCallPhase.data =>
                              LinkCallCause.resultData,
                            VnextClientCallPhase.errorType =>
                              LinkCallCause.resultErrorType,
                            VnextClientCallPhase.errorFlag =>
                              LinkCallCause.resultErrorFlag,
                            _ => LinkCallCause.unknown,
                          });
                  }
                });
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> close() => _client.close();
}
