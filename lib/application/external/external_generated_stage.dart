import 'dart:async';

import '../../domain/generated_question/generated_question_contract.dart';
import '../backup/backup_restore_gate.dart';
import '../capabilities/capability.dart';
import '../generated_question/generated_local_authority.dart';
import '../generated_question/generated_question_service.dart';
import 'external_authorization.dart';
import 'external_invocation_core.dart';
import 'external_trust_core.dart';

/// Narrow acknowledgement, never candidate content, Review or COMMIT authority.
final class ExternalStageSummary {
  const ExternalStageSummary(this.proposalId, this.submissionKey);
  final String proposalId, submissionKey;
}

final class ExternalStageResult {
  const ExternalStageResult(this.evidence, {this.failure, this.interruption});
  final CapabilityEvidence<ExternalStageSummary> evidence;
  final GeneratedFailure? failure;
  final ExternalFailure? interruption;
  CapabilityExecutionStatus get status => evidence.status;
  CapabilityEffect? get effect => evidence.effect;
  ExternalStageSummary? get output => evidence.output;
}

/// Only this service can mint access; a display id or another TrustCore's
/// Session cannot create it. The owning Data port rechecks durable policy.
final class ExternalStageAccess {
  ExternalStageAccess._(this._owner, this.session);
  final ExternalGeneratedStageService _owner;
  final ExternalSession session;
  String get profileId => session.principal.profileId;
  String get localOwner => _owner._localOwner.localOwner;
  void validate() => _owner._validateSession(session);
}

/// App-approved snapshot. No public constructor, wire decoder or boolean trust.
final class ExternalStageContext {
  ExternalStageContext._(this.access, this.target, this.evidence,
      this.grantRevision, this.expiresAt);
  final ExternalStageAccess access;
  final GeneratedTarget target;
  final List<GeneratedEvidence> evidence;
  final int grantRevision;
  final DateTime expiresAt;
  void validate() {
    access.validate();
    if (!access._owner._trust.clock.now().isBefore(expiresAt)) {
      generatedFail(GeneratedFailure.unauthorized);
    }
  }
}

/// SQL/transactions remain in the existing Proposal Data owner. These objects
/// prove runtime admission only; they cannot replace current SQLite checks.
abstract interface class ExternalGeneratedStagePort {
  Future<int> authorizeStage(ExternalStageAccess access, GeneratedTarget target,
      List<GeneratedEvidence> evidence);
  Future<ExternalStageSummary> publishExternalStage(
      GeneratedStageInput input,
      ExternalStageContext context,
      String? externalRequestId,
      ExternalCallControl control,
      CapabilityExecutionEvidence evidence);
  Future<ExternalStageSummary?> lookupExternalStage(
      ExternalStageAccess access, String submissionKey);
  Future<void> releaseExternalStage(
      ExternalStageAccess access, ExternalStageSummary result);
}

/// Unpublished Application/Data candidate. Construct only in App composition.
/// Local management binds a durable opaque reference to this TrustCore's exact
/// Principal. Credential proof, pairing and runtime enablement still precede
/// every Session. No CapabilityPrincipal.mcpStudyV0 adaptation exists here.
final class ExternalGeneratedStageService {
  ExternalGeneratedStageService({
    required ExternalTrustCore trust,
    required ExternalAuthorizationManagement management,
    required GeneratedLocalAuthoritySession localOwner,
    required ExternalGeneratedStagePort persistence,
    required GeneratedQuestionAdmission admission,
    this.maxInFlight = 16,
    this.maxInFlightPerSession = 4,
  })  : _trust = trust,
        _management = management,
        _localOwner = localOwner,
        _persistence = persistence,
        _admission = admission {
    if (maxInFlight < 1 || maxInFlightPerSession < 1) {
      throw ArgumentError('Invalid stage bounds');
    }
  }
  final ExternalTrustCore _trust;
  final ExternalAuthorizationManagement _management;
  final GeneratedLocalAuthoritySession _localOwner;
  final ExternalGeneratedStagePort _persistence;
  final GeneratedQuestionAdmission _admission;
  final int maxInFlight, maxInFlightPerSession;
  final _bindings = <ExternalPrincipal, ExternalProfileReference>{};
  final _active = <ExternalSession, int>{};
  final _controls = <ExternalCallControl>{};
  Completer<void>? _idle;
  bool _current = true;
  int get pendingCount => _controls.length;
  Future<void> get whenIdle => _idle?.future ?? Future.value();

  void close() => _current = false;
  void _validate() {
    try {
      BackupRestoreMutationGate.instance.ensureMutationAllowed();
    } catch (_) {
      generatedFail(GeneratedFailure.unauthorized);
    }
    if (!_current || !_localOwner.isCurrent) {
      generatedFail(GeneratedFailure.unauthorized);
    }
  }

  /// Trusted local binding, not an external call. A fresh runtime must select
  /// current durable metadata, prove credentials and bind afresh; history cannot
  /// recreate either the reference or the Principal.
  Future<void> bindIdentity(
      ExternalProfileReference reference, ExternalPrincipal principal) async {
    _validate();
    _trust.snapshot(principal); // rejects a Principal minted by another core
    final record = await _management.read(reference);
    _validate();
    _trust.snapshot(principal);
    if (principal.profileId != record.profile.clientProfileId ||
        record.profile.revokedAtUtcMs != null) {
      generatedFail(GeneratedFailure.unauthorized);
    }
    _bindings[principal] = reference;
  }

  void _validateSession(ExternalSession session) {
    _validate();
    if (_trust.sessionFailure(session) != null ||
        !_bindings.containsKey(session.principal)) {
      generatedFail(GeneratedFailure.unauthorized);
    }
  }

  ExternalStageAccess _access(ExternalSession session) {
    _validateSession(session);
    return ExternalStageAccess._(this, session);
  }

  /// App approval of the original Target/evidence only. No request permission,
  /// raw Profile id or client JSON enters this method. Fifteen minutes is an
  /// unpublished bounded candidate limit, independent of current Grant checks.
  Future<ExternalStageContext> approveTarget(ExternalSession session,
      GeneratedTarget target, Iterable<GeneratedEvidence> evidence) async {
    final access = _access(session);
    final snapshot = GeneratedTarget.fromJson(target.toJson());
    final sources = List<GeneratedEvidence>.unmodifiable(evidence);
    if (sources.length > 128 ||
        sources.map((e) => e.evidenceKey).toSet().length != sources.length) {
      generatedFail(GeneratedFailure.invalidEvidence);
    }
    for (final source in sources) {
      GeneratedEvidence.fromJson(source.toJson());
    }
    final revision =
        await _persistence.authorizeStage(access, snapshot, sources);
    access.validate();
    return ExternalStageContext._(access, snapshot, sources, revision,
        _trust.clock.now().add(const Duration(minutes: 15)));
  }

  Future<ExternalStageResult> stage({
    required ExternalSession session,
    required ExternalStageContext context,
    required String submissionJson,
    required ExternalCallControl control,
    required bool Function() responseAvailable,
    String? externalRequestId,
  }) {
    late final GeneratedStageInput input;
    try {
      if (!identical(context.access._owner, this) ||
          !identical(context.access.session, session)) {
        generatedFail(GeneratedFailure.unauthorized);
      }
      context.validate();
      if (externalRequestId != null &&
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
              .hasMatch(externalRequestId)) {
        generatedFail(GeneratedFailure.invalidSubmission);
      }
      input = _admission.admitContent(submissionJson, context.evidence);
    } on GeneratedQuestionException catch (e) {
      return Future.value(_rejected(e.failure));
    }
    return _run(session, control, responseAvailable, (confirmed) async {
      try {
        context.validate();
        final current = await _persistence.authorizeStage(
            context.access, context.target, context.evidence);
        context.validate();
        if (current != context.grantRevision) {
          generatedFail(GeneratedFailure.unauthorized);
        }
      } catch (_) {
        confirmed.confirm(CapabilityEffect.none);
        rethrow;
      }
      return _persistence.publishExternalStage(
          input, context, externalRequestId, control, confirmed);
    });
  }

  /// Current authentication + original Profile/key, with no generation Context
  /// or old process journal. Absence is deliberately outcome_unknown: a queued
  /// handler in this or another runtime may still publish after the read.
  Future<ExternalStageResult> reconcile({
    required ExternalSession session,
    required String submissionKey,
    required ExternalCallControl control,
    required bool Function() responseAvailable,
  }) =>
      _run(session, control, responseAvailable, (confirmed) async {
        generatedToken(submissionKey);
        final result = await _persistence.lookupExternalStage(
            _access(session), submissionKey);
        if (result != null) confirmed.confirm(CapabilityEffect.proposalStaged);
        return result;
      });

  ExternalStageResult _rejected(GeneratedFailure failure) =>
      ExternalStageResult(
          const CapabilityEvidence(
              status: CapabilityExecutionStatus.notStarted,
              effect: CapabilityEffect.none),
          failure: failure);

  Future<ExternalStageResult> _run(
      ExternalSession session,
      ExternalCallControl control,
      bool Function() responseAvailable,
      Future<ExternalStageSummary?> Function(CapabilityExecutionEvidence)
          handler) async {
    try {
      _validateSession(session);
    } catch (_) {
      return _rejected(GeneratedFailure.unauthorized);
    }
    if (control.failure != null) {
      return ExternalStageResult(
          const CapabilityEvidence(
              status: CapabilityExecutionStatus.notStarted,
              effect: CapabilityEffect.none),
          interruption: control.failure);
    }
    if (pendingCount >= maxInFlight ||
        (_active[session] ?? 0) >= maxInFlightPerSession ||
        !_controls.add(control)) {
      return _rejected(GeneratedFailure.resourceLimit);
    }
    if (pendingCount == 1) _idle = Completer<void>();
    _active[session] = (_active[session] ?? 0) + 1;
    final confirmed = CapabilityExecutionEvidence();
    final pending = () async {
      try {
        final output = await handler(confirmed);
        if (output == null || !responseAvailable()) {
          return ExternalStageResult(
              CapabilityEvidence(
                  status: CapabilityExecutionStatus.outcomeUnknown,
                  effect: confirmed.knownEffect),
              interruption:
                  output == null ? null : ExternalFailure.responseLost);
        }
        await _persistence.releaseExternalStage(_access(session), output);
        _validateSession(session);
        if (control.failure != null || !responseAvailable()) {
          return ExternalStageResult(
              CapabilityEvidence(
                  status: CapabilityExecutionStatus.outcomeUnknown,
                  effect: confirmed.knownEffect),
              interruption: control.failure ?? ExternalFailure.responseLost);
        }
        return ExternalStageResult(CapabilityEvidence.completed(
            output, CapabilityEffect.proposalStaged));
      } on GeneratedQuestionException catch (e) {
        return ExternalStageResult(
            CapabilityEvidence(
                status: confirmed.knownEffect == CapabilityEffect.none
                    ? CapabilityExecutionStatus.failedWithoutEffect
                    : CapabilityExecutionStatus.outcomeUnknown,
                effect: confirmed.knownEffect),
            failure: e.failure);
      } catch (_) {
        return ExternalStageResult(CapabilityEvidence(
            status: CapabilityExecutionStatus.outcomeUnknown,
            effect: confirmed.knownEffect));
      } finally {
        _controls.remove(control);
        if (_controls.isEmpty) {
          _idle?.complete();
          _idle = null;
        }
        final remaining = _active[session]! - 1;
        if (remaining == 0) {
          _active.remove(session);
        } else {
          _active[session] = remaining;
        }
      }
    }();
    // Caller interruption never frees the resource held by unfinished work.
    return Future.any([
      pending,
      control.interrupted.then((failure) => ExternalStageResult(
          CapabilityEvidence(
              status: CapabilityExecutionStatus.outcomeUnknown,
              effect: confirmed.knownEffect),
          interruption: failure)),
    ]);
  }
}
