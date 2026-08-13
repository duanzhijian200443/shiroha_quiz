library;

import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../application/parsed_artifacts/parsed_artifact_ports.dart';
import '../../application/retrieval/retrieval.dart';
import '../../application/retrieval/retrieval_ports.dart';
import '../../domain/source/source_document.dart';

final class ParsedArtifactRetrievalSource
    implements RetrievalArtifactSourcePort {
  ParsedArtifactRetrievalSource(
      {required ParsedArtifactLifecyclePort lifecycle,
      required ParsedArtifactRepositoryPort metadata})
      : _lifecycle = lifecycle,
        _metadata = metadata;

  final ParsedArtifactLifecyclePort _lifecycle;
  final ParsedArtifactRepositoryPort _metadata;

  @override
  Future<
      ({
        RetrievalArtifactSnapshot identity,
        String? displayLabel,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId) async {
    final snapshot = await _lifecycle.getCurrentArtifact(fileId);
    final metadata = await _metadata.findCurrentByFileId(fileId);
    if (metadata == null ||
        metadata.artifactId != snapshot.artifact.artifactId ||
        metadata.revision != snapshot.artifact.revision) {
      throw const RetrievalException(RetrievalFailure.temporarilyUnavailable);
    }
    return (
      identity: RetrievalArtifactSnapshot(
          fileId: fileId,
          artifactId: metadata.artifactId,
          revision: metadata.revision,
          payloadDigest: metadata.payloadSha256,
          displayLabel: snapshot.sourceDocument.documentRef.displayLabel),
      displayLabel: snapshot.sourceDocument.documentRef.displayLabel,
      sourceDocument: snapshot.sourceDocument,
    );
  }

  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async {
    final metadata = await _metadata.findCurrentByFileId(fileId);
    return metadata == null
        ? null
        : RetrievalArtifactSnapshot(
            fileId: fileId,
            artifactId: metadata.artifactId,
            revision: metadata.revision,
            payloadDigest: metadata.payloadSha256);
  }
}
