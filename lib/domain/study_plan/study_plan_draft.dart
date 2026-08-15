/// Transient SPL-1 `StudyPlanDraft` and its canonical semantic fingerprint.
///
/// Drafts are transient only: they never touch SQLite and disappear on
/// process restart. The fingerprint uses normalized canonical values
/// ([StudyPlanInput]) plus the runtime-injected source authority; provider
/// omission/presence is never part of plan identity.
library;

import '../conversations/conversation.dart';
import 'study_plan_values.dart';

/// Deterministic semantic fingerprint of one `StudyPlanDraft`.
///
/// Equality is canonical structural equality over the frozen inputs: source
/// Conversation identity, source User Message identity, source
/// scope/project identity, operation semantics, and the normalized plan
/// fields. `draftId`, `createdAt`, preview counts, provider call identity,
/// and lifecycle state are never fingerprint inputs.
final class StudyPlanDraftFingerprint {
  const StudyPlanDraftFingerprint({
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.sourceScope,
    required this.operationKind,
    required this.plan,
  });

  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope sourceScope;
  final StudyPlanOperationKind operationKind;

  /// Normalized canonical plan fields; never raw provider omission/presence.
  final StudyPlanInput plan;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanDraftFingerprint &&
            sourceConversationId == other.sourceConversationId &&
            sourceMessageId == other.sourceMessageId &&
            sourceScope == other.sourceScope &&
            operationKind == other.operationKind &&
            plan == other.plan;
  }

  @override
  int get hashCode => Object.hash(
        sourceConversationId,
        sourceMessageId,
        sourceScope,
        operationKind,
        plan,
      );
}

/// One transient, immutable SPL-1 plan draft.
///
/// Created by the Application after planning admission and deterministic
/// preview construction. Never persisted; outcome transitions go through
/// the single atomic lifecycle gate of `StudyPlanDraftService`.
final class StudyPlanDraft {
  const StudyPlanDraft({
    required this.draftId,
    required this.fingerprint,
    required this.sourceConversationId,
    required this.sourceMessageId,
    required this.sourceScope,
    required this.bankName,
    required this.goal,
    required this.dailyTarget,
    required this.priority,
    required this.horizonDays,
    required this.createdAt,
    required this.outcome,
    required this.preview,
  });

  final String draftId;
  final StudyPlanDraftFingerprint fingerprint;
  final String sourceConversationId;
  final String sourceMessageId;
  final ConversationScope sourceScope;
  final String bankName;
  final String? goal;
  final int dailyTarget;
  final StudyPlanPriority priority;
  final int? horizonDays;
  final DateTime createdAt;
  final StudyPlanDraftOutcome outcome;
  final StudyPlanPreview preview;

  StudyPlanDraft withOutcome(StudyPlanDraftOutcome outcome) {
    return StudyPlanDraft(
      draftId: draftId,
      fingerprint: fingerprint,
      sourceConversationId: sourceConversationId,
      sourceMessageId: sourceMessageId,
      sourceScope: sourceScope,
      bankName: bankName,
      goal: goal,
      dailyTarget: dailyTarget,
      priority: priority,
      horizonDays: horizonDays,
      createdAt: createdAt,
      outcome: outcome,
      preview: preview,
    );
  }
}
