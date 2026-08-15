/// Pure, deterministic ordering and dedup helpers for SPL-1 candidate pools.
///
/// The repository pools are already ordered by the frozen rules; these
/// helpers guarantee the same deterministic order for any producer and
/// provide the mandatory selected-storageId dedup used by the future
/// SPL-1-U0 selection service. No UI selection logic lives here.
library;

import '../../domain/study_plan/study_plan_values.dart';

final class StudyPlanPoolOrder {
  const StudyPlanPoolOrder();

  /// due: `nextReviewAt ASC, storageId ASC`. Candidates without a scheduled
  /// review sort last (totality for any producer).
  List<StudyPlanCandidate> orderDue(Iterable<StudyPlanCandidate> candidates) {
    final list = candidates.toList(growable: false);
    list.sort((a, b) {
      final byNext = (a.nextReviewAt ?? _maxUnixSeconds)
          .compareTo(b.nextReviewAt ?? _maxUnixSeconds);
      if (byNext != 0) return byNext;
      return a.storageId.compareTo(b.storageId);
    });
    return list;
  }

  /// weak: `lapses DESC, difficulty DESC, storageId ASC`.
  List<StudyPlanCandidate> orderWeak(Iterable<StudyPlanCandidate> candidates) {
    final list = candidates.toList(growable: false);
    list.sort((a, b) {
      final byLapses = b.lapses.compareTo(a.lapses);
      if (byLapses != 0) return byLapses;
      final byDifficulty = b.difficulty.compareTo(a.difficulty);
      if (byDifficulty != 0) return byDifficulty;
      return a.storageId.compareTo(b.storageId);
    });
    return list;
  }

  /// new: `storageId ASC`.
  List<StudyPlanCandidate> orderNew(Iterable<StudyPlanCandidate> candidates) {
    final list = candidates.toList(growable: false);
    list.sort((a, b) => a.storageId.compareTo(b.storageId));
    return list;
  }

  /// Mandatory selected-storageId dedup: keeps the first occurrence and
  /// preserves relative order (stable).
  List<StudyPlanCandidate> dedupeByStorageId(
    Iterable<StudyPlanCandidate> candidates,
  ) {
    final seen = <String>{};
    final result = <StudyPlanCandidate>[];
    for (final candidate in candidates) {
      if (seen.add(candidate.storageId)) {
        result.add(candidate);
      }
    }
    return result;
  }

  static const int _maxUnixSeconds = 0x7fffffffffffffff;
}
