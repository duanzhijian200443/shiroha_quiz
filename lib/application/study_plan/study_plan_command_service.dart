/// Application-level command service for SPL-1 StudyPlan adoption and stop.
///
/// Owns: formal draft adoption, transient beginCommit winner gate, injected
/// plan identity factory and clock, durable CAS execution via
/// [StudyPlanPersistencePort], marking draft committed on success, rollback
/// to pending on zero-mutation failure, and explicit stop command.
library;

import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import 'study_plan_draft_service.dart';
import 'study_plan_ports.dart';

/// Result of one formal adoption attempt on [StudyPlanCommandService].
sealed class StudyPlanAdoptResult {
  const StudyPlanAdoptResult();
}

/// The plan was successfully adopted and committed to durable storage.
final class StudyPlanAdoptResultSuccess extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultSuccess(this.activePlan);

  final ActiveStudyPlan activePlan;
}

/// The adoption parameters (e.g. invalid replacement confirmation pair) or
/// draft id are invalid.
final class StudyPlanAdoptResultInvalidPlan extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultInvalidPlan();
}

/// Another caller is already committing this draft.
final class StudyPlanAdoptResultBusy extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultBusy();
}

/// The source conversation, message, or project scope failed admission
/// revalidation during the adoption transaction.
final class StudyPlanAdoptResultStaleScope extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultStaleScope();
}

/// The target question bank is missing or empty.
final class StudyPlanAdoptResultTargetUnavailable extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultTargetUnavailable();
}

/// No-active CAS failed because an active plan already exists.
final class StudyPlanAdoptResultAlreadyActive extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultAlreadyActive();
}

/// Replacement CAS failed because the existing active plan id does not match
/// the expected plan id.
final class StudyPlanAdoptResultStaleActivePlan extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultStaleActivePlan();
}

/// The draft was superseded before adoption was acquired.
final class StudyPlanAdoptResultSuperseded extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultSuperseded();
}

/// The draft was rejected before adoption was acquired.
final class StudyPlanAdoptResultRejected extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultRejected();
}

/// The draft was already committed.
final class StudyPlanAdoptResultCommitted extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultCommitted();
}

/// An unexpected persistence failure occurred.
final class StudyPlanAdoptResultFailed extends StudyPlanAdoptResult {
  const StudyPlanAdoptResultFailed();
}

/// Result of one stop attempt on [StudyPlanCommandService].
sealed class StudyPlanStopResult {
  const StudyPlanStopResult();
}

/// The active plan was successfully stopped.
final class StudyPlanStopResultSuccess extends StudyPlanStopResult {
  const StudyPlanStopResultSuccess();
}

/// The plan to stop does not match the active plan or no active plan exists.
final class StudyPlanStopResultStaleActivePlan extends StudyPlanStopResult {
  const StudyPlanStopResultStaleActivePlan();
}

/// An unexpected failure occurred while stopping the active plan.
final class StudyPlanStopResultFailed extends StudyPlanStopResult {
  const StudyPlanStopResultFailed();
}

final class StudyPlanCommandService {
  StudyPlanCommandService({
    required StudyPlanDraftService draftService,
    required StudyPlanPersistencePort persistencePort,
    required String Function() planIdFactory,
    required DateTime Function() clock,
  })  : _draftService = draftService,
        _persistencePort = persistencePort,
        _planIdFactory = planIdFactory,
        _clock = clock;

  final StudyPlanDraftService _draftService;
  final StudyPlanPersistencePort _persistencePort;
  final String Function() _planIdFactory;
  final DateTime Function() _clock;

  /// Loads the durable active study plan, or null when no plan is active.
  Future<ActiveStudyPlan?> loadActivePlan() =>
      _persistencePort.loadActivePlan();

  /// Formally adopts a transient draft and commits it to durable persistence.
  ///
  /// Enforces:
  /// 1. Bounded parameter validation and replacement consistency;
  /// 2. Atomic transient `tryBeginCommit` winner acquisition;
  /// 3. In-transaction admission revalidation and SQLite CAS;
  /// 4. Terminal `markCommitted` on confirmed durable success;
  /// 5. Atomic `rollbackCommit` back to `pending` on zero-mutation failure.
  Future<StudyPlanAdoptResult> adoptDraft({
    required String draftId,
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) async {
    if (!_isBoundedId(draftId)) {
      return const StudyPlanAdoptResultInvalidPlan();
    }
    if (expectedActivePlanId != null) {
      if (!replacementConfirmed || !_isBoundedId(expectedActivePlanId)) {
        return const StudyPlanAdoptResultInvalidPlan();
      }
    } else {
      if (replacementConfirmed) {
        return const StudyPlanAdoptResultInvalidPlan();
      }
    }

    final StudyPlanDraft draft;
    try {
      draft = _draftService.draftById(draftId);
    } on ArgumentError {
      return const StudyPlanAdoptResultInvalidPlan();
    }

    // Fast-path inspection for terminal states
    if (draft.outcome == StudyPlanDraftOutcome.superseded) {
      return const StudyPlanAdoptResultSuperseded();
    }
    if (draft.outcome == StudyPlanDraftOutcome.rejected) {
      return const StudyPlanAdoptResultRejected();
    }
    if (draft.outcome == StudyPlanDraftOutcome.committed) {
      return const StudyPlanAdoptResultCommitted();
    }

    // Acquire transient commit gate: only winner gets acquired == true
    final commitGate = _draftService.tryBeginCommit(draftId);
    if (!commitGate.acquired) {
      return switch (commitGate.draft.outcome) {
        StudyPlanDraftOutcome.committing => const StudyPlanAdoptResultBusy(),
        StudyPlanDraftOutcome.superseded =>
          const StudyPlanAdoptResultSuperseded(),
        StudyPlanDraftOutcome.rejected => const StudyPlanAdoptResultRejected(),
        StudyPlanDraftOutcome.committed =>
          const StudyPlanAdoptResultCommitted(),
        StudyPlanDraftOutcome.pending => const StudyPlanAdoptResultBusy(),
      };
    }

    final newPlanId = _planIdFactory();
    final adoptedAt = _clock();

    try {
      final persistenceResult = await _persistencePort.commitAdoption(
        planId: newPlanId,
        bankName: draft.bankName,
        goal: draft.goal,
        dailyTarget: draft.dailyTarget,
        priority: draft.priority,
        horizonDays: draft.horizonDays,
        sourceConversationId: draft.sourceConversationId,
        sourceUserMessageId: draft.sourceMessageId,
        sourceScope: draft.sourceScope,
        adoptedAt: adoptedAt,
        expectedActivePlanId: expectedActivePlanId,
        replacementConfirmed: replacementConfirmed,
      );

      return switch (persistenceResult) {
        StudyPlanPersistenceCommitSuccess(:final activePlan) => () {
            _draftService.markCommitted(draftId);
            return StudyPlanAdoptResultSuccess(activePlan);
          }(),
        StudyPlanPersistenceCommitStaleScope() => () {
            _draftService.rollbackCommit(draftId);
            return const StudyPlanAdoptResultStaleScope();
          }(),
        StudyPlanPersistenceCommitTargetUnavailable() => () {
            _draftService.rollbackCommit(draftId);
            return const StudyPlanAdoptResultTargetUnavailable();
          }(),
        StudyPlanPersistenceCommitAlreadyActive() => () {
            _draftService.rollbackCommit(draftId);
            return const StudyPlanAdoptResultAlreadyActive();
          }(),
        StudyPlanPersistenceCommitStaleActivePlan() => () {
            _draftService.rollbackCommit(draftId);
            return const StudyPlanAdoptResultStaleActivePlan();
          }(),
        StudyPlanPersistenceCommitFailed() => () {
            _draftService.rollbackCommit(draftId);
            return const StudyPlanAdoptResultFailed();
          }(),
      };
    } catch (_) {
      _draftService.rollbackCommit(draftId);
      return const StudyPlanAdoptResultFailed();
    }
  }

  /// Formally stops the current active study plan.
  Future<StudyPlanStopResult> stopActivePlan({
    required String expectedPlanId,
  }) async {
    if (!_isBoundedId(expectedPlanId)) {
      return const StudyPlanStopResultStaleActivePlan();
    }
    try {
      final result = await _persistencePort.stopActivePlan(
        expectedPlanId: expectedPlanId,
      );
      return switch (result) {
        StudyPlanPersistenceStopSuccess() => const StudyPlanStopResultSuccess(),
        StudyPlanPersistenceStopStaleActivePlan() =>
          const StudyPlanStopResultStaleActivePlan(),
        StudyPlanPersistenceStopFailed() => const StudyPlanStopResultFailed(),
      };
    } catch (_) {
      return const StudyPlanStopResultFailed();
    }
  }

  static bool _isBoundedId(String value) {
    final length = value.runes.length;
    return length >= 1 && length <= 128 && !value.contains(' ');
  }
}
