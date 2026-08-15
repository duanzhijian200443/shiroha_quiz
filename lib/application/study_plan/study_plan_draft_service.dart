/// Transient SPL-1 `StudyPlanDraft` service.
///
/// Owns: canonical normalization/validation, planning admission/read,
/// deterministic preview construction, draft identity, semantic fingerprint
/// replay dedup, the one-active/pending-draft-per-source-turn rule,
/// explicit Reject, pending supersession, the atomic `beginCommit` gate, and
/// the commit-success terminal marking seam for SPL-1-D1.
///
/// D0 performs zero durable writes: no plan row, no schema v22, no adoption
/// transaction. The durable `ActiveStudyPlan` concurrency authority (SQLite
/// transaction-level CAS) is a D1 concern; only `pending -> committing` may
/// gate the future formal adoption transaction.
///
/// ### Atomicity invariant
///
/// No `await` may split the lifecycle check-and-transition path: every map
/// read and write of the activation block and the shared transition gate is
/// synchronous, so each competes atomically from the service perspective on
/// the single-threaded event loop. The only awaited operation is the
/// planning admission read, which precedes the synchronous activation block.
library;

import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import 'study_plan_ports.dart';
import 'study_plan_preview_builder.dart';

/// Result of one staging attempt.
sealed class StudyPlanStageResult {
  const StudyPlanStageResult();
}

/// The draft is active: a fresh pending draft, or the existing draft with
/// its current outcome on a semantic replay. The outcome field distinguishes
/// the two; terminal outcomes are never reactivated.
final class StudyPlanStageResultStaged extends StudyPlanStageResult {
  const StudyPlanStageResultStaged(this.draft);

  final StudyPlanDraft draft;
}

/// The planning admission denied the target. Shared bounded non-enumerating
/// shape; carries no target identity or content.
final class StudyPlanStageResultUnavailable extends StudyPlanStageResult {
  const StudyPlanStageResultUnavailable();
}

/// The source turn already has a draft in `committing` state. Bounded
/// non-mutating response: nothing is superseded and no second active/pending
/// draft is created.
final class StudyPlanStageResultBusy extends StudyPlanStageResult {
  const StudyPlanStageResultBusy();
}

/// The plan fields or source identity failed canonical validation. Zero
/// state change.
final class StudyPlanStageResultInvalid extends StudyPlanStageResult {
  const StudyPlanStageResultInvalid();
}

/// This invocation no longer owns the latest proposal intent for its source
/// turn: a newer different proposal was staged while this call's planning
/// read was in flight. Bounded non-mutating result: zero draft creation,
/// zero supersession, zero lifecycle mutation.
final class StudyPlanStageResultStale extends StudyPlanStageResult {
  const StudyPlanStageResultStale();
}

/// Result of an attempt to acquire the transient commit gate on a draft.
final class StudyPlanBeginCommitResult {
  const StudyPlanBeginCommitResult({
    required this.draft,
    required this.acquired,
  });

  final StudyPlanDraft draft;
  final bool acquired;
}

final class StudyPlanDraftService {
  StudyPlanDraftService({
    required StudyPlanPlanningPort planningPort,
    required String Function() draftIdFactory,
    required DateTime Function() clock,
  })  : _planningPort = planningPort,
        _draftIdFactory = draftIdFactory,
        _clock = clock;

  final StudyPlanPlanningPort _planningPort;
  final String Function() _draftIdFactory;
  final DateTime Function() _clock;
  static const StudyPlanPreviewBuilder _previewBuilder =
      StudyPlanPreviewBuilder();

  final Map<String, StudyPlanDraft> _draftsById = {};
  final Map<StudyPlanDraftFingerprint, String> _draftIdByFingerprint = {};
  final Map<String, String> _activeDraftIdByTurn = {};

  /// Latest per-turn proposal intent. A newer DIFFERENT fingerprint advances
  /// the generation; same-fingerprint calls share the generation so they
  /// never fight as different revisions.
  final Map<String, ({int generation, StudyPlanDraftFingerprint fingerprint})>
      _intentByTurn = {};

  /// Stages one plan draft for a trusted Application caller.
  ///
  /// Source identity and scope are parameters, never fields of a generic
  /// plan payload map. The Agent parser/wiring is a later SPL-1-I0 concern.
  ///
  /// Ordering invariants:
  ///
  /// 1. trusted source validation + canonical normalization;
  /// 2. fingerprint computed BEFORE any planning read;
  /// 3. an existing fingerprint returns the stored draft/current outcome
  ///    immediately — replay never re-admits, never re-reads planning, and
  ///    never rebuilds the preview (staging authority was established when
  ///    the draft was created; fresh authority is revalidated at D1
  ///    adoption);
  /// 4. the call reserves the latest per-turn proposal intent;
  /// 5. after the planning read, the call re-checks the fingerprint (a
  ///    same-intent call may already have activated it) and verifies it
  ///    still owns the latest intent before any lifecycle mutation — an
  ///    older proposal whose read finished later performs zero mutation.
  ///
  /// Throws [StudyPlanException] only for infrastructure read failures
  /// (`temporarilyUnavailable`); plan-level outcomes are sealed results.
  Future<StudyPlanStageResult> stage({
    required String sourceConversationId,
    required String sourceMessageId,
    required ConversationScope sourceScope,
    required String bankName,
    String? goal,
    int? dailyTarget,
    StudyPlanPriority? priority,
    int? horizonDays,
  }) async {
    if (!_isBoundedId(sourceConversationId) || !_isBoundedId(sourceMessageId)) {
      return const StudyPlanStageResultInvalid();
    }
    final StudyPlanInput plan;
    try {
      plan = StudyPlanInput.normalize(
        bankName: bankName,
        goal: goal,
        dailyTarget: dailyTarget,
        priority: priority,
        horizonDays: horizonDays,
      );
    } on StudyPlanValidationException {
      return const StudyPlanStageResultInvalid();
    }

    final turnKey = _turnKey(sourceConversationId, sourceMessageId);
    final fingerprint = StudyPlanDraftFingerprint(
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      sourceScope: sourceScope,
      operationKind: StudyPlanOperationKind.proposeStudyPlan,
      plan: plan,
    );
    // P2-C: semantic replay returns before any fresh planning read.
    final existingId = _draftIdByFingerprint[fingerprint];
    if (existingId != null) {
      return StudyPlanStageResultStaged(_draftsById[existingId]!);
    }
    // P2-A: reserve the latest proposal intent for this source turn before
    // the awaited read, so completion order can never win over intent order.
    final generation = _reserveIntent(turnKey, fingerprint);

    // The only awaited read of this method. All lifecycle mutations below
    // are synchronous.
    final StudyPlanPlanningAdmission admission;
    try {
      admission = await _planningPort.loadPlanningContext(
        sourceScope: sourceScope,
        bankName: plan.bankName,
        now: _clock(),
      );
    } on StudyPlanReadException {
      throw const StudyPlanException(StudyPlanFailure.temporarilyUnavailable);
    }
    final StudyPlanPlanningContext? context = switch (admission) {
      StudyPlanPlanningAdmitted(:final context) => context,
      StudyPlanPlanningUnavailable() => null,
    };
    if (context == null) return const StudyPlanStageResultUnavailable();

    final preview = _previewBuilder.build(plan: plan, context: context);
    return _activateAfterRead(
      plan: plan,
      preview: preview,
      fingerprint: fingerprint,
      generation: generation,
      turnKey: turnKey,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      sourceScope: sourceScope,
    );
  }

  /// Explicit Reject through the shared lifecycle gate.
  ///
  /// Synchronous and atomic: only a `pending` draft transitions to
  /// `rejected`; any other outcome is returned unchanged.
  StudyPlanDraft rejectDraft(String draftId) {
    return _transition(
      _requireDraft(draftId),
      from: StudyPlanDraftOutcome.pending,
      to: StudyPlanDraftOutcome.rejected,
    );
  }

  /// Transient adoption-entry gate: `pending -> committing`.
  ///
  /// Synchronous and atomic; only the `pending -> committing` transition
  /// winner receives `acquired == true`. Any caller observing `committing`,
  /// `committed`, `rejected`, or `superseded` receives `acquired == false`
  /// and MUST perform zero durable adoption work.
  StudyPlanBeginCommitResult tryBeginCommit(String draftId) {
    final current = _requireDraft(draftId);
    if (current.outcome != StudyPlanDraftOutcome.pending) {
      return StudyPlanBeginCommitResult(draft: current, acquired: false);
    }
    final updated = current.withOutcome(StudyPlanDraftOutcome.committing);
    _draftsById[draftId] = updated;
    return StudyPlanBeginCommitResult(draft: updated, acquired: true);
  }

  /// Backward-compatible convenience forwarding to [tryBeginCommit].
  StudyPlanDraft beginCommit(String draftId) => tryBeginCommit(draftId).draft;

  /// Transient rollback from `committing -> pending` after a zero-mutation
  /// persistence failure or CAS conflict.
  ///
  /// Synchronous and atomic: only a `committing` draft transitions to
  /// `pending`. Never transitions `committed`, `rejected`, or
  /// `superseded` drafts.
  StudyPlanDraft rollbackCommit(String draftId) {
    return _transition(
      _requireDraft(draftId),
      from: StudyPlanDraftOutcome.committing,
      to: StudyPlanDraftOutcome.pending,
    );
  }

  /// D1 commit-success terminal marking seam: `committing -> committed`.
  ///
  /// Synchronous and atomic; only a `committing` draft transitions. A
  /// rejected or superseded draft can never become committed.
  StudyPlanDraft markCommitted(String draftId) {
    return _transition(
      _requireDraft(draftId),
      from: StudyPlanDraftOutcome.committing,
      to: StudyPlanDraftOutcome.committed,
    );
  }

  /// Reads the current transient state of [draftId], or throws
  /// [ArgumentError] for an unknown id.
  StudyPlanDraft draftById(String draftId) => _requireDraft(draftId);

  /// One synchronous, atomic post-read activation entry.
  ///
  /// Runs after the planning read with the reserved intent generation. No
  /// `await` may split this check-and-transition path: every map read and
  /// write happens in one event-loop turn, so concurrent staging calls
  /// serialize here deterministically.
  StudyPlanStageResult _activateAfterRead({
    required StudyPlanInput plan,
    required StudyPlanPreview preview,
    required StudyPlanDraftFingerprint fingerprint,
    required int generation,
    required String turnKey,
    required String sourceConversationId,
    required String sourceMessageId,
    required ConversationScope sourceScope,
  }) {
    // A same-intent call may already have activated this exact fingerprint
    // while the read was in flight; converge to it without a second
    // activation or lifecycle mutation.
    final existingId = _draftIdByFingerprint[fingerprint];
    if (existingId != null) {
      return StudyPlanStageResultStaged(_draftsById[existingId]!);
    }
    // This call must still own the latest proposal intent for its source
    // turn. An older different proposal whose planning read finished later
    // performs zero draft creation, supersession, or lifecycle mutation.
    if (!_isLatestIntent(turnKey, generation)) {
      return const StudyPlanStageResultStale();
    }
    return _activate(
      plan: plan,
      preview: preview,
      fingerprint: fingerprint,
      turnKey: turnKey,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      sourceScope: sourceScope,
    );
  }

  /// One synchronous, atomic activation block.
  ///
  /// Only the latest-intent call reaches this block (see
  /// [_activateAfterRead]). No `await` may split the check-and-transition
  /// path: every map read and write happens in one event-loop turn.
  StudyPlanStageResult _activate({
    required StudyPlanInput plan,
    required StudyPlanPreview preview,
    required StudyPlanDraftFingerprint fingerprint,
    required String turnKey,
    required String sourceConversationId,
    required String sourceMessageId,
    required ConversationScope sourceScope,
  }) {
    final currentId = _activeDraftIdByTurn[turnKey];
    if (currentId != null) {
      final current = _draftsById[currentId]!;
      if (current.outcome == StudyPlanDraftOutcome.committing) {
        // A revised proposal must not cancel or replace a committing draft,
        // and no second active/pending draft may exist for this source turn.
        return const StudyPlanStageResultBusy();
      }
      if (current.outcome == StudyPlanDraftOutcome.pending) {
        // The current pending draft belongs to an older proposal intent for
        // this turn; the latest intent supersedes it.
        _transition(
          current,
          from: StudyPlanDraftOutcome.pending,
          to: StudyPlanDraftOutcome.superseded,
        );
      }
      // Terminal (rejected/superseded/committed) drafts do not block a new
      // pending draft for the turn.
    }

    final draft = StudyPlanDraft(
      draftId: _draftIdFactory(),
      fingerprint: fingerprint,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      sourceScope: sourceScope,
      bankName: plan.bankName,
      goal: plan.goal,
      dailyTarget: plan.dailyTarget,
      priority: plan.priority,
      horizonDays: plan.horizonDays,
      createdAt: _clock(),
      outcome: StudyPlanDraftOutcome.pending,
      preview: preview,
    );
    _draftsById[draft.draftId] = draft;
    _draftIdByFingerprint[fingerprint] = draft.draftId;
    _activeDraftIdByTurn[turnKey] = draft.draftId;
    return StudyPlanStageResultStaged(draft);
  }

  /// Reserves (or reuses) the latest proposal intent for [turnKey].
  ///
  /// Synchronous and atomic. A different fingerprint advances the per-turn
  /// generation; the same fingerprint shares the existing generation so
  /// same-intent concurrent calls never fight as different revisions.
  int _reserveIntent(String turnKey, StudyPlanDraftFingerprint fingerprint) {
    final current = _intentByTurn[turnKey];
    if (current != null && current.fingerprint == fingerprint) {
      return current.generation;
    }
    final generation = (current?.generation ?? 0) + 1;
    _intentByTurn[turnKey] = (generation: generation, fingerprint: fingerprint);
    return generation;
  }

  /// Whether [generation] is still the latest reserved intent for
  /// [turnKey]. Synchronous; called only inside the activation path.
  bool _isLatestIntent(String turnKey, int generation) {
    final current = _intentByTurn[turnKey];
    return current != null && current.generation == generation;
  }

  /// The single shared transient lifecycle gate.
  ///
  /// Synchronous and atomic: re-reads the current stored outcome and only
  /// transitions when it equals [from]; otherwise the current draft is
  /// returned unchanged. Exactly one competing transition can win.
  StudyPlanDraft _transition(
    StudyPlanDraft target, {
    required StudyPlanDraftOutcome from,
    required StudyPlanDraftOutcome to,
  }) {
    final current = _draftsById[target.draftId]!;
    if (current.outcome != from) return current;
    final updated = current.withOutcome(to);
    _draftsById[target.draftId] = updated;
    return updated;
  }

  StudyPlanDraft _requireDraft(String draftId) {
    final draft = _draftsById[draftId];
    if (draft == null) {
      throw ArgumentError.value(draftId, 'draftId', 'Unknown draft.');
    }
    return draft;
  }

  static String _turnKey(String conversationId, String messageId) {
    return '$conversationId\u0000$messageId';
  }

  static bool _isBoundedId(String value) {
    final length = value.runes.length;
    return length >= 1 && length <= 128 && !value.contains('\u0000');
  }
}
