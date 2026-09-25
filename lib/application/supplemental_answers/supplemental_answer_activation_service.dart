import '../../domain/assets/library_file.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import '../file_library/file_library_ports.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../u1_workspace/u1_workspace_dtos.dart';
import 'supplemental_answer_failure.dart';
import 'supplemental_answer_matcher.dart';
import 'supplemental_answer_projector.dart';
import 'supplemental_answer_review_session.dart';
import 'target_question_snapshot_service.dart';

/// Ordinary-user activation seam for the frozen P6 supplemental-answer flow.
///
/// Presentation reaches the P6 chain only through this service: it lists the
/// selectable File Library candidates as safe summaries and starts exactly one
/// matching session for one explicit target scope plus one explicitly selected
/// `LibraryFile`. It never ensures, reparses, or OCRs an artifact, and it never
/// writes answer data.
final class SupplementalAnswerActivationService {
  const SupplementalAnswerActivationService({
    required LibraryFileRepositoryPort fileCatalog,
    required TargetQuestionSnapshotService targetSnapshotService,
    required ParsedArtifactLifecyclePort artifactPort,
    SupplementalAnswerProjector projector = const SupplementalAnswerProjector(),
    SupplementalAnswerMatcher matcher = const SupplementalAnswerMatcher(),
  })  : _fileCatalog = fileCatalog,
        _targetSnapshotService = targetSnapshotService,
        _artifactPort = artifactPort,
        _projector = projector,
        _matcher = matcher;

  final LibraryFileRepositoryPort _fileCatalog;
  final TargetQuestionSnapshotService _targetSnapshotService;
  final ParsedArtifactLifecyclePort _artifactPort;
  final SupplementalAnswerProjector _projector;
  final SupplementalAnswerMatcher _matcher;

  /// Selectable supplemental files as safe summaries, newest first.
  ///
  /// Only the safe [LibraryFileSummary] projection leaves this seam; storage
  /// keys, managed paths, digests, rows, and artifact payloads never do.
  Future<List<LibraryFileSummary>> listSupplementalFiles() async {
    final files = <LibraryFileSummary>[
      for (final file in await _fileCatalog.findAll()) _summary(file),
    ]..sort(_newestFirst);
    return List<LibraryFileSummary>.unmodifiable(files);
  }

  /// Starts one matching session for [targetScope] and exactly one explicitly
  /// selected [supplementalFileId].
  ///
  /// The supplemental file is consumed only through the F1 lifecycle seam
  /// (`getCurrentArtifact`). A file without a current artifact, a corrupt or
  /// unsupported artifact, a target scope without eligible typed questions,
  /// and a document without a usable supplemental answer all fail safely with
  /// zero ensure/reparse/OCR and zero mutation.
  Future<SupplementalAnswerReviewSession> startSession({
    required SupplementalAnswerTargetScope targetScope,
    required String supplementalFileId,
  }) async {
    final request = SupplementalAnswerMatchRequest(
      targetScope: targetScope,
      supplementalFileId: supplementalFileId,
    );

    final snapshot = await _targetSnapshotService.resolve(request.targetScope);
    if (snapshot.isEmpty) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.targetUnavailable,
      );
    }

    final ParsedArtifactSnapshot artifact;
    try {
      artifact = await _artifactPort.getCurrentArtifact(
        request.supplementalFileId,
      );
    } on ParsedArtifactLifecycleException catch (error) {
      throw SupplementalAnswerException(_mapArtifactFailure(error.failure));
    }

    final projection = _projector.project(artifact.sourceDocument);
    if (projection.fragments.isEmpty) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.noUsableAnswers,
      );
    }

    final matchResult = _matcher.match(
      fragments: projection.fragments,
      snapshot: snapshot,
      artifact: SupplementalArtifactContext(
        supplementalFileId: request.supplementalFileId,
        artifactId: artifact.artifact.artifactId,
        artifactRevision: artifact.artifact.revision,
      ),
    );

    return SupplementalAnswerReviewSession(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
    );
  }
}

LibraryFileSummary _summary(LibraryFile file) {
  return LibraryFileSummary(
    fileId: file.fileId,
    displayName: file.displayName,
    mimeType: file.mimeType,
    sizeBytes: file.sizeBytes,
    createdAt: file.createdAt,
  );
}

int _newestFirst(LibraryFileSummary left, LibraryFileSummary right) {
  final created = right.createdAt.compareTo(left.createdAt);
  return created != 0 ? created : left.fileId.compareTo(right.fileId);
}

/// The same frozen artifact-failure mapping the P6 confirm path applies, so
/// activation and confirmation classify a missing/corrupt/unsupported
/// artifact identically.
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
