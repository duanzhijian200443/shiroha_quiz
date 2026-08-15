/// Canonical immutable `ActiveStudyPlan` value type.
///
/// D0 defines the type for SPL-1-D1 use only. D0 never reads or writes a
/// durable plan row: there is no schema v22, no migration, and no
/// persistence in this stage. The value is a global/product-level singleton
/// in semantics (exactly one active plan) and is never Project-owned.
library;

import 'study_plan_values.dart';

/// One durable active study plan value (schema v22 is a future SPL-1-D1
/// concern; this file only freezes the canonical value shape).
final class ActiveStudyPlan {
  factory ActiveStudyPlan({
    required String planId,
    required String bankName,
    String? goal,
    int? dailyTarget,
    StudyPlanPriority? priority,
    int? horizonDays,
    String? sourceConversationId,
    String? sourceUserMessageId,
    required DateTime adoptedAt,
  }) {
    final plan = StudyPlanInput.normalize(
      bankName: bankName,
      goal: goal,
      dailyTarget: dailyTarget,
      priority: priority,
      horizonDays: horizonDays,
    );
    _requireBoundedId(planId, 'planId');
    if (sourceConversationId != null) {
      _requireBoundedId(sourceConversationId, 'sourceConversationId');
    }
    if (sourceUserMessageId != null) {
      _requireBoundedId(sourceUserMessageId, 'sourceUserMessageId');
    }
    final normalizedAdoptedAt = DateTime.fromMillisecondsSinceEpoch(
        adoptedAt.millisecondsSinceEpoch,
        isUtc: true);
    if (normalizedAdoptedAt.millisecondsSinceEpoch < 0) {
      throw const FormatException(
        'ActiveStudyPlan adoptedAt must be a non-negative UTC instant.',
      );
    }
    return ActiveStudyPlan._(
      planId: planId,
      bankName: plan.bankName,
      goal: plan.goal,
      dailyTarget: plan.dailyTarget,
      priority: plan.priority,
      horizonDays: plan.horizonDays,
      sourceConversationId: sourceConversationId,
      sourceUserMessageId: sourceUserMessageId,
      adoptedAt: normalizedAdoptedAt,
    );
  }

  const ActiveStudyPlan._({
    required this.planId,
    required this.bankName,
    required this.goal,
    required this.dailyTarget,
    required this.priority,
    required this.horizonDays,
    required this.sourceConversationId,
    required this.sourceUserMessageId,
    required this.adoptedAt,
  });

  final String planId;
  final String bankName;
  final String? goal;
  final int dailyTarget;
  final StudyPlanPriority priority;
  final int? horizonDays;

  /// Record-only provenance, runtime-injected; never durable ownership and
  /// never an authorization scope for the adopted plan.
  final String? sourceConversationId;
  final String? sourceUserMessageId;

  final DateTime adoptedAt;

  static void _requireBoundedId(String value, String label) {
    final length = value.runes.length;
    if (length < 1 || length > 128 || value.contains('\u0000')) {
      throw FormatException(
        '$label must use the bounded opaque token format.',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ActiveStudyPlan &&
            planId == other.planId &&
            bankName == other.bankName &&
            goal == other.goal &&
            dailyTarget == other.dailyTarget &&
            priority == other.priority &&
            horizonDays == other.horizonDays &&
            sourceConversationId == other.sourceConversationId &&
            sourceUserMessageId == other.sourceUserMessageId &&
            adoptedAt == other.adoptedAt;
  }

  @override
  int get hashCode => Object.hash(
        planId,
        bankName,
        goal,
        dailyTarget,
        priority,
        horizonDays,
        sourceConversationId,
        sourceUserMessageId,
        adoptedAt,
      );
}
