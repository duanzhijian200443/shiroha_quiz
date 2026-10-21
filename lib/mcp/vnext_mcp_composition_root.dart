/// Explicit inactive App-side composition of P3/P7/P8/P9/P10 services.
library;

import 'dart:async';
import '../application/capabilities/capability.dart';
import '../application/external/external_generated_stage.dart';
import '../application/external/external_invocation_core.dart';
import '../application/external/external_read_context.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/ipc_command_projection.dart';
import 'vnext_mcp_protocol_projection.dart';
import 'vnext_mcp_server.dart';

final class _PinnedAuthentication implements OfflineIpcAuthenticationPort {
  const _PinnedAuthentication(this.owner, this.session);
  final OfflineIpcAuthenticationPort owner;
  final ExternalSession session;
  @override
  Future<ExternalSession?> authenticate() async =>
      identical(await owner.authenticate(), session) ? session : null;
}

/// Trusted App session supplier; protocol requests never select its identity.
final class VnextMcpSessionAuthentication
    implements OfflineIpcAuthenticationPort {
  const VnextMcpSessionAuthentication(this.session);
  final Future<ExternalSession?> Function() session;
  @override
  Future<ExternalSession?> authenticate() => session();
}

/// App owns authentication and prior target approvals. This composition selects
/// existing authority; a READ handle never mints approval. No startup installs it.
final class VnextMcpAppComposition
    implements VnextMcpPort, IpcTrustedContextBinding {
  VnextMcpAppComposition(
      {required this.host,
      required this.reads,
      required this.stages,
      required this.authentication,
      required Iterable<ExternalStageContext> approvedTargets})
      : _approved = List.unmodifiable(approvedTargets) {
    if (!identical(reads.admission, stages.runtimeAdmission)) {
      throw ArgumentError('Mismatched runtime admission');
    }
  }
  @override
  final LocalHostDispatchCore host;
  final ExternalReadContextService reads;
  final ExternalGeneratedStageService stages;
  final OfflineIpcAuthenticationPort authentication;
  List<ExternalStageContext> _approved;

  @override
  ExternalClock get clock => reads.admission.trust.clock;
  @override
  Duration get readTimeout => reads.maxQueryDuration;

  /// The P10 decoder supplies selections only after authenticating S and
  /// binding E. Only these original P8 openings can mint execution Contexts.
  @override
  Future<ExternalExecutionContext> bind({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required IpcContextSelection selection,
    required ExternalCallControl control,
  }) async {
    void check() {
      if (_closed || !host.isReady || control.failure != null) {
        throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
      }
    }

    check();
    final ExternalExecutionContext context;
    switch (selection.kind) {
      case IpcContextSelectionKind.rootRead:
        context = await host.openRead(entry);
      case IpcContextSelectionKind.read:
        context = await host.openRead(entry, context: selection.contextRef!);
      case IpcContextSelectionKind.proposalLifecycle:
        context =
            await host.openProposalLifecycle(entry, selection.submissionKey!);
      case IpcContextSelectionKind.reconciliation:
        context =
            await host.openReconciliation(entry, selection.submissionKey!);
      case IpcContextSelectionKind.stage:
        context =
            await _stageContext(session, entry, selection.contextRef!, control);
    }
    check();
    return context;
  }

  Future<ExternalExecutionContext> _stageContext(
      ExternalSession session,
      LocalHostSessionEntry entry,
      String contextRef,
      ExternalCallControl control) async {
    final access =
        await reads.capabilityAccess(session: session, context: contextRef);
    if (_closed || control.failure != null) {
      throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
    }
    for (final candidate in _approved) {
      final target = candidate.target;
      if (identical(candidate.access.session, session) &&
          target.bankName == access.target.bankName &&
          target.projectId == access.target.projectId &&
          target.folderName == access.target.folderName &&
          candidate.grantRevision == access.revision) {
        return host.openStage(entry, candidate);
      }
    }
    throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
  }

  /// Trusted local control supplies P3 approvals; no MCP tool invokes this.
  void replaceApprovedTargets(Iterable<ExternalStageContext> targets) {
    if (_closed) return;
    final snapshot = List<ExternalStageContext>.unmodifiable(targets);
    if (snapshot.length > 128) throw ArgumentError('Too many approved targets');
    _approved = snapshot;
  }

  final _pending = <Future<void>>{};
  bool _closed = false;
  int _id = 0;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || !host.isReady) return vnextFailure('unavailable');
    if (_pending.length >= 16) return vnextFailure('busy');
    final done = Completer<void>();
    _pending.add(done.future);
    final control = ExternalCallControl(clock: reads.admission.trust.clock);
    final cancellation = cancelled.listen((_) => control.cancel());
    try {
      final command = VnextMcpCommand.parse(tool, arguments);
      OfflineIpcAuthenticationPort invocationAuthentication = authentication;
      if (command.contextKind == VnextMcpContextKind.stage) {
        final session = await authentication.authenticate();
        if (session == null) return vnextFailure('unauthenticated');
        // Preserve cheap refusal before serializing the App's STAGE payload.
        await _stageContext(session, await host.bindSession(session),
            command.contextRef!, control);
        invocationAuthentication =
            _PinnedAuthentication(authentication, session);
      }
      final projection = OfflineIpcCommandProjection(
          host: host, authentication: invocationAuthentication);
      if (_closed || !available()) control.cancel();
      final id = 'mcp_${++_id}';
      final result = await projection.invokeV3(command.request(id),
          binding: this,
          control: control,
          responseAvailable: () => !_closed && available());
      if (result.frame == null) return vnextFailure('outcome_unknown');
      try {
        return command.response(VnextMcpCommand.decodeFrame(result.frame!), id);
      } catch (_) {
        return vnextFailure('invalidResult');
      }
    } on FormatException {
      return vnextFailure('invalidRequest');
    } catch (_) {
      return vnextFailure(
          _closed || !host.isReady ? 'unavailable' : 'capability.accessDenied');
    } finally {
      await cancellation.cancel();
      done.complete();
      _pending.remove(done.future);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await host.shutdown();
    await Future.wait(_pending.toList());
  }
}
