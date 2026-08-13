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
  Future<void> removeIndex(String fileId);
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
