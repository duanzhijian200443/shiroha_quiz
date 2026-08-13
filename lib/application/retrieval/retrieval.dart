library;

import '../../domain/retrieval/retrieval_chunk.dart';
import '../../domain/source/source_ref.dart';

enum RetrievalStrategy { lexicalV1 }

sealed class RetrievalScopeRequest {
  const RetrievalScopeRequest();
}

final class RetrievalFilesScope extends RetrievalScopeRequest {
  RetrievalFilesScope(Iterable<String> fileIds)
      : fileIds = List<String>.unmodifiable(fileIds);
  final List<String> fileIds;
}

final class RetrievalProjectScope extends RetrievalScopeRequest {
  const RetrievalProjectScope(this.projectId);
  final String projectId;
}

final class RetrievalConversationAttachmentsScope
    extends RetrievalScopeRequest {
  const RetrievalConversationAttachmentsScope(this.conversationId);
  final String conversationId;
}

final class RetrievalArtifactSnapshot {
  const RetrievalArtifactSnapshot({
    required this.fileId,
    required this.artifactId,
    required this.revision,
    required this.payloadDigest,
    this.displayLabel,
  });
  final String fileId;
  final String artifactId;
  final int revision;
  final String payloadDigest;
  final String? displayLabel;

  bool sameGeneration(RetrievalArtifactSnapshot other) =>
      fileId == other.fileId &&
      artifactId == other.artifactId &&
      revision == other.revision &&
      payloadDigest == other.payloadDigest;
}

final class RetrievalScopeSnapshot {
  RetrievalScopeSnapshot(Iterable<RetrievalArtifactSnapshot> files)
      : files = List<RetrievalArtifactSnapshot>.unmodifiable(files);
  final List<RetrievalArtifactSnapshot> files;
}

final class RetrievalHit {
  const RetrievalHit({
    required this.fileId,
    required this.artifactId,
    required this.revision,
    required this.sourceId,
    required this.chunkId,
    required this.content,
    required this.contentKind,
    required this.score,
    required this.lexicalScore,
    required this.locator,
    required this.partOrdinal,
    required this.windowOrdinal,
    required this.sourceRef,
    this.nearestHeading,
    this.displayLabel,
  });
  final String fileId;
  final String artifactId;
  final int revision;
  final String sourceId;
  final String chunkId;
  final String content;
  final RetrievalContentKind contentKind;
  final double score;
  final double lexicalScore;
  double? get embeddingScore => null;
  final String locator;
  final int partOrdinal;
  final int windowOrdinal;
  final String? nearestHeading;
  final String? displayLabel;
  final SourceRef sourceRef;
}

enum RetrievalFileIssueCode {
  fileUnavailable,
  artifactMissing,
  artifactCorrupt,
  payloadUnsupported,
  indexBuildFailed,
  sourceChanged,
  unsupportedContentExcluded,
}

final class RetrievalFileIssue {
  const RetrievalFileIssue({required this.fileId, required this.code});
  final String fileId;
  final RetrievalFileIssueCode code;
}

final class RetrievalResult {
  RetrievalResult(
      {required this.frozenScopeSnapshot,
      required Iterable<RetrievalHit> rankedHits,
      required Iterable<RetrievalFileIssue> perFileIssues})
      : rankedHits = List<RetrievalHit>.unmodifiable(rankedHits),
        perFileIssues = List<RetrievalFileIssue>.unmodifiable(perFileIssues);
  final RetrievalScopeSnapshot frozenScopeSnapshot;
  final List<RetrievalHit> rankedHits;
  final List<RetrievalFileIssue> perFileIssues;
}

enum RetrievalFailure {
  invalidRequest,
  scopeEmpty,
  scopeUnavailable,
  accessDenied,
  temporarilyUnavailable,
  internalError
}

final class RetrievalException implements Exception {
  const RetrievalException(this.failure);
  final RetrievalFailure failure;
  @override
  String toString() => 'RetrievalException(${failure.name})';
}
