import '../../domain/assets/library_file.dart';
import '../../domain/supplemental_answers/supplemental_answer_scope.dart';
import '../file_library/file_library_ports.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'supplemental_answer_activation_service.dart';
import 'supplemental_answer_failure.dart';
import 'supplemental_answer_review_session.dart';

/// Supplemental source file types accepted by the direct acquisition path.
///
/// Image formats stay out on purpose: image (PNG/JPG/JPEG) OCR activation is
/// deferred by the canonical OCR-UX contract, so this path never accepts them.
const supplementalAnswerSourceFileExtensions = <String>[
  'pdf',
  'docx',
  'txt',
  'md',
  'markdown',
];

/// Whether [displayName] names a file the direct acquisition path may add.
bool isSupportedSupplementalSourceName(String displayName) {
  final dot = displayName.lastIndexOf('.');
  if (dot < 0 || dot == displayName.length - 1) return false;
  return supplementalAnswerSourceFileExtensions
      .contains(displayName.substring(dot + 1).toLowerCase());
}

/// Observable phases of one direct acquisition, for Presentation progress.
enum SupplementalAnswerSourcePhase { ingesting, preparing, matching }

typedef SupplementalAnswerSourceProgress = void Function(
  SupplementalAnswerSourcePhase phase,
);

/// Bounded safe failure of one direct acquisition.
///
/// Categories are producer-side only: the Presentation maps each of them to
/// one fixed message and never receives a raw exception, path, storage key,
/// SQL, provider body, or artifact payload.
enum SupplementalAnswerSourceFailure {
  unreadableFile,
  unsupportedFile,
  ingestionFailed,
  parseFailed,
  ocrUnavailable,
  artifactCorrupt,
  unsupportedArtifact,
  noUsableAnswers,
  targetUnavailable,
  temporarilyUnavailable,
  internalError,
}

/// Result of one direct acquisition attempt.
sealed class SupplementalAnswerSourceOutcome {
  const SupplementalAnswerSourceOutcome();
}

/// Deterministic preparation succeeded and the existing P6 session is ready.
final class SupplementalAnswerSourceReady
    extends SupplementalAnswerSourceOutcome {
  const SupplementalAnswerSourceReady(this.session);

  final SupplementalAnswerReviewSession session;
}

/// The file entered the File Library but deterministic parsing found no
/// extractable text, so the PDF needs one explicit OCR decision from the user.
///
/// [fileId] is the safe opaque identity of the already-ingested `LibraryFile`;
/// it never carries a storage key, managed path, or digest.
final class SupplementalAnswerSourceOcrRequired
    extends SupplementalAnswerSourceOutcome {
  const SupplementalAnswerSourceOcrRequired({required this.fileId});

  final String fileId;
}

/// The acquisition stopped with one bounded safe failure.
final class SupplementalAnswerSourceFailed
    extends SupplementalAnswerSourceOutcome {
  const SupplementalAnswerSourceFailed(this.failure);

  final SupplementalAnswerSourceFailure failure;
}

/// Direct supplemental-source acquisition: external file -> File Library ->
/// deterministic F1 parsing -> existing P6 session.
///
/// This seam sits *outside* [SupplementalAnswerActivationService] and reuses
/// every existing authority: F0 ingestion owns the managed copy and metadata,
/// the F1 lifecycle owns parsing, and the activation service owns matching. It
/// never re-implements file storage, artifact storage, projection, matching, or
/// answer writing, and it never triggers OCR on its own: `auto` stays
/// deterministic, and the OCR route is reachable only through
/// [continueWithOcr] after the user explicitly confirmed.
///
/// A durable `LibraryFile` is never rolled back by this seam. Ingestion is a
/// legitimate committed action, so a later parse/OCR/match failure leaves the
/// file in the File Library for retry, re-selection, or manual deletion.
final class SupplementalAnswerSourceAcquisitionService {
  const SupplementalAnswerSourceAcquisitionService({
    required FileIngestionPort ingestion,
    required ParsedArtifactLifecyclePort artifactPort,
    required SupplementalAnswerActivationService activationService,
  })  : _ingestion = ingestion,
        _artifactPort = artifactPort,
        _activationService = activationService;

  final FileIngestionPort _ingestion;
  final ParsedArtifactLifecyclePort _artifactPort;
  final SupplementalAnswerActivationService _activationService;

  /// Adds the user-selected external file and starts the P6 session.
  ///
  /// [externalPath] is a transient picker result: it is passed to ingestion and
  /// never stored, returned, logged, or used as durable identity.
  Future<SupplementalAnswerSourceOutcome> addSourceAndStart({
    required SupplementalAnswerTargetScope targetScope,
    required String externalPath,
    required String displayName,
    SupplementalAnswerSourceProgress? onPhase,
  }) async {
    if (!isSupportedSupplementalSourceName(displayName)) {
      return const SupplementalAnswerSourceFailed(
        SupplementalAnswerSourceFailure.unsupportedFile,
      );
    }

    onPhase?.call(SupplementalAnswerSourcePhase.ingesting);
    final LibraryFile file;
    try {
      file = await _ingestion.ingest(
        externalPath: externalPath,
        displayName: displayName,
      );
    } catch (_) {
      return const SupplementalAnswerSourceFailed(
        SupplementalAnswerSourceFailure.ingestionFailed,
      );
    }

    onPhase?.call(SupplementalAnswerSourcePhase.preparing);
    final preparation = await _ensureDeterministic(file);
    switch (preparation) {
      case _PreparationReady():
        break;
      case _PreparationOcrRequired():
        return SupplementalAnswerSourceOcrRequired(fileId: file.fileId);
      case _PreparationFailed(:final failure):
        return SupplementalAnswerSourceFailed(failure);
    }

    return _startSession(
      targetScope: targetScope,
      fileId: file.fileId,
      onPhase: onPhase,
    );
  }

  /// Continues one already-ingested scanned PDF through explicit OCR.
  ///
  /// Only the Presentation may call this, and only after the user confirmed the
  /// canonical OCR dialog; the `ocr_pdf` route is never selected implicitly.
  Future<SupplementalAnswerSourceOutcome> continueWithOcr({
    required SupplementalAnswerTargetScope targetScope,
    required String fileId,
    SupplementalAnswerSourceProgress? onPhase,
  }) async {
    onPhase?.call(SupplementalAnswerSourcePhase.preparing);
    final preparation = await _ensureOcr(fileId);
    if (preparation case _PreparationFailed(:final failure)) {
      return SupplementalAnswerSourceFailed(failure);
    }
    return _startSession(
      targetScope: targetScope,
      fileId: fileId,
      onPhase: onPhase,
    );
  }

  Future<SupplementalAnswerSourceOutcome> _startSession({
    required SupplementalAnswerTargetScope targetScope,
    required String fileId,
    required SupplementalAnswerSourceProgress? onPhase,
  }) async {
    onPhase?.call(SupplementalAnswerSourcePhase.matching);
    try {
      final session = await _activationService.startSession(
        targetScope: targetScope,
        supplementalFileId: fileId,
      );
      return SupplementalAnswerSourceReady(session);
    } on SupplementalAnswerException catch (error) {
      return SupplementalAnswerSourceFailed(
        _mapActivationFailure(error.failure),
      );
    } catch (_) {
      return const SupplementalAnswerSourceFailed(
        SupplementalAnswerSourceFailure.internalError,
      );
    }
  }

  Future<_Preparation> _ensureDeterministic(LibraryFile file) async {
    try {
      await _artifactPort.ensureParsedArtifact(
        fileId: file.fileId,
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.auto,
        ),
      );
      return const _PreparationReady();
    } on ParsedArtifactLifecycleException catch (error) {
      return _mapDeterministicFailure(error.failure, isPdf: _isPdf(file));
    } catch (_) {
      return const _PreparationFailed(
        SupplementalAnswerSourceFailure.internalError,
      );
    }
  }

  Future<_Preparation> _ensureOcr(String fileId) async {
    try {
      await _artifactPort.ensureParsedArtifact(
        fileId: fileId,
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.ocrPdf,
        ),
      );
      return const _PreparationReady();
    } on ParsedArtifactLifecycleException catch (error) {
      return _mapOcrFailure(error.failure);
    } catch (_) {
      return const _PreparationFailed(
        SupplementalAnswerSourceFailure.internalError,
      );
    }
  }
}

/// Maps a deterministic `auto` failure onto the bounded acquisition taxonomy.
///
/// A PDF without extractable text offers one explicit OCR decision; every other
/// source stays a plain parse failure. `auto` itself never degrades to OCR.
_Preparation _mapDeterministicFailure(
  ParsedArtifactLifecycleFailure failure, {
  required bool isPdf,
}) {
  return switch (failure) {
    ParsedArtifactLifecycleFailure.sourceUnavailable => isPdf
        ? const _PreparationOcrRequired()
        : const _PreparationFailed(SupplementalAnswerSourceFailure.parseFailed),
    ParsedArtifactLifecycleFailure.unsupportedRoute =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.unsupportedFile),
    ParsedArtifactLifecycleFailure.parseFailed ||
    ParsedArtifactLifecycleFailure.publishConflict ||
    ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.parseFailed),
    ParsedArtifactLifecycleFailure.artifactCorrupt ||
    ParsedArtifactLifecycleFailure.payloadUnsupported =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.artifactCorrupt),
    ParsedArtifactLifecycleFailure.invalidRequest ||
    ParsedArtifactLifecycleFailure.fileNotFound ||
    ParsedArtifactLifecycleFailure.artifactMissing ||
    ParsedArtifactLifecycleFailure.internalError =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.internalError),
  };
}

/// Maps an explicit `ocr_pdf` failure onto the bounded acquisition taxonomy.
///
/// An unavailable/unconfigured OCR engine is its own category so the user is
/// told to check the OCR engine configuration instead of retrying forever.
_Preparation _mapOcrFailure(ParsedArtifactLifecycleFailure failure) {
  return switch (failure) {
    ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.ocrUnavailable),
    ParsedArtifactLifecycleFailure.sourceUnavailable ||
    ParsedArtifactLifecycleFailure.parseFailed ||
    ParsedArtifactLifecycleFailure.publishConflict ||
    ParsedArtifactLifecycleFailure.unsupportedRoute ||
    ParsedArtifactLifecycleFailure.fileNotFound ||
    ParsedArtifactLifecycleFailure.artifactMissing =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.parseFailed),
    ParsedArtifactLifecycleFailure.artifactCorrupt ||
    ParsedArtifactLifecycleFailure.payloadUnsupported =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.artifactCorrupt),
    ParsedArtifactLifecycleFailure.invalidRequest ||
    ParsedArtifactLifecycleFailure.internalError =>
      const _PreparationFailed(SupplementalAnswerSourceFailure.internalError),
  };
}

/// Maps an existing P6 activation failure onto the acquisition taxonomy.
///
/// `sourceUnavailable` here means the artifact we just ensured is no longer
/// readable, which the direct path reports as a parse failure rather than as
/// the "not parsed yet" message of the existing-file path.
SupplementalAnswerSourceFailure _mapActivationFailure(
  SupplementalAnswerFailure failure,
) {
  return switch (failure) {
    SupplementalAnswerFailure.noUsableAnswers =>
      SupplementalAnswerSourceFailure.noUsableAnswers,
    SupplementalAnswerFailure.targetUnavailable =>
      SupplementalAnswerSourceFailure.targetUnavailable,
    SupplementalAnswerFailure.unsupportedArtifact =>
      SupplementalAnswerSourceFailure.unsupportedArtifact,
    SupplementalAnswerFailure.artifactCorrupt =>
      SupplementalAnswerSourceFailure.artifactCorrupt,
    SupplementalAnswerFailure.temporarilyUnavailable =>
      SupplementalAnswerSourceFailure.temporarilyUnavailable,
    SupplementalAnswerFailure.sourceUnavailable =>
      SupplementalAnswerSourceFailure.parseFailed,
    SupplementalAnswerFailure.staleTarget ||
    SupplementalAnswerFailure.ambiguousMatch ||
    SupplementalAnswerFailure.unmatched ||
    SupplementalAnswerFailure.conflict ||
    SupplementalAnswerFailure.invalidCandidate ||
    SupplementalAnswerFailure.internalError =>
      SupplementalAnswerSourceFailure.internalError,
  };
}

bool _isPdf(LibraryFile file) {
  final name = file.displayName.toLowerCase();
  return name.endsWith('.pdf') || file.mimeType == 'application/pdf';
}

sealed class _Preparation {
  const _Preparation();
}

final class _PreparationReady extends _Preparation {
  const _PreparationReady();
}

final class _PreparationOcrRequired extends _Preparation {
  const _PreparationOcrRequired();
}

final class _PreparationFailed extends _Preparation {
  const _PreparationFailed(this.failure);

  final SupplementalAnswerSourceFailure failure;
}
