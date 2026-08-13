import '../question/question_draft_v2.dart';
import 'answer_candidate.dart';

/// Disposition of one source fragment after deterministic matching.
///
/// `matched` and `conflict` resolve to exactly one deterministic target;
/// `conflict` additionally means the existing typed answer differs from the
/// supplemental candidate. `unmatched` means the source fragment has no
/// target; it is never the same as `uncovered` (a formal target without a
/// supplemental answer), which is tracked by [TargetCoverage] instead.
enum AnswerMatchDisposition {
  matched,
  ambiguous,
  unmatched,
  conflict,
  invalid,
}

/// Canonical certainty of one match.
///
/// P6 defines no probabilistic confidence and freezes no 0-1 score. A
/// `deterministic` certainty requires a primary identity proof plus hard
/// compatibility; `ambiguous` means no committable candidate exists;
/// `none` is used for unmatched/invalid dispositions.
enum MatchCertainty {
  deterministic,
  ambiguous,
  none,
}

/// Typed evidence codes recorded on a match.
///
/// Codes are stable semantic labels, not scores. They may rank review
/// alternatives internally but are never persisted and never exposed as
/// probability.
enum MatchEvidenceCode {
  /// Scope-unique exact normalized main number.
  uniqueMainNumber,

  /// Unique main number plus explicit subquestion proof.
  mainNumberAndSubquestion,

  /// No number, but scope-unique exact normalized full stem fingerprint.
  uniqueStemFingerprint,

  /// Same-locator continuation group that still resolves uniquely.
  continuationGroup,

  /// Question type / answer shape passed the hard compatibility filter.
  typeCompatible,

  /// Local heading/section context corroboration.
  headingCorroboration,

  /// Source relationship corroboration.
  sourceCorroboration,

  /// Sequence/neighborhood consistency (corroboration only).
  neighborhoodConsistency,

  /// Duplicate locator without a unique sub/stem proof.
  duplicateLocator,

  /// Only sequence/neighborhood evidence is available.
  sequenceOnly,

  /// The fragment has no usable locator or stem identity.
  noLocator,

  /// A plausible target exists but no primary identity proof is available.
  missingPrimaryProof,

  /// The target failed the hard question-type/answer-shape compatibility
  /// filter.
  typeIncompatible,

  /// The source fragment maps to multiple targets.
  multipleTargets,

  /// Mutually conflicting answer fragments for one target.
  sourceConflict,

  /// The supplemental single-choice label cannot map uniquely to a current
  /// option label.
  ambiguousChoiceLabel,

  /// The target is a legacy (non-typed) question and is visible but
  /// ineligible.
  legacyIneligible,
}

/// One deterministic target reference used for alternatives and coverage.
final class AnswerTargetReference {
  const AnswerTargetReference({
    required this.storageId,
    required this.bankName,
    required this.draft,
  });

  final String storageId;
  final String bankName;
  final QuestionDraftV2 draft;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AnswerTargetReference &&
            storageId == other.storageId &&
            bankName == other.bankName &&
            draft == other.draft;
  }

  @override
  int get hashCode => Object.hash(storageId, bankName, draft);
}

/// One source fragment grouped with its deterministic match outcome.
///
/// `unmatched` and `ambiguous` records never carry a candidate. A `conflict`
/// record carries a candidate whose write intent is `replace`; `matched`
/// candidates use `fill` or `noOp`.
final class AnswerMatchRecord {
  const AnswerMatchRecord({
    required this.fragmentId,
    required this.disposition,
    required this.certainty,
    required this.evidence,
    this.candidate,
    this.alternatives = const <AnswerTargetReference>[],
  });

  final String fragmentId;
  final AnswerMatchDisposition disposition;
  final MatchCertainty certainty;
  final List<MatchEvidenceCode> evidence;
  final AnswerCandidate? candidate;
  final List<AnswerTargetReference> alternatives;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AnswerMatchRecord &&
            fragmentId == other.fragmentId &&
            disposition == other.disposition &&
            certainty == other.certainty &&
            _orderedEquals(evidence, other.evidence) &&
            candidate == other.candidate &&
            _orderedEquals(alternatives, other.alternatives);
  }

  @override
  int get hashCode => Object.hash(
        fragmentId,
        disposition,
        certainty,
        Object.hashAll(evidence),
        candidate,
        Object.hashAll(alternatives),
      );
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
