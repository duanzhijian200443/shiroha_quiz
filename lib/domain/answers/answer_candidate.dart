import '../content/rich_content.dart';
import '../question/question_draft_v2.dart';
import '../source/source_ref.dart';
import '../supplemental_answers/rich_content_equality.dart';

final _boundedTokenPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Write intent of one confirmed candidate.
///
/// `fill` targets a missing typed answer; `noOp` is a structural-equivalent
/// terminal outcome with zero transaction; `replace` is allowed only after a
/// per-question explicit reconfirmation of a `conflict`.
enum CandidateWriteIntent {
  fill,
  noOp,
  replace,
}

/// Typed evidence codes recorded on a Supplemental match.
///
/// Codes are stable semantic labels, not scores. They may rank review
/// alternatives internally but are never persisted and never exposed as
/// probability. This vocabulary belongs to the Supplemental producer origin;
/// the AI producer origin carries bounded generation provenance instead.
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

  /// The supplemental answer contains content that cannot become a writable
  /// typed answer (for example a raw fallback node).
  unsupportedContent,

  /// The source fragment maps to multiple targets.
  multipleTargets,

  /// The expected transient subquestion set is not uniquely and completely
  /// covered by the source fragments.
  subquestionSetMismatch,

  /// Mutually conflicting answer fragments for one target.
  sourceConflict,

  /// The supplemental single-choice label cannot map uniquely to a current
  /// option label.
  ambiguousChoiceLabel,

  /// The target is a legacy (non-typed) question and is visible but
  /// ineligible.
  legacyIneligible,
}

/// Typed producer origin of one transient [AnswerCandidate].
///
/// Producer-specific data never lives on the candidate's common structure;
/// it is sealed into this origin hierarchy. Adding a producer requires
/// extending this file, which forces every exhaustive pattern over
/// [AnswerCandidateOrigin] to handle the new producer at compile time.
sealed class AnswerCandidateOrigin {
  const AnswerCandidateOrigin();
}

/// Supplemental (P6) producer origin.
///
/// Freezes every P6 Supplemental-origin invariant: bounded opaque
/// `supplementalFileId` and `artifactId`, positive `artifactRevision`,
/// non-empty ordered `supplementalSourceRefs` all bound to the artifact,
/// typed match evidence, and immutable defensive copies. Any construction
/// that violates an invariant fails closed with a `FormatException`.
final class SupplementalAnswerOrigin extends AnswerCandidateOrigin {
  factory SupplementalAnswerOrigin({
    required String supplementalFileId,
    required String artifactId,
    required int artifactRevision,
    required Iterable<SourceRef> supplementalSourceRefs,
    required Iterable<MatchEvidenceCode> matchEvidence,
  }) {
    if (!_boundedTokenPattern.hasMatch(supplementalFileId)) {
      throw const FormatException(
        'Supplemental origin file ids must use the bounded opaque token format.',
      );
    }
    if (!_boundedTokenPattern.hasMatch(artifactId)) {
      throw const FormatException(
        'Supplemental origin artifact ids must use the bounded opaque token format.',
      );
    }
    if (artifactRevision <= 0) {
      throw const FormatException(
        'Supplemental origin artifact revisions must be positive.',
      );
    }
    final copiedSourceRefs = List<SourceRef>.unmodifiable(
      supplementalSourceRefs,
    );
    if (copiedSourceRefs.isEmpty) {
      throw const FormatException(
        'Supplemental origins require ordered source refs.',
      );
    }
    final sourceIds = copiedSourceRefs.map((ref) => ref.sourceId).toSet();
    if (sourceIds.length != 1 || sourceIds.single != artifactId) {
      throw const FormatException(
        'Supplemental origin source refs must belong to the bound artifact.',
      );
    }
    return SupplementalAnswerOrigin._(
      supplementalFileId: supplementalFileId,
      artifactId: artifactId,
      artifactRevision: artifactRevision,
      supplementalSourceRefs: copiedSourceRefs,
      matchEvidence: List<MatchEvidenceCode>.unmodifiable(matchEvidence),
    );
  }

  const SupplementalAnswerOrigin._({
    required this.supplementalFileId,
    required this.artifactId,
    required this.artifactRevision,
    required this.supplementalSourceRefs,
    required this.matchEvidence,
  });

  final String supplementalFileId;
  final String artifactId;
  final int artifactRevision;
  final List<SourceRef> supplementalSourceRefs;
  final List<MatchEvidenceCode> matchEvidence;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalAnswerOrigin &&
            supplementalFileId == other.supplementalFileId &&
            artifactId == other.artifactId &&
            artifactRevision == other.artifactRevision &&
            _orderedEquals(
              supplementalSourceRefs,
              other.supplementalSourceRefs,
            ) &&
            _orderedEquals(matchEvidence, other.matchEvidence);
  }

  @override
  int get hashCode => Object.hash(
        supplementalFileId,
        artifactId,
        artifactRevision,
        Object.hashAll(supplementalSourceRefs),
        Object.hashAll(matchEvidence),
      );
}

/// Minimal bounded AI producer origin (P7 seam).
///
/// Carries only safe, bounded, transient provenance: a bounded generation
/// identity, a safe provider/profile/model display identity, and the UTC
/// generation instant. It must never carry provider requests/responses,
/// credentials, reasoning, chain-of-thought, debug traces, HTTP headers,
/// billing metadata, or RAG/File provenance. AI generation itself is NOT
/// implemented in P7-D0a; this type exists so the producer seam is sealed
/// and the fail-closed P6 guards are expressible.
final class AiAnswerOrigin extends AnswerCandidateOrigin {
  factory AiAnswerOrigin({
    required String generationId,
    required String providerProfileId,
    required DateTime generatedAtUtc,
  }) {
    if (!_boundedTokenPattern.hasMatch(generationId)) {
      throw const FormatException(
        'AI origin generation ids must use the bounded opaque token format.',
      );
    }
    if (!_boundedTokenPattern.hasMatch(providerProfileId)) {
      throw const FormatException(
        'AI origin provider profile ids must use the bounded opaque token format.',
      );
    }
    if (!generatedAtUtc.isUtc) {
      throw const FormatException(
        'AI origin generation instants must be UTC.',
      );
    }
    return AiAnswerOrigin._(
      generationId: generationId,
      providerProfileId: providerProfileId,
      generatedAtUtc: generatedAtUtc,
    );
  }

  const AiAnswerOrigin._({
    required this.generationId,
    required this.providerProfileId,
    required this.generatedAtUtc,
  });

  final String generationId;
  final String providerProfileId;
  final DateTime generatedAtUtc;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AiAnswerOrigin &&
            generationId == other.generationId &&
            providerProfileId == other.providerProfileId &&
            generatedAtUtc == other.generatedAtUtc;
  }

  @override
  int get hashCode =>
      Object.hash(generationId, providerProfileId, generatedAtUtc);
}

/// Transient producer-neutral typed answer candidate.
///
/// A candidate exists only for a deterministic unique target and binds the
/// complete expected `QuestionDraftV2` snapshot plus the exact typed answer,
/// write intent, and one typed [AnswerCandidateOrigin]. Producer-specific
/// data (Supplemental artifact provenance, AI generation provenance) lives
/// only inside the origin. Candidates are never persisted; only `answer`
/// enters the existing typed mutation authority after explicit confirmation.
final class AnswerCandidate {
  factory AnswerCandidate({
    required String candidateId,
    required String targetStorageId,
    required String targetBankName,
    required QuestionDraftV2 expectedDraft,
    required QuestionAnswer answer,
    RichContent? reviewOnlyExplanation,
    required CandidateWriteIntent writeIntent,
    required AnswerCandidateOrigin origin,
  }) {
    if (!_boundedTokenPattern.hasMatch(candidateId)) {
      throw const FormatException(
        'Answer candidate ids must use the bounded opaque token format.',
      );
    }
    if (!_boundedTokenPattern.hasMatch(targetStorageId)) {
      throw const FormatException(
        'Answer candidate target ids must use the bounded opaque token format.',
      );
    }
    return AnswerCandidate._(
      candidateId: candidateId,
      targetStorageId: targetStorageId,
      targetBankName: targetBankName,
      expectedDraft: expectedDraft,
      answer: answer,
      reviewOnlyExplanation: reviewOnlyExplanation,
      writeIntent: writeIntent,
      origin: origin,
    );
  }

  const AnswerCandidate._({
    required this.candidateId,
    required this.targetStorageId,
    required this.targetBankName,
    required this.expectedDraft,
    required this.answer,
    required this.reviewOnlyExplanation,
    required this.writeIntent,
    required this.origin,
  });

  final String candidateId;
  final String targetStorageId;
  final String targetBankName;
  final QuestionDraftV2 expectedDraft;
  final QuestionAnswer answer;
  final RichContent? reviewOnlyExplanation;
  final CandidateWriteIntent writeIntent;
  final AnswerCandidateOrigin origin;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AnswerCandidate &&
            candidateId == other.candidateId &&
            targetStorageId == other.targetStorageId &&
            targetBankName == other.targetBankName &&
            expectedDraft == other.expectedDraft &&
            answer == other.answer &&
            _nullableRichContentEquals(
              reviewOnlyExplanation,
              other.reviewOnlyExplanation,
            ) &&
            writeIntent == other.writeIntent &&
            origin == other.origin;
  }

  @override
  int get hashCode => Object.hash(
        candidateId,
        targetStorageId,
        targetBankName,
        expectedDraft,
        answer,
        reviewOnlyExplanation == null
            ? null
            : richContentHash(reviewOnlyExplanation!),
        writeIntent,
        origin,
      );
}

bool _nullableRichContentEquals(RichContent? left, RichContent? right) {
  if (left == null || right == null) return left == right;
  return richContentEquals(left, right);
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
