/// Frozen semantic failure taxonomy of the P6 supplemental-answer flow.
///
/// Categories are canonical; future enum naming may differ but the semantics
/// must stay frozen. Hard failures (source/artifact/target unavailable,
/// corrupt, unsupported, temporary, internal) are distinct from normal
/// business outcomes (ambiguous, unmatched, conflict).
enum SupplementalAnswerFailure {
  sourceUnavailable,
  artifactCorrupt,
  unsupportedArtifact,
  noUsableAnswers,
  targetUnavailable,
  ambiguousMatch,
  unmatched,
  conflict,
  staleTarget,
  invalidCandidate,
  temporarilyUnavailable,
  internalError,
}

/// Safe fixed failure of the P6 flow.
///
/// Retains no raw cause, SQL, path, storage key, provider body, payload, or
/// user content; [toString] renders one fixed safe message per failure.
final class SupplementalAnswerException implements Exception {
  const SupplementalAnswerException(this.failure);

  final SupplementalAnswerFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      SupplementalAnswerFailure.sourceUnavailable =>
        'The supplemental source is unavailable.',
      SupplementalAnswerFailure.artifactCorrupt =>
        'The supplemental artifact is corrupt.',
      SupplementalAnswerFailure.unsupportedArtifact =>
        'The supplemental artifact is unsupported.',
      SupplementalAnswerFailure.noUsableAnswers =>
        'No usable supplemental answers were found.',
      SupplementalAnswerFailure.targetUnavailable =>
        'The typed target is unavailable.',
      SupplementalAnswerFailure.ambiguousMatch =>
        'The supplemental match is ambiguous.',
      SupplementalAnswerFailure.unmatched =>
        'The supplemental fragment has no matching target.',
      SupplementalAnswerFailure.conflict =>
        'The target already has a different answer.',
      SupplementalAnswerFailure.staleTarget =>
        'The artifact or target changed after matching.',
      SupplementalAnswerFailure.invalidCandidate =>
        'The supplemental answer candidate is invalid.',
      SupplementalAnswerFailure.temporarilyUnavailable =>
        'The supplemental answer service is temporarily unavailable.',
      SupplementalAnswerFailure.internalError =>
        'The supplemental answer service encountered an internal error.',
    };
    return 'SupplementalAnswerException(${failure.name}): $detail';
  }
}
