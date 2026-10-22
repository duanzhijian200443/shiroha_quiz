// Shared by real SDK and opt-in installed Codex Bridge tests only.
import 'dart:async';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_bridge_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import '../../data/external/fixtures/windows_tls_bridge_cases.dart';
import '../../data/external/windows_tls_transport_test.dart' as tls;

/// Test-only connection supplier. Every independent call gets a fresh verified
/// connection; an attempted call is never retried or moved to another channel.
final class VnextV3AppLink implements VnextMcpPort, IpcTrustedContextBinding {
  VnextV3AppLink(this.h) {
    final local = h.pairing.local;
    app = VnextMcpAppComposition(
        host: local.coordinator.host,
        reads: local.reads,
        stages: local.stages,
        authentication: VnextMcpSessionAuthentication(() async => null),
        approvedTargets: const []);
  }
  final tls.TlsHarness h;
  late final VnextMcpAppComposition app;
  final attempts = <BridgeFixture>[];
  final sessions = <ExternalSession>[];
  final contexts = <ExternalExecutionContext>[];
  Future<void> Function()? configureGrant, afterBinding;
  bool prepared = false, foreignExecution = false;
  void Function(BridgeFixture)? configureAttempt;
  @override
  LocalHostDispatchCore get host => app.host;
  @override
  ExternalClock get clock => app.clock;
  @override
  Duration get readTimeout => app.readTimeout;
  @override
  Future<ExternalExecutionContext> bind(
      {required ExternalSession session,
      required LocalHostSessionEntry entry,
      required IpcContextSelection selection,
      required ExternalCallControl control}) async {
    sessions.add(session);
    final ExternalExecutionContext context;
    if (foreignExecution) {
      final foreign =
          await h.verifier.authenticate(tls.MemoryTlsChannel(), h.plan);
      context = await host.openRead(await host.bindSession(foreign.session),
          context: selection.contextRef);
    } else {
      context = await app.bind(
          session: session,
          entry: entry,
          selection: selection,
          control: control);
    }
    contexts.add(context);
    await afterBinding?.call();
    return context;
  }

  Future<BridgeFixture> connect({bool attachHost = true}) async {
    final fixture = BridgeFixture(h);
    attempts.add(fixture);
    configureAttempt?.call(fixture);
    await fixture.open(
        binding: this,
        prepare: !prepared,
        configureGrant: configureGrant,
        attachHost: attachHost);
    prepared = true;
    return fixture;
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    final fixture = await connect();
    final port = VnextMcpBridgePort(fixture.bridge);
    try {
      return await port.call(tool, arguments,
          cancelled: cancelled, available: available);
    } finally {
      await port.close();
      await h.candidate!.whenConnectionsSettled;
      fixture.released();
    }
  }

  Future<Map<String, Object?>> invoke(String tool,
          [Map<String, dynamic> arguments = const {}]) =>
      call(tool, arguments,
          cancelled: const Stream.empty(), available: () => true);
  @override
  Future<void> close() async {
    for (final fixture in attempts) {
      await fixture.bridge.close();
    }
    await app.close();
  }
}
