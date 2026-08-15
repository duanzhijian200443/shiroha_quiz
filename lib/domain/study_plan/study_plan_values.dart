/// Canonical SPL-1 StudyPlan domain values.
///
/// All values are bounded, immutable, producer-neutral, and free of
/// provider/repository content. Bounds and defaults are frozen by
/// `docs/product/SPL-1 StudyPlan Agent Tool v0.md` (canonical input bounds
/// and defaults). Normalization happens before `StudyPlanDraft` construction
/// and before fingerprint generation, so provider omission is never part of
/// plan identity.
library;

/// Frozen plan priority policy.
enum StudyPlanPriority {
  balanced,
  dueFirst,
  weakFirst,
  newFirst;

  static const StudyPlanPriority defaultPriority = StudyPlanPriority.balanced;

  /// Canonical tool-surface code. Unknown codes are rejected by
  /// [fromCanonicalCode]; normalization never stores a raw code.
  String get canonicalCode => switch (this) {
        StudyPlanPriority.balanced => 'balanced',
        StudyPlanPriority.dueFirst => 'due_first',
        StudyPlanPriority.weakFirst => 'weak_first',
        StudyPlanPriority.newFirst => 'new_first',
      };

  /// Parses one canonical code, or throws [FormatException] for unknown
  /// codes.
  static StudyPlanPriority fromCanonicalCode(String code) {
    return switch (code) {
      'balanced' => StudyPlanPriority.balanced,
      'due_first' => StudyPlanPriority.dueFirst,
      'weak_first' => StudyPlanPriority.weakFirst,
      'new_first' => StudyPlanPriority.newFirst,
      _ => throw const FormatException('Unknown StudyPlan priority code.'),
    };
  }
}

/// Transient `StudyPlanDraft` lifecycle outcome. Only these five states
/// exist in SPL-1 v0.
enum StudyPlanDraftOutcome {
  pending,
  committing,
  committed,
  rejected,
  superseded,
}

/// Producer-neutral candidate classification.
enum StudyPlanQuestionClassification {
  /// Canonical never-reviewed / `state = 0` semantics.
  newQuestion,

  /// Reviewed question (any non-zero review state).
  review,
}

/// The single SPL-1 draft operation semantics.
enum StudyPlanOperationKind { proposeStudyPlan }

/// Fixed validation codes of the canonical plan input normalizer.
enum StudyPlanValidationFailure {
  emptyBankName,
  bankNameTooLong,
  emptyGoal,
  goalTooLong,
  goalControlCharacters,
  invalidDailyTarget,
  invalidPriority,
  invalidHorizonDays,
}

/// Raised by [StudyPlanInput.normalize] when a plan field violates the
/// frozen canonical bounds. Carries only the fixed code, never raw input.
final class StudyPlanValidationException implements Exception {
  const StudyPlanValidationException(this.failure);

  final StudyPlanValidationFailure failure;

  @override
  String toString() => 'StudyPlanValidationException(${failure.name})';
}

/// Normalized canonical plan input.
///
/// Produced by [StudyPlanInput.normalize] from raw model-controlled fields:
/// every optional field is either rejected or reduced to its canonical
/// default, so two semantically equivalent calls (omitted `dailyTarget`
/// versus explicit `40`, omitted `priority` versus `balanced`) produce
/// structurally equal values that fingerprint identically.
final class StudyPlanInput {
  factory StudyPlanInput.normalize({
    required String bankName,
    String? goal,
    int? dailyTarget,
    StudyPlanPriority? priority,
    int? horizonDays,
  }) {
    final normalizedBankName = _normalizeBankName(bankName);
    final normalizedGoal = _normalizeGoal(goal);
    final normalizedDailyTarget = _normalizeDailyTarget(dailyTarget);
    final normalizedPriority = priority ?? StudyPlanPriority.defaultPriority;
    final normalizedHorizonDays = _normalizeHorizonDays(horizonDays);
    return StudyPlanInput._(
      bankName: normalizedBankName,
      goal: normalizedGoal,
      dailyTarget: normalizedDailyTarget,
      priority: normalizedPriority,
      horizonDays: normalizedHorizonDays,
    );
  }

  const StudyPlanInput._({
    required this.bankName,
    required this.goal,
    required this.dailyTarget,
    required this.priority,
    required this.horizonDays,
  });

  static const int minBankNameRunes = 1;
  static const int maxBankNameRunes = 200;
  static const int maxGoalRunes = 120;
  static const int defaultDailyTarget = 40;
  static const int minDailyTarget = 1;
  static const int maxDailyTarget = 200;
  static const int minHorizonDays = 1;
  static const int maxHorizonDays = 90;

  final String bankName;
  final String? goal;
  final int dailyTarget;
  final StudyPlanPriority priority;
  final int? horizonDays;

  static String _normalizeBankName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.emptyBankName,
      );
    }
    final runes = trimmed.runes.length;
    if (runes < minBankNameRunes || runes > maxBankNameRunes) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.bankNameTooLong,
      );
    }
    return trimmed;
  }

  static String? _normalizeGoal(String? value) {
    if (value == null) return null;
    final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.emptyGoal,
      );
    }
    if (collapsed.runes.length > maxGoalRunes) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.goalTooLong,
      );
    }
    for (final rune in collapsed.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const StudyPlanValidationException(
          StudyPlanValidationFailure.goalControlCharacters,
        );
      }
    }
    return collapsed;
  }

  static int _normalizeDailyTarget(int? value) {
    final target = value ?? defaultDailyTarget;
    if (target < minDailyTarget || target > maxDailyTarget) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.invalidDailyTarget,
      );
    }
    return target;
  }

  static int? _normalizeHorizonDays(int? value) {
    if (value == null) return null;
    if (value < minHorizonDays || value > maxHorizonDays) {
      throw const StudyPlanValidationException(
        StudyPlanValidationFailure.invalidHorizonDays,
      );
    }
    return value;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanInput &&
            bankName == other.bankName &&
            goal == other.goal &&
            dailyTarget == other.dailyTarget &&
            priority == other.priority &&
            horizonDays == other.horizonDays;
  }

  @override
  int get hashCode =>
      Object.hash(bankName, goal, dailyTarget, priority, horizonDays);
}

/// Producer-neutral selection candidate.
///
/// Carries only the bounded selection fields required to construct the due /
/// weak / new pools. Never carries question content, options, answers,
/// explanations, SQL rows, or repository data models.
final class StudyPlanCandidate {
  const StudyPlanCandidate({
    required this.storageId,
    required this.bankName,
    required this.due,
    required this.nextReviewAt,
    required this.lapses,
    required this.difficulty,
    required this.classification,
  });

  final String storageId;
  final String bankName;

  /// Whether the question is due at the query instant under the canonical
  /// T0 semantics (`next_review_time <= now`; `state = 0` overlap allowed).
  final bool due;

  /// Unix seconds of the scheduled review, or null when never scheduled.
  final int? nextReviewAt;
  final int lapses;
  final double difficulty;
  final StudyPlanQuestionClassification classification;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanCandidate &&
            storageId == other.storageId &&
            bankName == other.bankName &&
            due == other.due &&
            nextReviewAt == other.nextReviewAt &&
            lapses == other.lapses &&
            difficulty == other.difficulty &&
            classification == other.classification;
  }

  @override
  int get hashCode => Object.hash(
        storageId,
        bankName,
        due,
        nextReviewAt,
        lapses,
        difficulty,
        classification,
      );
}

/// Typed, producer-neutral planning context admitted by the planning read
/// seam. Descriptive aggregates only; overlap between due / weak / new is
/// allowed and these are not mutually exclusive buckets.
final class StudyPlanPlanningContext {
  const StudyPlanPlanningContext({
    required this.bankName,
    required this.questionCount,
    required this.masteredCount,
    required this.dueCount,
    required this.weakCount,
    required this.newCount,
  });

  final String bankName;
  final int questionCount;

  /// `state = 3` count.
  final int masteredCount;

  /// Canonical due count (`next_review_time <= now`, no state filter).
  final int dueCount;

  /// `lapses > 0` count.
  final int weakCount;

  /// Canonical `state = 0` / never-reviewed count.
  final int newCount;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanPlanningContext &&
            bankName == other.bankName &&
            questionCount == other.questionCount &&
            masteredCount == other.masteredCount &&
            dueCount == other.dueCount &&
            weakCount == other.weakCount &&
            newCount == other.newCount;
  }

  @override
  int get hashCode => Object.hash(
        bankName,
        questionCount,
        masteredCount,
        dueCount,
        weakCount,
        newCount,
      );
}

/// Deterministic Application-built preview value.
///
/// Built exclusively from the normalized plan fields and the admitted
/// planning context; LLM prose is never the authoritative preview.
/// [estimatedDays] is advisory progress guidance only and is never
/// scheduling authority.
final class StudyPlanPreview {
  const StudyPlanPreview({
    required this.bankName,
    required this.goal,
    required this.dailyTarget,
    required this.priority,
    required this.horizonDays,
    required this.questionCount,
    required this.masteredCount,
    required this.dueCount,
    required this.weakCount,
    required this.newCount,
    required this.estimatedDays,
  });

  final String bankName;
  final String? goal;
  final int dailyTarget;
  final StudyPlanPriority priority;
  final int? horizonDays;
  final int questionCount;
  final int masteredCount;
  final int dueCount;
  final int weakCount;
  final int newCount;

  /// Deterministic advisory estimate: `ceil(unmastered / dailyTarget)`,
  /// zero when nothing is unmastered.
  final int estimatedDays;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanPreview &&
            bankName == other.bankName &&
            goal == other.goal &&
            dailyTarget == other.dailyTarget &&
            priority == other.priority &&
            horizonDays == other.horizonDays &&
            questionCount == other.questionCount &&
            masteredCount == other.masteredCount &&
            dueCount == other.dueCount &&
            weakCount == other.weakCount &&
            newCount == other.newCount &&
            estimatedDays == other.estimatedDays;
  }

  @override
  int get hashCode => Object.hash(
        bankName,
        goal,
        dailyTarget,
        priority,
        horizonDays,
        questionCount,
        masteredCount,
        dueCount,
        weakCount,
        newCount,
        estimatedDays,
      );
}
