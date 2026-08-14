import '../../domain/supplemental_answers/answer_candidate.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../safe_write/typed_answer_command.dart';
import 'supplemental_answer_failure.dart';
import 'supplemental_answer_review_session.dart';

/// Data port for the second, linearized confirm layer.
///
/// Implementations must open one caller-owned persistence transaction that
/// rechecks the current parsed-artifact generation, the typed target
/// (storageId, bankName, expected draft, fill/replace precondition), and then
/// reuses the existing typed answer mutation kernel in the same transaction.
abstract interface class SupplementalAnswerPersistencePort {
  Future<void> confirmCandidate(AnswerCandidate candidate);
}

/// P6 confirm command.
///
/// Two layers:
///
/// 1. Through the F1 seam, re-read the current artifact and confirm
///    `fileId`, `artifactId`, `revision`, and readable payload exactly match
///    the candidate.
/// 2. Through [SupplementalAnswerPersistencePort], recheck the artifact
///    generation and the full typed target inside one caller-owned
///    transaction, then reuse the existing typed answer mutation kernel.
///
/// The purpose is a definite ordering between reparse publish and answer
/// mutation, eliminating artifact-check -> later-write TOCTOU.
final class SupplementalAnswerConfirmCommand {
  const SupplementalAnswerConfirmCommand({
    required ParsedArtifactLifecyclePort artifactPort,
    required SupplementalAnswerPersistencePort persistencePort,
  })  : _artifactPort = artifactPort,
        _persistencePort = persistencePort;

  final ParsedArtifactLifecyclePort _artifactPort;
  final SupplementalAnswerPersistencePort _persistencePort;

  Future<void> confirm(SupplementalAnswerConfirmation confirmation) async {
    final candidate = confirmation.candidate;
    // The P6 confirm path is Supplemental-only. A foreign producer origin
    // fails closed with a typed failure before any seam is touched; no
    // blind cast or runtime CastError can escape.
    final origin = switch (candidate.origin) {
      SupplementalAnswerOrigin origin => origin,
      AiAnswerOrigin() => throw const SupplementalAnswerException(
          SupplementalAnswerFailure.invalidCandidate,
        ),
    };

    final ParsedArtifactSnapshot snapshot;
    try {
      snapshot = await _artifactPort.getCurrentArtifact(
        origin.supplementalFileId,
      );
    } on ParsedArtifactLifecycleException catch (error) {
      throw SupplementalAnswerException(
        _mapArtifactFailure(error.failure),
      );
    }

    final artifact = snapshot.artifact;
    if (artifact.artifactId != origin.artifactId ||
        artifact.revision != origin.artifactRevision) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }

    try {
      await _persistencePort.confirmCandidate(candidate);
    } on TypedAnswerMutationException catch (error) {
      throw SupplementalAnswerException(_mapMutationFailure(error.failure));
    }
  }
}

SupplementalAnswerFailure _mapArtifactFailure(
  ParsedArtifactLifecycleFailure failure,
) {
  return switch (failure) {
    ParsedArtifactLifecycleFailure.invalidRequest =>
      SupplementalAnswerFailure.sourceUnavailable,
    ParsedArtifactLifecycleFailure.fileNotFound =>
      SupplementalAnswerFailure.sourceUnavailable,
    ParsedArtifactLifecycleFailure.unsupportedRoute =>
      SupplementalAnswerFailure.unsupportedArtifact,
    ParsedArtifactLifecycleFailure.sourceUnavailable =>
      SupplementalAnswerFailure.sourceUnavailable,
    ParsedArtifactLifecycleFailure.parseFailed ||
    ParsedArtifactLifecycleFailure.publishConflict =>
      SupplementalAnswerFailure.temporarilyUnavailable,
    ParsedArtifactLifecycleFailure.artifactMissing =>
      SupplementalAnswerFailure.sourceUnavailable,
    ParsedArtifactLifecycleFailure.artifactCorrupt =>
      SupplementalAnswerFailure.artifactCorrupt,
    ParsedArtifactLifecycleFailure.payloadUnsupported =>
      SupplementalAnswerFailure.unsupportedArtifact,
    ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
      SupplementalAnswerFailure.temporarilyUnavailable,
    ParsedArtifactLifecycleFailure.internalError =>
      SupplementalAnswerFailure.internalError,
  };
}

SupplementalAnswerFailure _mapMutationFailure(
  TypedAnswerMutationFailure failure,
) {
  return switch (failure) {
    TypedAnswerMutationFailure.notFound ||
    TypedAnswerMutationFailure.notTyped ||
    TypedAnswerMutationFailure.stale =>
      SupplementalAnswerFailure.staleTarget,
    TypedAnswerMutationFailure.corruptPayload ||
    TypedAnswerMutationFailure.unsafePayload =>
      SupplementalAnswerFailure.targetUnavailable,
    TypedAnswerMutationFailure.invalidAnswer =>
      SupplementalAnswerFailure.invalidCandidate,
    TypedAnswerMutationFailure.transactionFailed =>
      SupplementalAnswerFailure.temporarilyUnavailable,
  };
}
