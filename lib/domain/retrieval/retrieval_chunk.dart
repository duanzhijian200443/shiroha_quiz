library;

import '../source/source_ref.dart';

enum RetrievalContentKind {
  paragraph,
  heading,
  formula,
  answerLike,
  table,
  imageAlt
}

final class RetrievalChunk {
  RetrievalChunk({
    required this.chunkId,
    required this.fileId,
    required this.artifactId,
    required this.revision,
    required this.sourceId,
    required this.ordinal,
    required this.kind,
    required this.locator,
    required this.partOrdinal,
    required this.windowOrdinal,
    required this.content,
    required this.contentHash,
    required this.sourceRef,
    this.heading,
  }) {
    if (sourceId != artifactId ||
        ordinal < 0 ||
        partOrdinal < 0 ||
        windowOrdinal < 0 ||
        content.isEmpty ||
        contentHash.length != 64 ||
        locator.isEmpty) {
      throw const FormatException('Invalid retrieval chunk.');
    }
  }

  final String chunkId;
  final String fileId;
  final String artifactId;
  final int revision;
  final String sourceId;
  final int ordinal;
  final RetrievalContentKind kind;
  final String locator;
  final int partOrdinal;
  final int windowOrdinal;
  final String content;
  final String contentHash;
  final String? heading;
  final SourceRef sourceRef;
}

final class RetrievalChunkProjection {
  RetrievalChunkProjection(
      {required Iterable<RetrievalChunk> chunks,
      required this.unsupportedExcluded})
      : chunks = List<RetrievalChunk>.unmodifiable(chunks);

  final List<RetrievalChunk> chunks;
  final bool unsupportedExcluded;
}
