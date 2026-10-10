/// Typed candidate orchestration. Production CapabilityExecutor integration is
/// deliberately absent until it supports a real ExternalPrincipal.
library;

import 'dart:async';

import '../capabilities/capability.dart';
import 'external_trust_core.dart';

enum ExternalInvocationPhase { admission, execution, release, reconciliation }

/// Supplied by trusted Application authority, never decoded from messages.
final class ExternalAuthorizedContext {
  const ExternalAuthorizedContext({
    required this.principal,
    required this.generation,
    required this.revision,
    required this.scope,
  });
  final ExternalPrincipal principal;
  final int generation;
  final int revision;
  final Object scope;
}

/// Owning Application port does all current capability/scope/grant checks.
/// STAGE's future durable CAS boundary must live inside that owning port.
abstract interface class ExternalCapabilityPort<I, O> {
  bool authorize(ExternalAuthorizedContext context,
      CapabilityPermission permission, ExternalInvocationPhase phase);
  Future<CapabilityEvidence<O>> invoke(
      I input,
      ExternalAuthorizedContext context,
      CapabilityExecutionEvidence evidence,
      String? submissionKey);
  Future<CapabilityEvidence<O>> reconcile(
      ExternalAuthorizedContext context, String submissionKey);
}

final class ExternalOperation<I, O> {
  const ExternalOperation(this.id, this.permission, this.port);
  final CapabilityId<I, O> id;
  final CapabilityPermission permission;
  final ExternalCapabilityPort<I, O> port;
}

/// Transport-independent explicit cancellation/deadline events. A future
/// scheduler must call checkDeadline on clock progress; no timer or I/O here.
final class ExternalCallControl {
  ExternalCallControl({required this.clock, this.deadline});
  final ExternalClock clock;
  final DateTime? deadline;
  final _signal = Completer<ExternalFailure>();
  ExternalFailure? _failure;
  ExternalFailure? get failure {
    checkDeadline();
    return _failure;
  }

  Future<ExternalFailure> get interrupted => _signal.future;
  void cancel() => _interrupt(ExternalFailure.cancelled);
  void checkDeadline() {
    if (deadline != null && !clock.now().isBefore(deadline!)) {
      _interrupt(ExternalFailure.deadlineExceeded);
    }
  }

  void _interrupt(ExternalFailure failure) {
    if (_failure != null) return;
    _failure = failure;
    _signal.complete(failure);
  }
}

final class ExternalInvocationResult<O> {
  const ExternalInvocationResult({
    required this.phase,
    required this.status,
    required this.effect,
    this.output,
    this.failure,
    this.submissionKey,
  });
  final ExternalInvocationPhase phase;
  final CapabilityExecutionStatus status;
  final CapabilityEffect? effect;
  final O? output;
  final ExternalFailure? failure;
  final String? submissionKey;
}

/// Session-local request slots plus a bounded process-local STAGE journal.
/// The journal is not a durable receipt store and never retries a handler.
final class ExternalInvocationCore {
  ExternalInvocationCore(Iterable<ExternalOperation> operations,
      {this.maxInFlightPerSession = 4,
      this.maxInFlight = 16,
      this.maxStageKeys = 64}) {
    if (maxInFlightPerSession < 1 || maxInFlight < 1 || maxStageKeys < 1) {
      throw ArgumentError('Invalid candidate limits');
    }
    for (final operation in operations) {
      if (operation.permission != CapabilityPermission.read &&
          operation.permission != CapabilityPermission.stage) {
        throw ArgumentError('External permission excluded');
      }
      if (_operations.containsKey(operation.id.value)) {
        throw ArgumentError('Duplicate capability');
      }
      _operations[operation.id.value] = operation;
    }
  }
  final int maxInFlightPerSession;
  final int maxInFlight;
  final int maxStageKeys;
  final _operations = <String, ExternalOperation>{};
  final _active = <ExternalSession, Set<Object>>{};
  final _controls = <ExternalCallControl>{};
  final _stages = <(ExternalPrincipal, String), ExternalOperation>{};
  int get stageKeyCount => _stages.length;
  int activeCount(ExternalSession session) => _active[session]?.length ?? 0;
  int get totalActive =>
      _active.values.fold(0, (count, slots) => count + slots.length);

  ExternalFailure? _authorize<I, O>(
      ExternalSession session,
      ExternalAuthorizedContext context,
      ExternalOperation<I, O> operation,
      ExternalInvocationPhase phase,
      {bool receiptRead = false}) {
    final failure = session.failure;
    if (failure != null) return failure;
    if (!identical(context.principal, session.principal) ||
        context.generation != session.generation) {
      return ExternalFailure.staleContext;
    }
    if (!identical(_operations[operation.id.value], operation)) {
      return ExternalFailure.accessDenied;
    }
    try {
      if (!operation.port.authorize(
          context,
          receiptRead ? CapabilityPermission.read : operation.permission,
          phase)) {
        return ExternalFailure.accessDenied;
      }
    } catch (_) {
      return ExternalFailure.accessDenied;
    }
    return null;
  }

  Future<ExternalInvocationResult<O>> invoke<I, O>({
    required ExternalSession session,
    required ExternalAuthorizedContext context,
    required ExternalOperation<I, O> operation,
    required String requestId,
    required I input,
    required ExternalCallControl control,
    required bool Function() responseAvailable,
    String? submissionKey,
  }) async {
    ExternalInvocationResult<O> reject(ExternalFailure failure) =>
        ExternalInvocationResult(
          phase: ExternalInvocationPhase.admission,
          status: CapabilityExecutionStatus.notStarted,
          effect: CapabilityEffect.none,
          failure: failure,
          submissionKey: submissionKey,
        );
    final denied = _authorize(
        session, context, operation, ExternalInvocationPhase.admission);
    if (denied != null) return reject(denied);
    if (control.failure != null) return reject(control.failure!);
    if (requestId.isEmpty || requestId.length > 128) {
      return reject(ExternalFailure.invalidRequest);
    }
    final stage = operation.permission == CapabilityPermission.stage;
    if (stage &&
        (submissionKey == null ||
            submissionKey.isEmpty ||
            submissionKey.length > 128)) {
      return reject(ExternalFailure.invalidRequest);
    }
    final stageKey = (session.principal, submissionKey ?? '');
    if (stage && _stages.containsKey(stageKey)) {
      return reject(ExternalFailure.reconciliationRequired);
    }
    if (stage && _stages.length >= maxStageKeys) {
      return reject(ExternalFailure.resourceLimit);
    }
    if (totalActive >= maxInFlight || _controls.contains(control)) {
      return reject(ExternalFailure.resourceLimit);
    }
    final slots = _active.putIfAbsent(session, () => <Object>{});
    if (slots.length >= maxInFlightPerSession || !slots.add(requestId)) {
      return reject(ExternalFailure.resourceLimit);
    }
    _controls.add(control);
    if (stage) _stages[stageKey] = operation;
    final confirmed = CapabilityExecutionEvidence();
    var entered = false;
    void releaseSlot() {
      slots.remove(requestId);
      _controls.remove(control);
      if (slots.isEmpty) _active.remove(session);
    }

    try {
      // No await between admission and handler entry. Revoke/publication atomicity
      // remains an obligation of the owning durable Application port, not here.
      final pending =
          operation.port.invoke(input, context, confirmed, submissionKey);
      entered = true;
      // Attach both outcomes, consuming errors without creating an unhandled
      // future. A cancelled caller cannot free capacity for unfinished work.
      unawaited(pending.then<void>((_) => releaseSlot(),
          onError: (Object _, StackTrace __) => releaseSlot()));
      final settled = await Future.any<Object>([
        pending,
        control.interrupted,
      ]);
      if (settled is ExternalFailure) {
        return ExternalInvocationResult(
          phase: ExternalInvocationPhase.execution,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: confirmed.knownEffect,
          failure: settled,
          submissionKey: submissionKey,
        );
      }
      final evidence = settled as CapabilityEvidence<O>;
      if (!responseAvailable()) {
        return ExternalInvocationResult(
          phase: ExternalInvocationPhase.release,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: evidence.effect,
          failure: ExternalFailure.responseLost,
          submissionKey: submissionKey,
        );
      }
      final releaseFailure = control.failure ??
          _authorize(
              session, context, operation, ExternalInvocationPhase.release);
      return ExternalInvocationResult(
        phase: ExternalInvocationPhase.release,
        status: evidence.status,
        effect: evidence.effect,
        output: releaseFailure == null && evidence.failure == null
            ? evidence.output
            : null,
        failure: releaseFailure ??
            (evidence.failure == null ? null : ExternalFailure.handlerFailed),
        submissionKey: submissionKey,
      );
    } catch (_) {
      return ExternalInvocationResult(
        phase: ExternalInvocationPhase.execution,
        status: CapabilityExecutionStatus.outcomeUnknown,
        effect: confirmed.knownEffect,
        failure: ExternalFailure.handlerFailed,
        submissionKey: submissionKey,
      );
    } finally {
      if (!entered) releaseSlot();
    }
  }

  Future<ExternalInvocationResult<O>> reconcile<I, O>({
    required ExternalSession session,
    required ExternalAuthorizedContext context,
    required ExternalOperation<I, O> operation,
    required String submissionKey,
    required ExternalCallControl control,
    required bool Function() responseAvailable,
  }) async {
    ExternalInvocationResult<O> denied(ExternalFailure failure) =>
        ExternalInvocationResult(
          phase: ExternalInvocationPhase.reconciliation,
          status: CapabilityExecutionStatus.notStarted,
          effect: CapabilityEffect.none,
          failure: failure,
          submissionKey: submissionKey,
        );
    final failure = _authorize(
        session, context, operation, ExternalInvocationPhase.reconciliation,
        receiptRead: true);
    if (failure != null) return denied(failure);
    if (operation.permission != CapabilityPermission.stage ||
        !identical(_stages[(session.principal, submissionKey)], operation)) {
      return denied(ExternalFailure.invalidRequest);
    }
    if (control.failure != null) return denied(control.failure!);
    if (totalActive >= maxInFlight || _controls.contains(control)) {
      return denied(ExternalFailure.resourceLimit);
    }
    final slots = _active.putIfAbsent(session, () => <Object>{});
    if (slots.length >= maxInFlightPerSession) {
      return denied(ExternalFailure.resourceLimit);
    }
    final querySlot = Object();
    slots.add(querySlot);
    _controls.add(control);
    var entered = false;
    void releaseSlot() {
      slots.remove(querySlot);
      _controls.remove(control);
      if (slots.isEmpty) _active.remove(session);
    }

    try {
      final pending = operation.port.reconcile(context, submissionKey);
      entered = true;
      unawaited(pending.then<void>((_) => releaseSlot(),
          onError: (Object _, StackTrace __) => releaseSlot()));
      final settled = await Future.any<Object>([pending, control.interrupted]);
      if (settled is ExternalFailure) {
        return ExternalInvocationResult(
          phase: ExternalInvocationPhase.reconciliation,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: null,
          failure: settled,
          submissionKey: submissionKey,
        );
      }
      final evidence = settled as CapabilityEvidence<O>;
      final release = _authorize(
          session, context, operation, ExternalInvocationPhase.release,
          receiptRead: true);
      final releaseFailure = control.failure ??
          release ??
          (responseAvailable() ? null : ExternalFailure.responseLost);
      return ExternalInvocationResult(
        phase: ExternalInvocationPhase.reconciliation,
        status: evidence.status,
        effect: evidence.effect,
        failure: releaseFailure ??
            (evidence.failure == null ? null : ExternalFailure.handlerFailed),
        output: releaseFailure == null && evidence.failure == null
            ? evidence.output
            : null,
        submissionKey: submissionKey,
      );
    } catch (_) {
      return ExternalInvocationResult(
        phase: ExternalInvocationPhase.reconciliation,
        status: CapabilityExecutionStatus.outcomeUnknown,
        effect: null,
        failure: ExternalFailure.handlerFailed,
        submissionKey: submissionKey,
      );
    } finally {
      if (!entered) releaseSlot();
    }
  }
}
