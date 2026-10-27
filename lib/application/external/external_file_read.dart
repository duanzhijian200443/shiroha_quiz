import 'dart:convert';

import '../../domain/retrieval/retrieval_chunk.dart';
import '../../domain/source/source_document.dart';
import '../../domain/source/source_part.dart';
import '../../domain/content/content_node.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../parsed_artifacts/parsed_artifact_ports.dart';
import '../retrieval/retrieval.dart';
import '../retrieval/retrieval_ports.dart';
import '../retrieval/retrieval_service.dart';
import 'external_read_context.dart';

/// Policy/relationship authority remains the existing SQLite Grant owner.
abstract interface class ExternalFileReadPort {
  Future<ExternalFileChoicePage> listChoices(ExternalQuestionReadAccess access,
      int pageSize, String? afterFileId, void Function() check);
  Future<List<RetrievalArtifactSnapshot>> query(
      ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot>? selected,
      void Function() check);
}

final class ExternalFileChoicePage {
  const ExternalFileChoicePage(this.files,
      {this.nextFileId, this.unsupportedExcluded = false});
  final List<RetrievalArtifactSnapshot> files;
  final String? nextFileId;
  final bool unsupportedExcluded;
}

/// Fixed safe failure plus real RAG transaction evidence, including pending
/// uncertainty. The evidence can settle after an interrupted caller returns.
final class ExternalFileReadException implements Exception {
  ExternalFileReadException(this.failure, this.evidence);
  final ExternalReadFailure failure;
  final RetrievalExecutionEvidence evidence;
  @override
  String toString() => 'ExternalFileReadException(${failure.name})';
}

/// Read-current-only F1 adapter. Unlike lazy Built-in retrieval, never parses.
final class ExternalVerifiedArtifactSource
    implements RetrievalArtifactSourcePort {
  ExternalVerifiedArtifactSource(
      {required this.lifecycle, required this.metadata});
  final ParsedArtifactLifecyclePort lifecycle;
  final ParsedArtifactRepositoryPort metadata;

  @override
  Future<
      ({
        RetrievalArtifactSnapshot identity,
        String? displayLabel,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId) async {
    final before = await metadata.findCurrentByFileId(fileId);
    final verified = await lifecycle.getCurrentArtifact(fileId);
    final after = await metadata.findCurrentByFileId(fileId);
    if (before == null ||
        after != before ||
        verified.artifact != before.artifact) {
      externalReadFail(ExternalReadFailure.stale);
    }
    return (
      identity: _identity(before),
      displayLabel: null,
      sourceDocument: verified.sourceDocument
    );
  }

  RetrievalArtifactSnapshot _identity(ParsedArtifactMetadata value) =>
      RetrievalArtifactSnapshot(
          fileId: value.fileId,
          artifactId: value.artifactId,
          revision: value.revision,
          payloadDigest: value.payloadSha256);

  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async {
    final value = await metadata.findCurrentByFileId(fileId);
    return value == null ? null : _identity(value);
  }
}

/// Internal orchestration/projection; references are minted only by P4.
final class ExternalFileReader {
  ExternalFileReader(
      {required this.authorization,
      required this.source,
      required this.index,
      required this.chunker});
  final ExternalFileReadPort authorization;
  final ExternalVerifiedArtifactSource source;
  final RetrievalIndexPort index;
  final RetrievalChunkerPort chunker;

  Future<void> authorize(ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot> files, void Function() check) async {
    check();
    access.validate();
    if (files.isEmpty || files.length > RetrievalService.maxFiles) {
      externalReadFail(ExternalReadFailure.denied);
    }
    await authorization.query(access, files, check);
    check();
    access.validate();
  }

  Future<RetrievalChunkProjection> project(
      ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot> files,
      RetrievalArtifactSnapshot file,
      void Function() check) async {
    await authorize(access, files, check);
    try {
      final loaded = await source.loadCurrent(file.fileId);
      check();
      if (!loaded.identity.sameGeneration(file)) {
        externalReadFail(ExternalReadFailure.stale);
      }
      final projection = chunker.project(
          fileId: file.fileId,
          artifactId: file.artifactId,
          revision: file.revision,
          document: loaded.sourceDocument);
      // The existing chunker can window oversized formulas. External passage
      // never releases a partial formula; fail safely instead of truncating.
      bool containsMath(SourcePart part) {
        final nodes = switch (part) {
          SourceContentPart(:final content) => content.nodes,
          SourceTablePart(:final rows) =>
            rows.expand((r) => r).expand((c) => c.nodes),
          SourceAssetPart(:final alternativeText) =>
            alternativeText?.nodes ?? const <ContentNode>[],
          UnsupportedSourcePart() => const <ContentNode>[],
        };
        return nodes.any((n) => n is InlineMathNode || n is BlockMathNode);
      }

      if (projection.chunks.any((c) =>
          c.windowOrdinal > 0 &&
          containsMath(loaded.sourceDocument.parts[c.partOrdinal]))) {
        externalReadFail(ExternalReadFailure.resourceLimit);
      }
      await authorize(access, files, check);
      return projection;
    } on ParsedArtifactLifecycleException catch (error) {
      externalReadFail(switch (error.failure) {
        ParsedArtifactLifecycleFailure.artifactMissing ||
        ParsedArtifactLifecycleFailure.fileNotFound ||
        ParsedArtifactLifecycleFailure.sourceUnavailable =>
          ExternalReadFailure.sourceNotReady,
        ParsedArtifactLifecycleFailure.artifactCorrupt ||
        ParsedArtifactLifecycleFailure.payloadUnsupported =>
          ExternalReadFailure.dataCorrupt,
        _ => ExternalReadFailure.unavailable,
      });
    }
  }

  Future<void> release(ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot> files, void Function() check) async {
    // Verify payload integrity again, then current SQLite policy/tuples last.
    for (final file in files) {
      await project(access, files, file, check);
    }
    await authorize(access, files, check);
  }

  Future<RetrievalResult> retrieve(
      ExternalQuestionReadAccess access,
      List<RetrievalArtifactSnapshot> files,
      String query,
      int limit,
      RetrievalExecutionEvidence evidence,
      void Function() check) async {
    if (query.trim().isEmpty ||
        query.runes.length > RetrievalService.maxQueryScalars ||
        limit < 1 ||
        limit > RetrievalService.maxLimit) {
      externalReadFail(ExternalReadFailure.invalidRequest);
    }
    try {
      if (buildLexicalMatchExpression(query).isEmpty) {
        externalReadFail(ExternalReadFailure.invalidRequest);
      }
    } on RetrievalException {
      externalReadFail(ExternalReadFailure.invalidRequest);
    }
    await authorize(access, files, check);
    final retrieval = RetrievalService(
        scopeResolver: _FilesOnly(files),
        artifactSource: source,
        index: index,
        chunker: chunker);
    final result = await retrieval.retrieve(
        scope: RetrievalFilesScope(files.map((f) => f.fileId)),
        query: query,
        limit: limit,
        executionEvidence: evidence,
        validateAccess: () => authorize(access, files, check));
    check();
    if (result.perFileIssues.any(
        (i) => i.code != RetrievalFileIssueCode.unsupportedContentExcluded)) {
      externalReadFail(result.perFileIssues.any((i) =>
              i.code == RetrievalFileIssueCode.artifactCorrupt ||
              i.code == RetrievalFileIssueCode.payloadUnsupported)
          ? ExternalReadFailure.dataCorrupt
          : ExternalReadFailure.stale);
    }
    return result;
  }
}

final class _FilesOnly implements RetrievalScopeResolverPort {
  _FilesOnly(this.files);
  final List<RetrievalArtifactSnapshot> files;
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async {
    if (scope is! RetrievalFilesScope ||
        scope.fileIds.length != files.length ||
        !files.every((f) => scope.fileIds.contains(f.fileId))) {
      throw const RetrievalException(RetrievalFailure.accessDenied);
    }
    return scope.fileIds;
  }
}

/// No SourceRef JSON, block ids, storage identities, label or nearest heading.
/// Locator is recomputed from verified ordinal/page values only.
Map<String, Object?> externalSafeChunk(RetrievalChunk chunk) => {
      'content': chunk.content,
      'contentKind': chunk.kind.name,
      'locator': 'part:${chunk.partOrdinal}/window:${chunk.windowOrdinal}',
      'chunkOrdinal': chunk.ordinal,
      'partOrdinal': chunk.partOrdinal,
      'windowOrdinal': chunk.windowOrdinal,
      'pageNumber': chunk.sourceRef.start?.pageNumber,
    };

int externalFileEncodedBytes(Object value) =>
    utf8.encode(jsonEncode(value)).length;
