import '../../core/observability/log_writer.dart';
import '../../core/observability/trace_context.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
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
    Future<SupplementalAnswerReviewSession> run() async {
      final stopwatch = Stopwatch()..start();
      _recordP6Event(
        'supplemental_review_started',
        stage: 'activation',
        status: 'started',
      );
      try {
        final session = await _startSession(
          targetScope: targetScope,
          supplementalFileId: supplementalFileId,
        );
        _recordP6Event(
          'supplemental_review_completed',
          stage: 'activation',
          status: 'success',
          data: <String, Object?>{
            'durationMs': stopwatch.elapsedMilliseconds,
          },
        );
        return session;
      } on SupplementalAnswerException catch (error) {
        final traced = SupplementalAnswerException(
          error.failure,
          correlationId: TraceContext.correlationId,
          traceId: TraceContext.traceId,
        );
        _recordP6Event(
          'supplemental_review_failed',
          stage: 'activation',
          status: 'failed',
          data: <String, Object?>{
            'failureCode': error.failure.name,
            'durationMs': stopwatch.elapsedMilliseconds,
          },
        );
        throw traced;
      } catch (error) {
        _recordP6Event(
          'supplemental_review_failed',
          stage: 'activation',
          status: 'failed',
          data: <String, Object?>{
            'failureCode': SupplementalAnswerFailure.internalError.name,
            'errorType': error.runtimeType.toString(),
            'durationMs': stopwatch.elapsedMilliseconds,
          },
        );
        throw SupplementalAnswerException(
          SupplementalAnswerFailure.internalError,
          correlationId: TraceContext.correlationId,
          traceId: TraceContext.traceId,
        );
      }
    }

    if (TraceContext.traceId != null) return run();
    return TraceContext.run<SupplementalAnswerReviewSession>(
      traceId: TraceContext.createTraceId(),
      correlationId: TraceContext.createCorrelationId(),
      action: run,
    );
  }

  Future<SupplementalAnswerReviewSession> _startSession({
    required SupplementalAnswerTargetScope targetScope,
    required String supplementalFileId,
  }) async {
    final request = SupplementalAnswerMatchRequest(
      targetScope: targetScope,
      supplementalFileId: supplementalFileId,
    );

    final targetWatch = Stopwatch()..start();
    final snapshot = await _targetSnapshotService.resolve(request.targetScope);
    _recordP6Event(
      'supplemental_target_snapshot',
      stage: 'target_resolution',
      status: snapshot.isEmpty ? 'empty' : 'success',
      data: <String, Object?>{
        'targetCount': snapshot.targets.length,
        'reportCount': snapshot.reports.length,
        'durationMs': targetWatch.elapsedMilliseconds,
      },
    );
    if (snapshot.isEmpty) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.targetUnavailable,
      );
    }

    final ParsedArtifactSnapshot artifact;
    final artifactWatch = Stopwatch()..start();
    try {
      artifact = await _artifactPort.getCurrentArtifact(
        request.supplementalFileId,
      );
    } on ParsedArtifactLifecycleException catch (error) {
      throw SupplementalAnswerException(_mapArtifactFailure(error.failure));
    }
    _recordP6Event(
      'supplemental_artifact_loaded',
      stage: 'artifact_read',
      status: 'success',
      data: <String, Object?>{
        'sourcePartCount': artifact.sourceDocument.parts.length,
        'sourceIssueCount': artifact.sourceDocument.issues.length,
        'durationMs': artifactWatch.elapsedMilliseconds,
      },
    );

    final projectionWatch = Stopwatch()..start();
    final projection = _projector.project(artifact.sourceDocument);
    _recordP6Event(
      'supplemental_projection_completed',
      stage: 'projection',
      status: projection.fragments.isEmpty ? 'empty' : 'success',
      data: <String, Object?>{
        'fragmentCount': projection.fragments.length,
        'issueCounts': _countsByName(
          projection.issues,
          (issue) => issue.kind.name,
        ),
        'durationMs': projectionWatch.elapsedMilliseconds,
      },
    );
    if (projection.fragments.isEmpty) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.noUsableAnswers,
      );
    }

    final matchingWatch = Stopwatch()..start();
    final matchResult = _matcher.match(
      fragments: projection.fragments,
      snapshot: snapshot,
      artifact: SupplementalArtifactContext(
        supplementalFileId: request.supplementalFileId,
        artifactId: artifact.artifact.artifactId,
        artifactRevision: artifact.artifact.revision,
      ),
    );
    final answerNodeCounts = _RichContentNodeCounts();
    final explanationNodeCounts = _RichContentNodeCounts();
    for (final fragment in projection.fragments) {
      answerNodeCounts.add(fragment.answerContent);
      explanationNodeCounts.add(fragment.explanationContent);
    }
    final evidenceCounts = <String, int>{};
    for (final record in matchResult.records) {
      for (final evidence in record.evidence) {
        evidenceCounts.update(
          evidence.name,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    _recordP6Event(
      'supplemental_matching_completed',
      stage: 'matching',
      status: 'success',
      data: <String, Object?>{
        'recordCount': matchResult.records.length,
        'dispositionCounts': _countsByName(
          matchResult.records,
          (record) => record.disposition.name,
        ),
        'evidenceCounts': evidenceCounts,
        'coverageCounts': _countsByName(
          matchResult.coverage,
          (coverage) => coverage.status.name,
        ),
        'fragmentOutcomes': <Map<String, Object?>>[
          for (final record in matchResult.records)
            <String, Object?>{
              'fragmentId': record.fragmentId,
              'disposition': record.disposition.name,
              'certainty': record.certainty.name,
              'evidenceCodes': <String>[
                for (final evidence in record.evidence) evidence.name,
              ],
              'hasCandidate': record.candidate != null,
              'alternativeCount': record.alternatives.length,
            },
        ],
        'answerNodeCounts': answerNodeCounts.toMap(),
        'explanationNodeCounts': explanationNodeCounts.toMap(),
        'durationMs': matchingWatch.elapsedMilliseconds,
      },
    );

    return SupplementalAnswerReviewSession(
      request: request,
      snapshot: snapshot,
      matchResult: matchResult,
      correlationId: TraceContext.correlationId,
      traceId: TraceContext.traceId,
    );
  }
}

void _recordP6Event(
  String event, {
  required String stage,
  required String status,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  try {
    LogWriter.info(
      event,
      module: 'SupplementalAnswer',
      data: <String, Object?>{
        'event': event,
        'stage': stage,
        'status': status,
        ...data,
      },
    );
  } catch (_) {
    // Diagnostic logging is best effort and never changes review behavior.
  }
}

Map<String, int> _countsByName<T>(
  Iterable<T> values,
  String Function(T) nameOf,
) {
  final counts = <String, int>{};
  for (final value in values) {
    counts.update(nameOf(value), (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

final class _RichContentNodeCounts {
  final Map<String, int> _counts = <String, int>{};

  void add(RichContent? content) {
    if (content == null) return;
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          _increment('textNodes');
          if (text.trim().isEmpty) _increment('blankTextNodes');
          _increment('textLineBreaks', '\n'.allMatches(text).length);
        case InlineMathNode():
          _increment('inlineMathNodes');
        case BlockMathNode():
          _increment('blockMathNodes');
        case ImageNode(:final alternativeText):
          _increment('imageNodes');
          add(alternativeText);
        case TableNode(:final structure):
          _increment('tableNodes');
          for (final row in structure.rows) {
            for (final cell in row.cells) {
              _increment('tableCells');
              add(cell.content);
            }
          }
        case RawFallbackNode():
          _increment('rawFallbackNodes');
      }
    }
  }

  Map<String, int> toMap() => Map<String, int>.unmodifiable(_counts);

  void _increment(String key, [int amount = 1]) {
    _counts.update(key, (count) => count + amount, ifAbsent: () => amount);
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
