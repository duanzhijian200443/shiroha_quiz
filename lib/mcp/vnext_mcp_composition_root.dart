/// Explicit inactive App-side composition of P3/P7/P8/P9/P10 services.
library;

import 'dart:async';
import '../application/capabilities/capability.dart';
import '../application/external/external_generated_stage.dart';
import '../application/external/external_invocation_core.dart';
import '../application/external/external_read_context.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/first_party_stage_approval.dart';
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
    implements
        VnextMcpPort,
        IpcTrustedStageApprovalBinding,
        IpcVersionedContextBinding {
  VnextMcpAppComposition(
      {required this.host,
      required this.reads,
      required this.stages,
      required this.authentication,
      this.stageApproval,
      this.profileVersion = 2,
      this.source = const VnextDataSource('windows', 'local'),
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
  final FirstPartyStageApproval? stageApproval;
  final int profileVersion;
  @override
  bool get supportsUnifiedProfile => profileVersion == 3;
  final VnextDataSource source;
  List<ExternalStageContext> _approved;

  @override
  ExternalClock get clock => reads.admission.trust.clock;
  @override
  Duration get readTimeout => reads.maxQueryDuration;

  @override
  bool get stageApprovalEnabled => stageApproval != null;
  @override
  Future<void> get whenStageApprovalSettled =>
      stageApproval?.whenSettled ?? Future<void>.value();
  @override
  void finishStageApproval(ExternalCallControl control,
          {required bool clean}) =>
      stageApproval?.finish(control, clean: clean);

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
  }) {
    final approval = stageApproval;
    if (_closed ||
        approval == null ||
        !identical(approval.host, host) ||
        !identical(approval.stages, stages)) {
      throw const LocalHostAdmissionException(CapabilityFailure.accessDenied);
    }
    return approval.waitForApproval(
        session: session,
        entry: entry,
        contextRef: contextRef,
        submissionJson: submission.submissionJson,
        control: control,
        authenticate: authenticate,
        available: available,
        onWaiting: onWaiting);
  }

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
      case IpcContextSelectionKind.rootStudy:
        if (profileVersion != 3) {
          throw const FormatException('unsupportedVersion');
        }
        context = await host.openStudy(entry);
      case IpcContextSelectionKind.study:
        if (profileVersion != 3) {
          throw const FormatException('unsupportedVersion');
        }
        context = await host.openStudy(entry, context: selection.contextRef!);
      case IpcContextSelectionKind.questionRead:
        if (profileVersion != 3) {
          throw const FormatException('unsupportedVersion');
        }
        context = await host.openRead(entry,
            context: selection.contextRef!,
            questionRef: selection.questionRef!);
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
    Map<String, Object?> failure(String code) =>
        vnextFailure(code, profileVersion: profileVersion, source: source);
    if (_closed || !host.isReady) return failure('unavailable');
    if (_pending.length >= 16) return failure('busy');
    final done = Completer<void>();
    _pending.add(done.future);
    final control = ExternalCallControl(clock: reads.admission.trust.clock);
    final cancellation = cancelled.listen((_) => control.cancel());
    try {
      final command = profileVersion == 3
          ? VnextMcpCommand.parseUnified(tool, arguments)
          : VnextMcpCommand.parse(tool, arguments);
      OfflineIpcAuthenticationPort invocationAuthentication = authentication;
      if (command.contextKind == VnextMcpContextKind.stage) {
        final session = await authentication.authenticate();
        if (session == null) return failure('unauthenticated');
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
      final result = await (profileVersion == 3
              ? projection.invokeV4
              : projection.invokeV3)(command.request(id),
          binding: this,
          control: control,
          responseAvailable: () => !_closed && available());
      if (result.frame == null) return failure('outcome_unknown');
      try {
        return {
          ...command.response(VnextMcpCommand.decodeFrame(result.frame!), id),
          if (profileVersion == 3) 'source': source.toJson()
        };
      } catch (_) {
        return failure('invalidResult');
      }
    } on FormatException {
      return failure('invalidRequest');
    } catch (_) {
      return failure(
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
    stageApproval?.cancel();
    await host.shutdown();
    await Future.wait(_pending.toList());
  }
}
