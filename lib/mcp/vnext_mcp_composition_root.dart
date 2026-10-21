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
  const _PinnedAuthentication(this.session);
  final ExternalSession session;
  @override
  Future<ExternalSession?> authenticate() async => session;
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
final class VnextMcpAppComposition implements VnextMcpPort {
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
  final LocalHostDispatchCore host;
  final ExternalReadContextService reads;
  final ExternalGeneratedStageService stages;
  final OfflineIpcAuthenticationPort authentication;
  List<ExternalStageContext> _approved;

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
      final session = await authentication.authenticate();
      if (session == null) return vnextFailure('unauthenticated');
      final entry = await host.bindSession(session);
      final command = VnextMcpCommand.parse(tool, arguments);
      final projection = OfflineIpcCommandProjection(
          host: host, authentication: _PinnedAuthentication(session));
      Future<Map<String, Object?>> invoke(
          ExternalExecutionContext context) async {
        if (_closed || !available()) control.cancel();
        final id = 'mcp_${++_id}';
        final request = command.request(id);
        final result = await projection.invoke(request,
            context: context,
            control: control,
            responseAvailable: () => !_closed && available());
        if (result.frame == null) return vnextFailure('outcome_unknown');
        try {
          return command.response(
              VnextMcpCommand.decodeFrame(result.frame!), id);
        } catch (_) {
          return vnextFailure('invalidResult');
        }
      }

      final contextRef = command.contextRef;
      if (command.contextKind == VnextMcpContextKind.proposalLifecycle) {
        return await invoke(
            await host.openProposalLifecycle(entry, command.submissionKey!));
      }
      if (command.contextKind == VnextMcpContextKind.stage) {
        final access = await reads.capabilityAccess(
            session: session, context: contextRef!);
        ExternalStageContext? approved;
        for (final candidate in _approved) {
          final target = candidate.target;
          if (identical(candidate.access.session, session) &&
              target.bankName == access.target.bankName &&
              target.projectId == access.target.projectId &&
              target.folderName == access.target.folderName &&
              candidate.grantRevision == access.revision) {
            approved = candidate;
            break;
          }
        }
        if (approved == null) return vnextFailure('capability.accessDenied');
        return await invoke(await host.openStage(entry, approved));
      }
      final read = await host.openRead(entry, context: contextRef);
      return await invoke(read);
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
