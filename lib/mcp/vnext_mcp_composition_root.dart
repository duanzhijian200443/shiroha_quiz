/// Explicit inactive App-side composition of P3/P7/P8/P9/P10 services.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../application/capabilities/capability.dart';
import '../application/external/external_generated_stage.dart';
import '../application/external/external_invocation_core.dart';
import '../application/external/external_read_context.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/ipc_command_projection.dart';
import '../data/external/ipc_envelope_codec.dart';
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
      final projection = OfflineIpcCommandProjection(
          host: host, authentication: _PinnedAuthentication(session));
      Future<Map<String, Object?>> invoke(String capability,
          Map<String, Object?> input, ExternalExecutionContext context) async {
        if (_closed || !available()) control.cancel();
        final id = 'mcp_${++_id}';
        final request = _decode(IpcEnvelopeCodec.encodeRequest(
            id,
            jsonEncode({
              'schemaVersion':
                  capability == 'external_get_proposal_lifecycle' ? 2 : 1,
              'type': 'command',
              'capability': capability,
              'input': input,
            })));
        final result = await projection.invoke(request,
            context: context,
            control: control,
            responseAvailable: () => !_closed && available());
        if (result.frame == null) return vnextFailure('outcome_unknown');
        final response = IpcCommandResponseCodec.decode(_decode(result.frame!));
        return {
          'profileVersion': 2,
          'data': response['data'],
          'error': response['error']
        };
      }

      final contextRef = arguments['contextRef'] as String?;
      if (tool == 'get_question_proposal') {
        return await invoke(
            'external_get_proposal_lifecycle',
            {},
            await host.openProposalLifecycle(
                entry, arguments['submissionKey'] as String));
      }
      if (tool == 'propose_generated_questions') {
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
        return await invoke(
            'external_stage_generated_questions',
            {
              'submissionJson': jsonEncode(arguments['submission']),
              'externalRequestId': null,
            },
            await host.openStage(entry, approved));
      }
      final read = await host.openRead(entry, context: contextRef);
      if (tool == 'open_generation_context') {
        if (arguments.containsKey('fileRefs')) {
          if (contextRef == null ||
              arguments.containsKey('targetRef') ||
              arguments.containsKey('cursor') ||
              arguments.containsKey('pageSize')) {
            return vnextFailure('invalidRequest');
          }
          return await invoke('external_create_file_context',
              {'fileRefs': arguments['fileRefs']}, read);
        }
        if (contextRef != null) {
          if (arguments.length != 1) return vnextFailure('invalidRequest');
          return await invoke('external_list_file_selections', {}, read);
        }
        if (arguments.containsKey('targetRef')) {
          if (arguments.length != 1) return vnextFailure('invalidRequest');
          return await invoke('external_create_read_context',
              {'targetRef': arguments['targetRef']}, read);
        }
        return await invoke(
            'external_list_targets',
            {
              'pageSize': arguments['pageSize'] ?? 20,
              'cursor': arguments['cursor'],
            },
            read);
      }
      if (contextRef == null) return vnextFailure('invalidRequest');
      return switch (tool) {
        'search_questions' => await invoke(
            'external_search_questions',
            {
              'query': arguments['query'],
              'pageSize': arguments['pageSize'] ?? 20,
              'cursor': arguments['cursor']
            },
            read),
        'get_question_detail' => await invoke('external_get_question_detail',
            {'questionRef': arguments['questionRef']}, read),
        'retrieve_file_content' => await invoke(
            'external_retrieve_file_content',
            {'query': arguments['query'], 'limit': arguments['limit'] ?? 8},
            read),
        'get_file_passage' => await invoke(
            'external_get_file_passage',
            {
              'passageRef': arguments['passageRef'],
              'cursor': arguments['cursor']
            },
            read),
        _ => vnextFailure('unsupportedCapability'),
      };
    } catch (_) {
      return vnextFailure(
          _closed || !host.isReady ? 'unavailable' : 'capability.accessDenied');
    } finally {
      await cancellation.cancel();
      done.complete();
      _pending.remove(done.future);
    }
  }

  static UntrustedIpcEnvelope _decode(Uint8List bytes) {
    final decoder = IpcEnvelopeDecoder();
    final step = decoder.consume(bytes);
    decoder.finish();
    if (step.consumed != bytes.length) throw StateError('Invalid frame');
    return step.envelope!;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await host.shutdown();
    await Future.wait(_pending.toList());
  }
}
