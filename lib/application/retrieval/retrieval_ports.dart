library;

import '../../domain/retrieval/retrieval_chunk.dart';
import '../../domain/source/source_document.dart';
import 'retrieval.dart';

abstract interface class RetrievalScopeResolverPort {
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope);
}

abstract interface class RetrievalArtifactSourcePort {
  Future<
      ({
        RetrievalArtifactSnapshot identity,
        String? displayLabel,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId);
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId);
}

abstract interface class RetrievalChunkerPort {
  String get version;
  RetrievalChunkProjection project({
    required String fileId,
    required String artifactId,
    required int revision,
    required SourceDocument document,
  });
}

abstract interface class RetrievalIndexPort {
  Future<void> ensureBuild({
    required RetrievalArtifactSnapshot snapshot,
    required String chunkerVersion,
    required String lexicalProjectionVersion,
    required List<RetrievalChunk> chunks,
  });
  Future<RetrievalIndexSearchResult> search({
    required List<RetrievalArtifactSnapshot> snapshots,
    required String matchExpression,
    required int limit,
    required int maxHitBytes,
    required int maxResultBytes,
  });

  /// Invalidates all derived retrieval rows for [fileId]. This operation is
  /// idempotent and safe to retry after a failed cleanup.
  Future<void> removeIndex(String fileId);

  /// Invalidates only the derived retrieval rows for [snapshot]. This is the
  /// generation-aware replacement cleanup; newer generations for the same
  /// file remain untouched.
  Future<void> removeIndexGeneration(RetrievalArtifactSnapshot snapshot);
}

final class RetrievalIndexSearchResult {
  RetrievalIndexSearchResult({
    required Iterable<RetrievalHit> hits,
    required Iterable<String> sourceChangedFileIds,
  })  : hits = List<RetrievalHit>.unmodifiable(hits),
        sourceChangedFileIds = List<String>.unmodifiable(sourceChangedFileIds);
  final List<RetrievalHit> hits;
  final List<String> sourceChangedFileIds;
}

/// Optional transaction evidence supplied by an owning index adapter. A legacy
/// adapter's successful void response cannot prove whether a build was written.
enum RetrievalBuildEffect { unchanged, derivedCache }

abstract interface class RetrievalIndexEvidencePort {
  Future<RetrievalBuildEffect> ensureBuildWithEvidence({
    required RetrievalArtifactSnapshot snapshot,
    required String chunkerVersion,
    required String lexicalProjectionVersion,
    required List<RetrievalChunk> chunks,
  });
}

/// Per-invocation evidence, never persisted. An unconfirmed index call may
/// have committed even when its response was lost.
final class RetrievalExecutionEvidence {
  RetrievalExecutionEvidence({this.onDerivedCacheCommitted});
  final void Function()? onDerivedCacheCommitted;
  int _unconfirmedBuilds = 0;
  bool _derivedCacheWritten = false;
  bool get effectKnown => _unconfirmedBuilds == 0;
  bool get derivedCacheWritten => _derivedCacheWritten;
  void buildEntered() => _unconfirmedBuilds++;
  void buildCompleted(RetrievalBuildEffect effect) {
    _unconfirmedBuilds--;
    if (effect == RetrievalBuildEffect.derivedCache) {
      _derivedCacheWritten = true;
      onDerivedCacheCommitted?.call();
    }
  }
}
