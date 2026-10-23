// Shared by real SDK and opt-in installed Codex Bridge tests only.
import 'dart:async';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_bridge_port.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import '../../data/external/fixtures/windows_tls_bridge_cases.dart';
import '../../data/external/windows_tls_transport_test.dart' as tls;
import 'stage_cancellation_evidence.dart';

/// Test-only connection supplier. Every independent call gets a fresh verified
/// connection; an attempted call is never retried or moved to another channel.
final class VnextV3AppLink
    implements VnextMcpPort, IpcTrustedStageApprovalBinding {
  VnextV3AppLink(this.h,
      {this.enableStageApprovalWait = false, this.evidence}) {
    final local = h.pairing.local;
    if (enableStageApprovalWait) {
      approval = FirstPartyStageApproval(
          host: local.coordinator.host,
          stages: local.stages,
          localOwner: local.localSession,
          compositionIsCurrent: () => local.current,
          monotonicNow: () => h.deadlines.now,
          schedule: h.deadlines.schedule);
    }
    app = VnextMcpAppComposition(
        host: local.coordinator.host,
        reads: local.reads,
        stages: local.stages,
        authentication: VnextMcpSessionAuthentication(() async => null),
        stageApproval: approval,
        approvedTargets: const []);
    if (enableStageApprovalWait) {
      controls = FirstPartyExternalAccess(
          policy: local.local.service,
          compositionIsCurrent: () => local.current);
      controls!.installTrusted(FirstPartyExternalBinding(
          management: local.management,
          coordinator: local.coordinator,
          trust: local.trust,
          stages: local.stages,
          localOwner: local.localSession,
          authenticationAttempt: () => null,
          stageApproval: approval,
          publishApprovals: app.replaceApprovedTargets,
          shutdown: () async {
            final closing = approval!.close();
            await h.candidate?.shutdown();
            await closing;
          }));
    }
  }
  final tls.TlsHarness h;
  final bool enableStageApprovalWait;
  final StageCancellationEvidence? evidence;
  FirstPartyStageApproval? approval;
  FirstPartyExternalAccess? controls;
  final stageSessions = <ExternalSession>[];
  final stageEntries = <LocalHostSessionEntry>[];
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
  bool get stageApprovalEnabled => app.stageApprovalEnabled;
  @override
  Future<void> get whenStageApprovalSettled => app.whenStageApprovalSettled;
  @override
  void finishStageApproval(ExternalCallControl control,
          {required bool clean}) =>
      app.finishStageApproval(control, clean: clean);
  @override
  Future<ExternalExecutionContext> bindStageForApproval({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required String contextRef,
    required ExternalStageSubmission submission,
    required ExternalCallControl control,
    required Future<ExternalSession?> Function() authenticate,
    required bool Function() available,
    void Function()? onWaiting,
  }) async {
    stageSessions.add(session);
    stageEntries.add(entry);
    final context = await app.bindStageForApproval(
        session: session,
        entry: entry,
        contextRef: contextRef,
        submission: submission,
        control: control,
        authenticate: authenticate,
        available: available,
        onWaiting: onWaiting);
    contexts.add(context);
    return context;
  }

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
        enableStageApprovalWait: enableStageApprovalWait,
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
    final trace = tool == 'propose_generated_questions' ? evidence : null;
    try {
      return await port.call(tool, arguments,
          cancelled: cancelled, available: available);
    } finally {
      trace?.mark(StageCancellationPhase.bridgeCallReturned);
      trace?.mark(StageCancellationPhase.portCloseStarted);
      await port.close();
      trace?.mark(StageCancellationPhase.portCloseFinished);
      await h.candidate!.whenConnectionsSettled;
      trace?.mark(StageCancellationPhase.owningSettled);
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
    await controls?.shutdown();
    await app.close();
  }
}
