/// Protocol-neutral Application capability semantics. No transport or model DTOs.
library;

import 'dart:async';
import 'dart:math';

import '../../domain/conversations/conversation.dart';
import '../retrieval/retrieval_egress_grant.dart';
import '../retrieval/retrieval_ports.dart';
import '../external/external_authorization.dart';
import '../external/external_generated_stage.dart';
import '../external/external_file_read.dart';
import '../external/external_invocation_core.dart';
import '../external/external_question_read.dart';
import '../external/external_read_context.dart';
import '../external/external_runtime_admission.dart';
import '../external/external_trust_core.dart';
import '../../domain/generated_question/generated_question_contract.dart';

part 'external_capabilities.dart';

enum CapabilityPermission { read, stage, commit, destructive }

enum CapabilityEffect { none, derivedCache, proposalStaged, formalMutation }

enum CapabilityExecutionStatus {
  notStarted,
  completed,
  failedWithoutEffect,
  outcomeUnknown
}

enum CapabilityExecutionSemantics {
  /// Each invocation requires fresh authorization, scope and egress checks.
  repeatableRead,

  /// Never repeated automatically; reconciliation only in the owning process.
  transientStage,

  /// No automatic repetition; reconcile against the owning durable Proposal.
  durableStage,
}

enum CapabilityFailure {
  invalidRequest,
  unknownCapability,
  accessDenied,
  budgetDenied,
  cancelled,
  deadlineExceeded,
  notFound,
  dataCorrupt,
  temporarilyUnavailable,
  internalError,
  ineligible,
  invalidPlan,
  targetUnavailable,
  encodingFailed,
  retrievalAccessDenied,
  retrievalScopeEmpty,
  retrievalScopeUnavailable,
  retrievalSourceChanged,
  retrievalTemporarilyUnavailable,
  retrievalInternalError,
  externalResponseLost,
  externalReadDenied,
  externalReadStale,
  externalReadResourceLimit,
  externalReadUnavailable,
  externalReadInvalidRequest,
  externalReadDataCorrupt,
  externalReadSourceNotReady,
  generatedInvalidSubmission,
  generatedUnsupportedContent,
  generatedUnsafePayload,
  generatedResourceLimit,
  generatedInvalidEvidence,
  generatedUnauthorized,
  generatedTargetChanged,
  generatedProposalUnavailable,
  generatedStaleRevision,
  generatedTerminalConflict,
  generatedIdempotencyConflict,
  generatedDuplicateContent,
  generatedReviewIncomplete,
  generatedQualityBlocked,
  generatedStaleEvidence,
  generatedInvalidEdit,
  generatedCorruptState,
  generatedPersistenceFailed,
}

enum CapabilityPrincipal { builtInAgent, mcpStudyV0, denied, external }

final class CapabilityId<I, O> {
  const CapabilityId(this.value);
  final String value;
  Type get inputType => I;
  Type get outputType => O;
  @override
  bool operator ==(Object other) =>
      other is CapabilityId &&
      value == other.value &&
      inputType == other.inputType &&
      outputType == other.outputType;
  @override
  int get hashCode => Object.hash(value, inputType, outputType);
}

/// Constructor values are supplied by trusted Application entrypoints only.
/// Permission/scope/grant values are never parsed from tool arguments.
final class CapabilityContext {
  CapabilityContext({
    required this.principal,
    required Iterable<CapabilityId> capabilities,
    required Iterable<CapabilityPermission> permissions,
    required this.scope,
    required this.authorizedScope,
    this.authorizationCurrent,
    this.budgetAllowed,
    this.isCancelled,
    this.cancellationSignal,
    this.deadline,
    this.sourceConversationId,
    this.sourceMessageId,
    this.turnRequestId,
    this.providerProfileId,
    this.retrievalGrant,
    Iterable<String> currentFileIds = const [],
    this.serializationAllowed,
    this.proposalResultFits,
  })  : capabilities = Set.unmodifiable(capabilities),
        permissions = Set.unmodifiable(permissions),
        currentFileIds = List.unmodifiable(currentFileIds),
        _externalCall = null {
    if (principal == CapabilityPrincipal.external) {
      throw ArgumentError('External contexts require authenticated admission.');
    }
  }

  CapabilityContext._external(_ExternalCapabilityCall call)
      : principal = CapabilityPrincipal.external,
        capabilities = call.context.capabilities,
        permissions = call.context.authorization.permissions,
        scope = call.context.scope,
        authorizedScope = call.context.scope,
        authorizationCurrent = call.authorize,
        budgetAllowed = null,
        isCancelled = null,
        cancellationSignal = null,
        deadline = null,
        sourceConversationId = null,
        sourceMessageId = null,
        turnRequestId = null,
        providerProfileId = null,
        retrievalGrant = null,
        currentFileIds = const [],
        serializationAllowed = null,
        proposalResultFits = null,
        _externalCall = call;
  final _ExternalCapabilityCall? _externalCall;
  final CapabilityPrincipal principal;
  final Set<CapabilityId> capabilities;
  final Set<CapabilityPermission> permissions;
  final ConversationScope scope;
  final ConversationScope authorizedScope;
  final Future<bool> Function()? authorizationCurrent;
  final bool Function()? budgetAllowed;
  final bool Function()? isCancelled;
  final Future<void>? cancellationSignal;
  final DateTime? deadline;
  final String? sourceConversationId;
  final String? sourceMessageId;
  final String? turnRequestId;
  final String? providerProfileId;
  final RetrievalEgressGrant? retrievalGrant;
  final List<String> currentFileIds;
  final Future<bool> Function()? serializationAllowed;

  /// Optional pre-activation release-size admission. The semantic handler
  /// supplies its exact typed proposal; the projection owns byte encoding.
  final bool Function(Object candidate)? proposalResultFits;

  bool get executionAllowed =>
      !(isCancelled?.call() ?? false) &&
      (deadline == null || DateTime.now().isBefore(deadline!)) &&
      (budgetAllowed?.call() ?? true);
  bool get scopeMatches =>
      scope.kind == authorizedScope.kind &&
      scope.projectId == authorizedScope.projectId &&
      !scope.isUnavailableLearningSpace;
}

/// Opaque process-local lifecycle reference. Equality of an artifact id across
/// processes does not make this reference valid in a new service instance.
final class TransientReconciliationReference {
  const TransientReconciliationReference(
      {required Object owner, required this.artifactId})
      : _owner = owner;
  final Object _owner;
  final String artifactId;
  bool belongsTo(Object lifecycle) => identical(_owner, lifecycle);
}

/// Correlation only, never a permission or a second persisted Receipt.
/// A fresh authenticated invocation uses the Proposal owner's original key.
final class DurableStageReconciliationReference {
  const DurableStageReconciliationReference(
      {required this.profileId, required this.submissionKey});
  final String profileId, submissionKey;
}

/// Trusted source references and private external authorization metadata.
/// Never request identity declarations or credential material.
final class CapabilityAuthorizationReferences {
  const CapabilityAuthorizationReferences(
      {this.turnRequestId,
      this.conversationId,
      this.sourceMessageId,
      this.providerProfileId,
      this.external});
  final String? turnRequestId;
  final String? conversationId;
  final String? sourceMessageId;
  final String? providerProfileId;
  final ExternalCapabilityAuthorization? external;
}

final class ExecutionReceipt {
  const ExecutionReceipt(
      {required this.executionId,
      required this.capabilityId,
      required this.status,
      required this.knownEffect,
      required this.principal,
      required this.scope,
      required this.authorization,
      this.failure,
      this.reconciliation,
      this.durableReconciliation});
  final String executionId;
  final CapabilityId capabilityId;
  final CapabilityExecutionStatus status;

  /// null means unknown, never proof of zero effect.
  final CapabilityEffect? knownEffect;
  final CapabilityFailure? failure;
  final CapabilityPrincipal principal;
  final ConversationScope scope;
  final CapabilityAuthorizationReferences authorization;
  final TransientReconciliationReference? reconciliation;
  final DurableStageReconciliationReference? durableReconciliation;

  ExecutionReceipt withFailure(CapabilityFailure code) => ExecutionReceipt(
      executionId: executionId,
      capabilityId: capabilityId,
      status: status,
      knownEffect: knownEffect,
      principal: principal,
      scope: scope,
      authorization: authorization,
      failure: code,
      reconciliation: reconciliation,
      durableReconciliation: durableReconciliation);
}

/// Evidence supplied by the owning handler/service, before egress/encoding.
final class CapabilityEvidence<O> {
  const CapabilityEvidence(
      {this.output,
      this.failure,
      required this.status,
      required this.effect,
      this.reconciliation,
      this.durableReconciliation});
  final O? output;
  final CapabilityFailure? failure;
  final CapabilityExecutionStatus status;
  final CapabilityEffect? effect;
  final TransientReconciliationReference? reconciliation;
  final DurableStageReconciliationReference? durableReconciliation;
  factory CapabilityEvidence.completed(O output, CapabilityEffect effect,
          {TransientReconciliationReference? reconciliation}) =>
      CapabilityEvidence(
          output: output,
          status: CapabilityExecutionStatus.completed,
          effect: effect,
          reconciliation: reconciliation);
  factory CapabilityEvidence.zeroEffectFailure(CapabilityFailure failure) =>
      CapabilityEvidence(
          failure: failure,
          status: CapabilityExecutionStatus.failedWithoutEffect,
          effect: CapabilityEffect.none);
}

final class CapabilityResult<O> {
  const CapabilityResult(
      {this.output, this.failure, required this.receipt, this.readReuse});
  final O? output;
  final CapabilityFailure? failure;
  final ExecutionReceipt receipt;
  final CapabilityReadReuse? readReuse;
  CapabilityResult<O> withReleaseFailure(CapabilityFailure code) =>
      CapabilityResult(failure: code, receipt: receipt.withFailure(code));
}

/// Process-local proof minted only by the executor for one resolved READ.
/// Rechecks admission and release for a new recipient without invoking a handler.
final class CapabilityReadReuse {
  CapabilityReadReuse._(this._receipt, this._authorize);
  final ExecutionReceipt _receipt;
  final Future<bool> Function(CapabilityContext) _authorize;

  Future<bool> permits(
      ExecutionReceipt receipt, CapabilityContext target) async {
    if (!identical(receipt, _receipt)) return false;
    try {
      return await _authorize(target);
    } catch (_) {
      return false;
    }
  }
}

/// Only owning handlers record confirmed effects. Exceptions/timeouts never
/// turn absence of evidence into proof of none.
final class CapabilityExecutionEvidence {
  CapabilityExecutionEvidence({this.onConfirmed});
  final void Function(CapabilityEffect)? onConfirmed;
  CapabilityEffect? knownEffect;
  TransientReconciliationReference? reconciliation;
  DurableStageReconciliationReference? durableReconciliation;
  void confirm(CapabilityEffect effect,
      {TransientReconciliationReference? reference}) {
    knownEffect = effect;
    reconciliation = reference;
    onConfirmed?.call(effect);
  }
}

final class CapabilityHandler<I, O> {
  const CapabilityHandler(this.invoke);
  final Future<CapabilityEvidence<O>> Function(I input,
      CapabilityContext context, CapabilityExecutionEvidence evidence) invoke;
  Type get inputType => I;
  Type get outputType => O;
}

final class CapabilityDefinition<I, O> {
  CapabilityDefinition(
      {required this.id,
      required this.permission,
      required Iterable<CapabilityEffect> permittedEffects,
      required this.semantics,
      required this.handler,
      this.admit,
      this.authorize,
      this.release})
      : permittedEffects = Set.unmodifiable(permittedEffects) {
    if (id.inputType != I ||
        id.outputType != O ||
        handler.inputType != I ||
        handler.outputType != O) {
      throw ArgumentError('Capability binding type mismatch.');
    }
  }
  final CapabilityId<I, O> id;
  final CapabilityPermission permission;
  final Set<CapabilityEffect> permittedEffects;
  final CapabilityExecutionSemantics semantics;
  final CapabilityHandler<I, O> handler;
  final CapabilityFailure? Function(I input)? admit;
  final Future<bool> Function(I input, CapabilityContext context)? authorize;
  final Future<bool> Function(I input, CapabilityContext context)? release;
}

final class ApplicationCapabilityRegistry {
  ApplicationCapabilityRegistry(Iterable<CapabilityDefinition> registrations)
      : definitions = List.unmodifiable(registrations) {
    final bindings = <String, CapabilityDefinition>{};
    for (final definition in definitions) {
      if (bindings.containsKey(definition.id.value)) {
        throw ArgumentError('Duplicate capability identity.');
      }
      if (definition.id.inputType != definition.handler.inputType ||
          definition.id.outputType != definition.handler.outputType) {
        throw ArgumentError('Capability binding type mismatch.');
      }
      bindings[definition.id.value] = definition;
    }
    _bindings = Map.unmodifiable(bindings);
  }
  final List<CapabilityDefinition> definitions;
  late final Map<String, CapabilityDefinition> _bindings;
  CapabilityDefinition<I, O>? definition<I, O>(CapabilityId<I, O> id) {
    final binding = _bindings[id.value];
    if (binding == null) return null;
    if (binding.id != id || binding is! CapabilityDefinition<I, O>) {
      throw ArgumentError('Capability binding type mismatch.');
    }
    return binding;
  }
}

final class CapabilityExecutor {
  CapabilityExecutor(this.registry);
  final ApplicationCapabilityRegistry registry;
  static final _identityRandom = Random.secure();

  static String _newExecutionId() {
    final bytes = List.generate(16, (_) => _identityRandom.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  CapabilityResult<O> reject<I, O>(CapabilityId<I, O> id,
          CapabilityContext context, CapabilityFailure failure) =>
      CapabilityResult(
          failure: failure,
          receipt: _receipt(
              id,
              context,
              CapabilityEvidence<O>(
                  failure: failure,
                  status: CapabilityExecutionStatus.notStarted,
                  effect: CapabilityEffect.none)));

  ExecutionReceipt _receipt(CapabilityId id, CapabilityContext context,
          CapabilityEvidence evidence) =>
      ExecutionReceipt(
          executionId: _newExecutionId(),
          capabilityId: id,
          status: evidence.status,
          knownEffect: evidence.effect,
          failure: evidence.failure,
          principal: context.principal,
          scope: context.scope,
          authorization: CapabilityAuthorizationReferences(
              turnRequestId: context.turnRequestId,
              conversationId: context.sourceConversationId,
              sourceMessageId: context.sourceMessageId,
              providerProfileId: context.providerProfileId,
              external: context._externalCall?.context.authorization),
          reconciliation: evidence.reconciliation,
          durableReconciliation: evidence.durableReconciliation);

  Future<CapabilityResult<O>> execute<I, O>(
      CapabilityId<I, O> id, I input, CapabilityContext context) async {
    final definition = registry.definition(id);
    if (definition == null) {
      return reject(id, context, CapabilityFailure.unknownCapability);
    }
    final externalInterruption = context._externalCall?.interruption;
    if (externalInterruption != null) {
      return reject(id, context, externalInterruption);
    }
    try {
      final admission = definition.admit?.call(input);
      if (admission != null) return reject(id, context, admission);
    } catch (_) {
      return reject(id, context, CapabilityFailure.invalidRequest);
    }
    try {
      final authorized = await _bounded(
          () async =>
              context.principal != CapabilityPrincipal.denied &&
              context.capabilities.contains(id) &&
              context.permissions.contains(definition.permission) &&
              context.scopeMatches &&
              (await context.authorizationCurrent?.call() ?? true) &&
              (await definition.authorize?.call(input, context) ?? true),
          context);
      if (!authorized) {
        return reject(id, context, CapabilityFailure.accessDenied);
      }
    } on _CapabilityInterrupted catch (error) {
      return reject(id, context, error.failure);
    } catch (_) {
      return reject(id, context, CapabilityFailure.accessDenied);
    }
    if (context.isCancelled?.call() ?? false) {
      return reject(id, context, CapabilityFailure.cancelled);
    }
    final beforeHandlerInterruption = context._externalCall?.interruption;
    if (beforeHandlerInterruption != null) {
      return reject(id, context, beforeHandlerInterruption);
    }
    if (context.deadline != null &&
        !DateTime.now().isBefore(context.deadline!)) {
      return reject(id, context, CapabilityFailure.deadlineExceeded);
    }
    if (!(context.budgetAllowed?.call() ?? true)) {
      return reject(id, context, CapabilityFailure.budgetDenied);
    }

    CapabilityEvidence<O> evidence;
    final confirmed = CapabilityExecutionEvidence();
    var handlerEntered = false;
    try {
      // Cancellation, timeout and unclassified throws cannot prove rollback.
      evidence = await _bounded(() {
        handlerEntered = true;
        return definition.handler.invoke(input, context, confirmed);
      }, context, delegatedExternalHandler: true);
    } on _CapabilityInterrupted catch (error) {
      evidence = CapabilityEvidence(
          failure: error.failure,
          status: handlerEntered
              ? CapabilityExecutionStatus.outcomeUnknown
              : CapabilityExecutionStatus.notStarted,
          effect:
              handlerEntered ? confirmed.knownEffect : CapabilityEffect.none,
          reconciliation: confirmed.reconciliation,
          durableReconciliation: confirmed.durableReconciliation);
    } catch (_) {
      evidence = CapabilityEvidence(
          failure: CapabilityFailure.internalError,
          status: CapabilityExecutionStatus.outcomeUnknown,
          effect: confirmed.knownEffect,
          reconciliation: confirmed.reconciliation,
          durableReconciliation: confirmed.durableReconciliation);
    }
    if (evidence.effect != null &&
        !definition.permittedEffects.contains(evidence.effect)) {
      return CapabilityResult(
          failure: CapabilityFailure.internalError,
          receipt: _receipt(
              id,
              context,
              CapabilityEvidence<O>(
                  failure: CapabilityFailure.internalError,
                  status: CapabilityExecutionStatus.outcomeUnknown,
                  effect: evidence.effect,
                  reconciliation: evidence.reconciliation,
                  durableReconciliation: evidence.durableReconciliation)));
    }
    final receipt = _receipt(id, context, evidence);
    final result = CapabilityResult<O>(
        output: evidence.output, failure: evidence.failure, receipt: receipt);
    if (evidence.output == null || evidence.failure != null) {
      return _withReadReuse(definition, input, context, result);
    }
    try {
      final allowed = await _bounded(
          () async =>
              context.executionAllowed &&
              (await context.authorizationCurrent?.call() ?? true) &&
              (await definition.release?.call(input, context) ?? true),
          context);
      if (!allowed) {
        return result.withReleaseFailure(CapabilityFailure.accessDenied);
      }
    } on _CapabilityInterrupted catch (error) {
      return result.withReleaseFailure(error.failure);
    } catch (_) {
      return result.withReleaseFailure(CapabilityFailure.accessDenied);
    }

    return _withReadReuse(definition, input, context, result);
  }

  CapabilityResult<O> _withReadReuse<I, O>(
      CapabilityDefinition<I, O> definition,
      I input,
      CapabilityContext original,
      CapabilityResult<O> result) {
    final receipt = result.receipt;
    if (original.principal != CapabilityPrincipal.builtInAgent ||
        definition.permission != CapabilityPermission.read ||
        definition.semantics != CapabilityExecutionSemantics.repeatableRead ||
        (receipt.status != CapabilityExecutionStatus.completed &&
            receipt.status != CapabilityExecutionStatus.failedWithoutEffect) ||
        (receipt.status == CapabilityExecutionStatus.failedWithoutEffect &&
            receipt.knownEffect != CapabilityEffect.none) ||
        (receipt.knownEffect != CapabilityEffect.none &&
            receipt.knownEffect != CapabilityEffect.derivedCache) ||
        !definition.permittedEffects.contains(receipt.knownEffect) ||
        (receipt.failure != null &&
            receipt.failure != CapabilityFailure.notFound &&
            receipt.failure != CapabilityFailure.invalidRequest &&
            receipt.failure != CapabilityFailure.dataCorrupt &&
            receipt.failure != CapabilityFailure.temporarilyUnavailable)) {
      return result;
    }
    return CapabilityResult(
        output: result.output,
        failure: result.failure,
        receipt: receipt,
        readReuse: CapabilityReadReuse._(receipt, (target) async {
          if (target.principal != original.principal ||
              target.turnRequestId == null ||
              target.turnRequestId != original.turnRequestId ||
              target.sourceConversationId == null ||
              target.sourceConversationId != original.sourceConversationId ||
              target.sourceMessageId == null ||
              target.sourceMessageId != original.sourceMessageId ||
              target.providerProfileId == null ||
              target.scope.kind != receipt.scope.kind ||
              target.scope.projectId != receipt.scope.projectId ||
              !target.scopeMatches ||
              !target.executionAllowed ||
              !target.capabilities.contains(definition.id) ||
              !target.permissions.contains(CapabilityPermission.read)) {
            return false;
          }
          return _bounded(
              () async =>
                  definition.admit?.call(input) == null &&
                  (await original.authorizationCurrent?.call() ?? true) &&
                  (await target.authorizationCurrent?.call() ?? true) &&
                  (await definition.authorize?.call(input, target) ?? true) &&
                  (await definition.release?.call(input, target) ?? true) &&
                  target.executionAllowed,
              target);
        }));
  }

  Future<T> _bounded<T>(Future<T> Function() action, CapabilityContext context,
      {bool delegatedExternalHandler = false}) async {
    final externalInterruption = context._externalCall?.interruption;
    if (externalInterruption != null) {
      throw _CapabilityInterrupted(externalInterruption);
    }
    if (context.isCancelled?.call() ?? false) {
      throw const _CapabilityInterrupted(CapabilityFailure.cancelled);
    }
    if (context.deadline != null &&
        !DateTime.now().isBefore(context.deadline!)) {
      throw const _CapabilityInterrupted(CapabilityFailure.deadlineExceeded);
    }
    Timer? timer;
    var settled = false;
    final interrupted = Completer<T>();
    void interrupt(CapabilityFailure failure) {
      if (!settled && !interrupted.isCompleted) {
        interrupted.completeError(_CapabilityInterrupted(failure));
      }
    }

    try {
      final pending = action();
      if (context.deadline != null) {
        timer = Timer(context.deadline!.difference(DateTime.now()),
            () => interrupt(CapabilityFailure.deadlineExceeded));
      }
      context.cancellationSignal
          ?.then((_) => interrupt(CapabilityFailure.cancelled));
      if (!delegatedExternalHandler) {
        context._externalCall?.control.interrupted
            .then((failure) => interrupt(_externalInterruption(failure)!));
      }
      return await Future.any([pending, interrupted.future]);
    } finally {
      settled = true;
      timer?.cancel();
    }
  }
}

final class _CapabilityInterrupted implements Exception {
  const _CapabilityInterrupted(this.failure);
  final CapabilityFailure failure;
}
