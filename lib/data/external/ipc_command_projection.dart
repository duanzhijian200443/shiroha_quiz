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

/// Untrusted selectors decoded only after current P8 Session admission.
enum IpcContextSelectionKind {
  rootRead,
  read,
  stage,
  reconciliation,
  proposalLifecycle
}

final class IpcContextSelection {
  const IpcContextSelection._(this.kind, {this.contextRef, this.submissionKey});
  final IpcContextSelectionKind kind;
  final String? contextRef, submissionKey;
  bool get isRead =>
      kind == IpcContextSelectionKind.rootRead ||
      kind == IpcContextSelectionKind.read ||
      kind == IpcContextSelectionKind.proposalLifecycle;
}

/// Compiled App composition only. Selectors supply no identity or authority;
/// implementations must use the original P8 openings and approval owners.
abstract interface class IpcTrustedContextBinding {
  LocalHostDispatchCore get host;
  ExternalClock get clock;
  Duration get readTimeout;
  Future<ExternalExecutionContext> bind({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required IpcContextSelection selection,
    required ExternalCallControl control,
  });
}

/// Optional compiled App binding for the explicit single-request human wait.
/// No approval action or decision is accepted from the wire.
abstract interface class IpcTrustedStageApprovalBinding
    implements IpcTrustedContextBinding {
  bool get stageApprovalEnabled;
  Future<ExternalExecutionContext> bindStageForApproval({
    required ExternalSession session,
    required LocalHostSessionEntry entry,
    required String contextRef,
    required ExternalStageSubmission submission,
    required ExternalCallControl control,
    required Future<ExternalSession?> Function() authenticate,
    required bool Function() available,
    void Function()? onWaiting,
  });
  Future<void> get whenStageApprovalSettled;
  void finishStageApproval(ExternalCallControl control, {required bool clean});
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
  IpcTrustedStageApprovalBinding? _stageBinding;
  ExternalCallControl? _stageControl;
  Completer<void>? _idle;
  Future<void>? _shutdown;

  /// Owning P8/P7 settlement, independent of caller/result availability.
  Future<void> get whenSettled => () async {
        await (_idle?.future ?? Future<void>.value());
        await _stageBinding?.whenStageApprovalSettled;
        await _host.whenSettled;
      }();

  /// Called after the same connection's I/O and acknowledged close, never from
  /// whenSettled (which must remain usable before writing the final response).
  void finishStageApproval({required bool clean}) {
    final control = _stageControl;
    if (control != null) {
      _stageBinding?.finishStageApproval(control, clean: clean);
    }
  }

  Future<OfflineIpcCommandResult> invoke(UntrustedIpcEnvelope envelope,
          {required ExternalExecutionContext context,
          ExternalCallControl? control,
          bool Function()? responseAvailable}) =>
      _invoke(envelope,
          context: context,
          control: control,
          responseAvailable: responseAvailable);

  /// v3 never falls back to a supplied legacy execution Context or wire version.
  Future<OfflineIpcCommandResult> invokeV3(UntrustedIpcEnvelope envelope,
          {required IpcTrustedContextBinding binding,
          bool stageApprovalWait = false,
          void Function()? onStageWaiting,
          ExternalCallControl? control,
          bool Function()? responseAvailable}) =>
      _invoke(envelope,
          binding: binding,
          stageApprovalWait: stageApprovalWait,
          onStageWaiting: onStageWaiting,
          control: control,
          responseAvailable: responseAvailable);

  Future<OfflineIpcCommandResult> _invoke(UntrustedIpcEnvelope envelope,
      {ExternalExecutionContext? context,
      IpcTrustedContextBinding? binding,
      bool stageApprovalWait = false,
      void Function()? onStageWaiting,
      ExternalCallControl? control,
      bool Function()? responseAvailable}) async {
    if (_closed) return _failure(envelope, IpcCommandFailure.unavailable);
    if (_pending++ == 0) _idle = Completer<void>();
    Timer? bindingTimer;
    try {
      final ExternalSession session;
      final LocalHostSessionEntry entry;
      try {
        final authenticated = await _authentication.authenticate();
        if (authenticated == null) {
          return _failure(envelope, IpcCommandFailure.unauthenticated);
        }
        session = authenticated;
        // P8's current runtime/Grant admission precedes ALL business parsing.
        entry = await _host.bindSession(session);
      } catch (_) {
        return _failure(envelope, IpcCommandFailure.unauthenticated);
      }
      if (_closed) return _failure(envelope, IpcCommandFailure.unavailable);
      final bindingStarted = binding?.clock.now();
      final _CommandRequest request;
      try {
        request = _CommandRequest.decode(envelope, selected: binding != null);
      } on IpcCommandSchemaException catch (error) {
        return _failure(envelope, error.failure);
      }
      final ExternalExecutionContext executionContext;
      var operationControl = control;
      if (binding != null) {
        try {
          if (!identical(binding.host, _host) ||
              binding.readTimeout <= Duration.zero ||
              binding.readTimeout > const Duration(seconds: 2)) {
            throw const LocalHostAdmissionException(
                CapabilityFailure.accessDenied);
          }
          DateTime? deadline = control?.deadline;
          if (request.selection!.isRead) {
            final readDeadline = bindingStarted!.add(binding.readTimeout);
            if (deadline == null || readDeadline.isBefore(deadline)) {
              deadline = readDeadline;
            }
          }
          final boundControl = operationControl = stageApprovalWait &&
                  request.selection!.kind == IpcContextSelectionKind.stage &&
                  control != null
              ? control
              : ExternalCallControl(clock: binding.clock, deadline: deadline);
          void forward(ExternalFailure failure) {
            if (failure == ExternalFailure.cancelled) {
              boundControl.cancel();
            } else {
              boundControl.expireDeadline();
            }
          }

          if (control?.failure != null) forward(control!.failure!);
          control?.interrupted.then(forward);
          if (deadline != null) {
            bindingTimer = Timer(deadline.difference(binding.clock.now()),
                boundControl.expireDeadline);
          }
          void check() {
            final failure = _bindingInterruption(boundControl);
            if (failure != null ||
                _closed ||
                !(responseAvailable?.call() ?? true)) {
              throw LocalHostAdmissionException(
                  failure ?? CapabilityFailure.accessDenied);
            }
          }

          check();
          if (stageApprovalWait &&
              request.selection!.kind == IpcContextSelectionKind.stage) {
            if (binding is! IpcTrustedStageApprovalBinding ||
                !binding.stageApprovalEnabled) {
              throw const LocalHostAdmissionException(
                  CapabilityFailure.accessDenied);
            }
            _stageBinding = binding;
            _stageControl = boundControl;
            executionContext = await binding.bindStageForApproval(
                session: session,
                entry: entry,
                contextRef: request.selection!.contextRef!,
                submission: request.input as ExternalStageSubmission,
                control: boundControl,
                authenticate: _authentication.authenticate,
                onWaiting: onStageWaiting,
                available: () =>
                    !_closed && (responseAvailable?.call() ?? true));
          } else {
            executionContext = await binding.bind(
                session: session,
                entry: entry,
                selection: request.selection!,
                control: boundControl);
          }
          check();
          // Revalidation may withhold S, but must never replace it with S2.
          if (!identical(await _authentication.authenticate(), session)) {
            throw const LocalHostAdmissionException(
                CapabilityFailure.accessDenied);
          }
          check();
        } catch (error) {
          final failure = _bindingInterruption(operationControl) ??
              (error is LocalHostAdmissionException
                  ? error.failure
                  : CapabilityFailure.accessDenied);
          return _encode(envelope, request.command,
              version: request.version, error: 'capability.${failure.name}');
        }
      } else {
        executionContext = context!;
      }
      Future<CapabilityResult<O>> call<I, O>(CapabilityId<I, O> id, I input) =>
          _host.dispatch(id, input,
              entry: entry,
              context: executionContext,
              control: operationControl,
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
            ExternalCapabilities.listFileSelections,
            request.input as ExternalTargetQuery),
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
        _Command.proposalLifecycle =>
          call(ExternalCapabilities.proposalLifecycle, const ExternalNoInput()),
      };
      if (result.failure != null || result.output == null) {
        return _encode(envelope, request.command,
            version: request.version,
            error:
                'capability.${(result.failure ?? CapabilityFailure.internalError).name}',
            execution: result);
      }
      try {
        final data = switch (request.command) {
          _Command.proposalLifecycle =>
            (result.output as ExternalProposalLifecycle).toJson(),
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
            version: request.version, data: data, execution: result);
      } catch (_) {
        return _encode(envelope, request.command,
            version: request.version,
            error: IpcCommandFailure.invalidResult.name,
            execution: result);
      }
    } finally {
      bindingTimer?.cancel();
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
      {int? version,
      Map<String, Object?>? data,
      String? error,
      CapabilityResult? execution}) {
    // A response/protocol-error frame cannot be repurposed into a command.
    if (envelope.kind != IpcMessageKind.request) {
      return OfflineIpcCommandResult._(
          null, IpcCommandFailure.invalidRequest.name, execution);
    }
    try {
      final payload = jsonEncode({
        'schemaVersion':
            version ?? command?.version ?? IpcCommandResponseCodec.version,
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
    _stageControl?.cancel();
    final owning = _host.shutdown();
    return _shutdown = Future.wait([
      owning,
      _idle?.future ?? Future<void>.value(),
    ]).then((_) {});
  }
}

CapabilityFailure? _bindingInterruption(ExternalCallControl? control) =>
    switch (control?.failure) {
      null => null,
      ExternalFailure.cancelled => CapabilityFailure.cancelled,
      _ => CapabilityFailure.deadlineExceeded,
    };
