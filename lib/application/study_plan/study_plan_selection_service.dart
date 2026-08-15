/// SPL-1-U0 focused selection service.
///
/// Owns the deterministic dynamic selection pipeline for Today / 特训:
///
/// ```text
/// ActiveStudyPlan
/// -> live planning admission (global bank existence)
/// -> live candidate pools (maxPerPool = 200)
/// -> deterministic priority selection
/// -> typed focused state
/// ```
///
/// The Application boundary is respected: this service never receives or
/// exposes `PersistedQuestion`, `Question`, SQL rows, repository maps, or the
/// `Database`. Its output is bounded: an [ActiveStudyPlan], ordered selected
/// storage IDs, and advisory flags. No persisted question IDs exist anywhere.
/// Selection is recomputed fresh on every call from live review state; no
/// AI/provider call is ever involved.
library;

import '../../domain/conversations/conversation.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';
import 'study_plan_ports.dart';
import 'study_plan_pool_order.dart';

/// Bounded infrastructure failure categories for the focused surface. Never
/// carries SQL, paths, or raw causes.
enum StudyPlanFocusedFailureKind { temporarilyUnavailable, internalError }

/// Advisory-only flags derived from live planning state. None of them ever
/// deactivates a plan or empties the queue by itself.
final class StudyPlanFocusedAdvisory {
  const StudyPlanFocusedAdvisory({
    required this.masteryReached,
    required this.horizonElapsed,
  });

  /// `planningContext.masteredCount == planningContext.questionCount`.
  /// Advisory only: a mastered plan may still have due/weak selections.
  final bool masteryReached;

  /// `adoptedAt + horizonDays < now` when `horizonDays` exists. Advisory
  /// only: no auto-expiry, no disabled training.
  final bool horizonElapsed;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyPlanFocusedAdvisory &&
            masteryReached == other.masteryReached &&
            horizonElapsed == other.horizonElapsed;
  }

  @override
  int get hashCode => Object.hash(masteryReached, horizonElapsed);
}

/// Typed focused-state result of one selection pipeline run. Presentation
/// never receives exception text as state.
sealed class StudyPlanFocusedState {
  const StudyPlanFocusedState();
}

/// No durable ActiveStudyPlan exists.
final class StudyPlanFocusedNoActivePlan extends StudyPlanFocusedState {
  const StudyPlanFocusedNoActivePlan();
}

/// The active plan's bank no longer exists or has no real questions under
/// current GLOBAL bank admission semantics. The durable plan remains present;
/// it is never auto-deleted.
final class StudyPlanFocusedPlanUnavailable extends StudyPlanFocusedState {
  const StudyPlanFocusedPlanUnavailable(this.activePlan);

  final ActiveStudyPlan activePlan;
}

/// The active bank exists but deterministic selection is empty.
final class StudyPlanFocusedNoCandidates extends StudyPlanFocusedState {
  const StudyPlanFocusedNoCandidates(this.activePlan, this.advisory);

  final ActiveStudyPlan activePlan;
  final StudyPlanFocusedAdvisory advisory;
}

/// The active bank exists and deterministic selection produced an ordered
/// session of at most `dailyTarget` distinct storage IDs.
final class StudyPlanFocusedReady extends StudyPlanFocusedState {
  const StudyPlanFocusedReady(
    this.activePlan,
    this.selectedStorageIds,
    this.advisory,
  );

  final ActiveStudyPlan activePlan;

  /// Exact ordered, deduplicated, at-most-`dailyTarget` storage IDs. Never
  /// persisted; never reused across session starts.
  final List<String> selectedStorageIds;
  final StudyPlanFocusedAdvisory advisory;
}

/// Bounded infrastructure failure (temporarily unavailable / internal).
final class StudyPlanFocusedFailure extends StudyPlanFocusedState {
  const StudyPlanFocusedFailure(this.kind);

  final StudyPlanFocusedFailureKind kind;
}

/// Deterministic focused selection service for Today / 特训.
///
/// Dependencies are the narrow frozen ports plus an injected clock; no
/// repository, database, or row types ever cross this boundary.
class StudyPlanSelectionService {
  StudyPlanSelectionService({
    required StudyPlanPersistencePort persistencePort,
    required StudyPlanPlanningPort planningPort,
    required StudyPlanCandidateQueryPort candidateQueryPort,
    required StudyPlanPoolOrder poolOrder,
    required DateTime Function() clock,
  })  : _persistencePort = persistencePort,
        _planningPort = planningPort,
        _candidateQueryPort = candidateQueryPort,
        _poolOrder = poolOrder,
        _clock = clock;

  /// Frozen candidate-read bound. `dailyTarget` is capped at 200 and
  /// selection consumes the ordered pools with mandatory storageId dedup, so
  /// every possible final session of at most 200 distinct candidates is a
  /// prefix of the top-200 of each pool; reading `dailyTarget` instead could
  /// miss overlap-deeper candidates needed to reach `dailyTarget` distinct
  /// IDs. Reading more than 200 can never change the selection.
  static const int maxCandidatesPerPool = 200;

  final StudyPlanPersistencePort _persistencePort;
  final StudyPlanPlanningPort _planningPort;
  final StudyPlanCandidateQueryPort _candidateQueryPort;
  final StudyPlanPoolOrder _poolOrder;
  final DateTime Function() _clock;

  /// Runs the full fresh selection pipeline from live state and returns the
  /// typed focused state. Every call re-queries the live ActiveStudyPlan,
  /// planning admission, and candidate pools; callers MUST invoke this again
  /// at 开始特训 and must never reuse a previously displayed snapshot.
  Future<StudyPlanFocusedState> loadFocusedState() async {
    final now = _clock();
    final nowUnixSeconds = now.millisecondsSinceEpoch ~/ 1000;
    try {
      final activePlan = await _persistencePort.loadActivePlan();
      if (activePlan == null) {
        return const StudyPlanFocusedNoActivePlan();
      }

      final admission = await _planningPort.loadPlanningContext(
        sourceScope: ConversationScope.global(),
        bankName: activePlan.bankName,
        now: now,
      );
      if (admission is! StudyPlanPlanningAdmitted) {
        return StudyPlanFocusedPlanUnavailable(activePlan);
      }
      final context = admission.context;

      final batch = await _candidateQueryPort.loadCandidates(
        bankName: activePlan.bankName,
        nowUnixSeconds: nowUnixSeconds,
        maxPerPool: maxCandidatesPerPool,
      );

      final selected =
          _select(batch, activePlan.priority, activePlan.dailyTarget);
      final advisory = StudyPlanFocusedAdvisory(
        masteryReached: context.masteredCount == context.questionCount,
        horizonElapsed: _horizonElapsed(activePlan, now),
      );
      if (selected.isEmpty) {
        return StudyPlanFocusedNoCandidates(activePlan, advisory);
      }
      return StudyPlanFocusedReady(
        activePlan,
        List<String>.unmodifiable(selected),
        advisory,
      );
    } on StudyPlanReadException {
      return const StudyPlanFocusedFailure(
        StudyPlanFocusedFailureKind.temporarilyUnavailable,
      );
    } on StudyPlanException {
      return const StudyPlanFocusedFailure(
        StudyPlanFocusedFailureKind.temporarilyUnavailable,
      );
    } catch (_) {
      return const StudyPlanFocusedFailure(
        StudyPlanFocusedFailureKind.internalError,
      );
    }
  }

  /// Defensive deterministic ordering for any producer, then frozen priority
  /// consumption with mandatory storageId dedup and the dailyTarget cap.
  List<String> _select(
    StudyPlanCandidateBatch batch,
    StudyPlanPriority priority,
    int dailyTarget,
  ) {
    final due = _poolOrder.orderDue(batch.due);
    final weak = _poolOrder.orderWeak(batch.weak);
    final newPool = _poolOrder.orderNew(batch.newPool);
    return switch (priority) {
      StudyPlanPriority.dueFirst => _sequential(
          <List<StudyPlanCandidate>>[due, weak, newPool], dailyTarget),
      StudyPlanPriority.weakFirst => _sequential(
          <List<StudyPlanCandidate>>[weak, due, newPool], dailyTarget),
      StudyPlanPriority.newFirst => _sequential(
          <List<StudyPlanCandidate>>[newPool, due, weak], dailyTarget),
      StudyPlanPriority.balanced => _balanced(due, weak, newPool, dailyTarget),
    };
  }

  /// Sequential priorities: pool order fixed by priority; first occurrence
  /// wins; then take `dailyTarget`.
  List<String> _sequential(
    List<List<StudyPlanCandidate>> pools,
    int dailyTarget,
  ) {
    final merged = _poolOrder.dedupeByStorageId(pools.expand((pool) => pool));
    return List<String>.unmodifiable(
      merged.take(dailyTarget).map((candidate) => candidate.storageId),
    );
  }

  /// Exact balanced round-robin: due -> weak -> new -> due -> ... Each pool
  /// owns its cursor; on a pool's turn it advances past already-selected
  /// duplicate storage IDs until the first unselected candidate (selected) or
  /// the pool is exhausted (skipped). Stops immediately after any successful
  /// append that reaches `dailyTarget` (the cap is checked BEFORE the next
  /// pool is consumed, so the final length can never exceed `dailyTarget`),
  /// or when every pool is exhausted. Deterministic for identical inputs.
  List<String> _balanced(
    List<StudyPlanCandidate> due,
    List<StudyPlanCandidate> weak,
    List<StudyPlanCandidate> newPool,
    int dailyTarget,
  ) {
    final selected = <String>[];
    final seen = <String>{};
    var dueIndex = 0;
    var weakIndex = 0;
    var newIndex = 0;
    while (selected.length < dailyTarget) {
      var advanced = false;
      while (dueIndex < due.length && !seen.add(due[dueIndex].storageId)) {
        dueIndex++;
      }
      if (dueIndex < due.length) {
        selected.add(due[dueIndex].storageId);
        dueIndex++;
        if (selected.length == dailyTarget) break;
        advanced = true;
      }
      while (weakIndex < weak.length && !seen.add(weak[weakIndex].storageId)) {
        weakIndex++;
      }
      if (weakIndex < weak.length) {
        selected.add(weak[weakIndex].storageId);
        weakIndex++;
        if (selected.length == dailyTarget) break;
        advanced = true;
      }
      while (
          newIndex < newPool.length && !seen.add(newPool[newIndex].storageId)) {
        newIndex++;
      }
      if (newIndex < newPool.length) {
        selected.add(newPool[newIndex].storageId);
        newIndex++;
        if (selected.length == dailyTarget) break;
        advanced = true;
      }
      if (!advanced) break;
    }
    return List<String>.unmodifiable(selected);
  }

  /// Advisory only: `adoptedAt + horizonDays < now` when `horizonDays`
  /// exists. Never auto-expires or disables training.
  bool _horizonElapsed(ActiveStudyPlan plan, DateTime now) {
    final days = plan.horizonDays;
    if (days == null) return false;
    return plan.adoptedAt.add(Duration(days: days)).isBefore(now);
  }
}
