/// Unpublished offline composition; no production identity or transport adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../application/capabilities/capability.dart';
import '../../application/external/external_generated_stage.dart';
import '../../application/external/external_invocation_core.dart';
import '../../application/external/external_question_read.dart';
import '../../application/external/external_read_context.dart';
import '../../application/external/external_trust_core.dart';
import '../../application/external/local_host_dispatch.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import 'ipc_envelope_codec.dart';

part 'ipc_command_schema.dart';

/// Trusted offline credential authority. Payload metadata is never supplied.
abstract interface class OfflineIpcAuthenticationPort {
  Future<ExternalSession?> authenticate();
}

/// Trusted encoding seam for offline failure injection, after fixed validation.
abstract interface class IpcCommandFrameEncoder {
  Uint8List encodeResponse(String requestId, String payload);
}

final class _P9FrameEncoder implements IpcCommandFrameEncoder {
  const _P9FrameEncoder();
  @override
  Uint8List encodeResponse(String requestId, String payload) =>
      IpcEnvelopeCodec.encodeResponse(requestId, payload);
}

enum IpcCommandFailure {
  unauthenticated,
  unavailable,
  invalidRequest,
  unsupportedVersion,
  unsupportedCapability,
  invalidResult,
  responseEncodingFailed,
}

final class IpcCommandSchemaException implements Exception {
  const IpcCommandSchemaException(this.failure);
  final IpcCommandFailure failure;
  @override
  String toString() => 'IpcCommandSchemaException(${failure.name})';
}

/// Local evidence is the original result, never a wire Receipt or new journal.
final class OfflineIpcCommandResult {
  const OfflineIpcCommandResult._(this.frame, this.failure, this.execution);
  final Uint8List? frame;
  final String? failure;
  final CapabilityResult? execution;
}

/// Authenticate -> current P8 binding -> strict projection -> explicit P8 route.
/// The execution Context is supplied only by trusted P8 composition, not JSON.
final class OfflineIpcCommandProjection {
  OfflineIpcCommandProjection({
    required LocalHostDispatchCore host,
    required OfflineIpcAuthenticationPort authentication,
    IpcCommandFrameEncoder encoder = const _P9FrameEncoder(),
  })  : _host = host,
        _authentication = authentication,
        _encoder = encoder;

  final LocalHostDispatchCore _host;
  final OfflineIpcAuthenticationPort _authentication;
  final IpcCommandFrameEncoder _encoder;
  bool _closed = false;
  int _pending = 0;
  Completer<void>? _idle;
  Future<void>? _shutdown;

  /// Owning P8/P7 settlement, independent of caller/result availability.
  Future<void> get whenSettled => _host.whenSettled;

  Future<OfflineIpcCommandResult> invoke(UntrustedIpcEnvelope envelope,
      {required ExternalExecutionContext context,
      ExternalCallControl? control,
      bool Function()? responseAvailable}) async {
    if (_closed) return _failure(envelope, IpcCommandFailure.unavailable);
    if (_pending++ == 0) _idle = Completer<void>();
    try {
      final LocalHostSessionEntry entry;
      try {
        final session = await _authentication.authenticate();
        if (session == null) {
          return _failure(envelope, IpcCommandFailure.unauthenticated);
        }
        // P8's current runtime/Grant admission precedes ALL business parsing.
        entry = await _host.bindSession(session);
      } catch (_) {
        return _failure(envelope, IpcCommandFailure.unauthenticated);
      }
      if (_closed) return _failure(envelope, IpcCommandFailure.unavailable);
      final _CommandRequest request;
      try {
        request = _CommandRequest.decode(envelope);
      } on IpcCommandSchemaException catch (error) {
        return _failure(envelope, error.failure);
      }
      Future<CapabilityResult<O>> call<I, O>(CapabilityId<I, O> id, I input) =>
          _host.dispatch(id, input,
              entry: entry,
              context: context,
              control: control,
              responseAvailable: () =>
                  !_closed && (responseAvailable?.call() ?? true));
      // Never manufacture CapabilityId from a request string or use an executor.
      final CapabilityResult result = await switch (request.command) {
        _Command.listTargets => call(ExternalCapabilities.listTargets,
            request.input as ExternalTargetQuery),
        _Command.createReadContext => call(
            ExternalCapabilities.createReadContext,
            request.input as ExternalTargetSelection),
        _Command.searchQuestions => call(ExternalCapabilities.searchQuestions,
            request.input as ExternalQuestionQuery),
        _Command.getQuestionDetail => call(
            ExternalCapabilities.getQuestionDetail,
            request.input as ExternalQuestionSelection),
        _Command.listFileSelections => call(
            ExternalCapabilities.listFileSelections, const ExternalNoInput()),
        _Command.createFileContext => call(
            ExternalCapabilities.createFileContext,
            request.input as ExternalFileSelections),
        _Command.retrieveFileContent => call(
            ExternalCapabilities.retrieveFileContent,
            request.input as ExternalFileQuery),
        _Command.getFilePassage => call(ExternalCapabilities.getFilePassage,
            request.input as ExternalPassageSelection),
        _Command.stage => call(ExternalCapabilities.stage,
            request.input as ExternalStageSubmission),
        _Command.reconcile =>
          call(ExternalCapabilities.reconcile, const ExternalNoInput()),
      };
      if (result.failure != null || result.output == null) {
        return _encode(envelope, request.command,
            error:
                'capability.${(result.failure ?? CapabilityFailure.internalError).name}',
            execution: result);
      }
      try {
        final data = switch (request.command) {
          _Command.listTargets =>
            (result.output as ExternalTargetPage).toJson(),
          _Command.createReadContext ||
          _Command.createFileContext =>
            <String, Object?>{'contextRef': result.output as String},
          _Command.searchQuestions =>
            (result.output as ExternalQuestionSearchPage).toJson(),
          _Command.getQuestionDetail =>
            (result.output as ExternalQuestionDetail).toJson(),
          _Command.listFileSelections ||
          _Command.retrieveFileContent ||
          _Command.getFilePassage =>
            (result.output as ExternalFilePage).toJson(),
          _Command.stage || _Command.reconcile => <String, Object?>{
              'proposalId': (result.output as ExternalStageSummary).proposalId,
              'submissionKey':
                  (result.output as ExternalStageSummary).submissionKey,
              'publication': 'STAGED',
              'formalCommit': 'NOT_REPORTED',
            },
        };
        // Explicit deep whitelist rejects unknown nested DTO fields as well.
        _validateData(request.command, data);
        return _encode(envelope, request.command,
            data: data, execution: result);
      } catch (_) {
        return _encode(envelope, request.command,
            error: IpcCommandFailure.invalidResult.name, execution: result);
      }
    } finally {
      if (--_pending == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  OfflineIpcCommandResult _failure(
          UntrustedIpcEnvelope envelope, IpcCommandFailure failure) =>
      _encode(envelope, null, error: failure.name);

  OfflineIpcCommandResult _encode(
      UntrustedIpcEnvelope envelope, _Command? command,
      {Map<String, Object?>? data,
      String? error,
      CapabilityResult? execution}) {
    // A response/protocol-error frame cannot be repurposed into a command.
    if (envelope.kind != IpcMessageKind.request) {
      return OfflineIpcCommandResult._(
          null, IpcCommandFailure.invalidRequest.name, execution);
    }
    try {
      final payload = jsonEncode({
        'schemaVersion': IpcCommandResponseCodec.version,
        'type': 'result',
        'capability': command?.wireName,
        'data': data,
        'error': error,
      });
      if (utf8.encode(payload).length > IpcEnvelopeLimits.responseBytes) {
        throw const IpcCommandSchemaException(
            IpcCommandFailure.responseEncodingFailed);
      }
      final frame = _encoder.encodeResponse(envelope.requestId!, payload);
      return OfflineIpcCommandResult._(frame, error, execution);
    } catch (_) {
      // No restage, rollback claim, receipt replacement or invented zero effect.
      return OfflineIpcCommandResult._(
          null, IpcCommandFailure.responseEncodingFailed.name, execution);
    }
  }

  /// Include authentication/admission callers and P8's real owning work in drain.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _closed = true;
    final owning = _host.shutdown();
    return _shutdown = Future.wait([
      owning,
      _idle?.future ?? Future<void>.value(),
    ]).then((_) {});
  }
}
