import '../content/rich_content.dart';
import '../question/question_draft_v2.dart';
import '../source/source_ref.dart';
import 'answer_match_record.dart';
import 'rich_content_equality.dart';

final _candidateIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

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

/// Transient typed answer candidate produced by P6 matching.
///
/// A candidate exists only for a deterministic unique target and binds the
/// exact artifact generation (`artifactId` + `revision`) plus the expected
/// `QuestionDraftV2`. It is never persisted; only `answer` enters the
/// existing typed mutation authority after explicit confirmation.
final class AnswerCandidate {
  factory AnswerCandidate({
    required String candidateId,
    required String targetStorageId,
    required String targetBankName,
    required QuestionDraftV2 expectedDraft,
    required String supplementalFileId,
    required String artifactId,
    required int artifactRevision,
    required QuestionAnswer answer,
    RichContent? reviewOnlyExplanation,
    required Iterable<SourceRef> supplementalSourceRefs,
    required Iterable<MatchEvidenceCode> matchEvidence,
    required CandidateWriteIntent writeIntent,
  }) {
    if (!_candidateIdPattern.hasMatch(candidateId)) {
      throw const FormatException(
        'Answer candidate ids must use the bounded opaque token format.',
      );
    }
    if (!_candidateIdPattern.hasMatch(targetStorageId)) {
      throw const FormatException(
        'Answer candidate target ids must use the bounded opaque token format.',
      );
    }
    if (!_candidateIdPattern.hasMatch(supplementalFileId)) {
      throw const FormatException(
        'Answer candidate file ids must use the bounded opaque token format.',
      );
    }
    if (!_candidateIdPattern.hasMatch(artifactId)) {
      throw const FormatException(
        'Answer candidate artifact ids must use the bounded opaque token format.',
      );
    }
    if (artifactRevision <= 0) {
      throw const FormatException(
        'Answer candidate artifact revisions must be positive.',
      );
    }
    final copiedSourceRefs = List<SourceRef>.unmodifiable(
      supplementalSourceRefs,
    );
    if (copiedSourceRefs.isEmpty) {
      throw const FormatException(
        'Answer candidates require ordered supplemental source refs.',
      );
    }
    final sourceIds = copiedSourceRefs.map((ref) => ref.sourceId).toSet();
    if (sourceIds.length != 1 || sourceIds.single != artifactId) {
      throw const FormatException(
        'Answer candidate source refs must belong to the bound artifact.',
      );
    }
    return AnswerCandidate._(
      candidateId: candidateId,
      targetStorageId: targetStorageId,
      targetBankName: targetBankName,
      expectedDraft: expectedDraft,
      supplementalFileId: supplementalFileId,
      artifactId: artifactId,
      artifactRevision: artifactRevision,
      answer: answer,
      reviewOnlyExplanation: reviewOnlyExplanation,
      supplementalSourceRefs: copiedSourceRefs,
      matchEvidence: List<MatchEvidenceCode>.unmodifiable(matchEvidence),
      writeIntent: writeIntent,
    );
  }

  const AnswerCandidate._({
    required this.candidateId,
    required this.targetStorageId,
    required this.targetBankName,
    required this.expectedDraft,
    required this.supplementalFileId,
    required this.artifactId,
    required this.artifactRevision,
    required this.answer,
    required this.reviewOnlyExplanation,
    required this.supplementalSourceRefs,
    required this.matchEvidence,
    required this.writeIntent,
  });

  final String candidateId;
  final String targetStorageId;
  final String targetBankName;
  final QuestionDraftV2 expectedDraft;
  final String supplementalFileId;
  final String artifactId;
  final int artifactRevision;
  final QuestionAnswer answer;
  final RichContent? reviewOnlyExplanation;
  final List<SourceRef> supplementalSourceRefs;
  final List<MatchEvidenceCode> matchEvidence;
  final CandidateWriteIntent writeIntent;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AnswerCandidate &&
            candidateId == other.candidateId &&
            targetStorageId == other.targetStorageId &&
            targetBankName == other.targetBankName &&
            expectedDraft == other.expectedDraft &&
            supplementalFileId == other.supplementalFileId &&
            artifactId == other.artifactId &&
            artifactRevision == other.artifactRevision &&
            answer == other.answer &&
            _nullableRichContentEquals(
              reviewOnlyExplanation,
              other.reviewOnlyExplanation,
            ) &&
            _orderedEquals(supplementalSourceRefs, other.supplementalSourceRefs) &&
            _orderedEquals(matchEvidence, other.matchEvidence) &&
            writeIntent == other.writeIntent;
  }

  @override
  int get hashCode => Object.hash(
        candidateId,
        targetStorageId,
        targetBankName,
        expectedDraft,
        supplementalFileId,
        artifactId,
        artifactRevision,
        answer,
        reviewOnlyExplanation == null
            ? null
            : richContentHash(reviewOnlyExplanation!),
        Object.hashAll(supplementalSourceRefs),
        Object.hashAll(matchEvidence),
        writeIntent,
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
