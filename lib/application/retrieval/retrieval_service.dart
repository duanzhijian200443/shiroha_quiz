library;

import '../../services/retrieval/deterministic_source_chunker.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'retrieval.dart';
import 'retrieval_ports.dart';

final class RetrievalService {
  RetrievalService(
      {required RetrievalScopeResolverPort scopeResolver,
      required RetrievalArtifactSourcePort artifactSource,
      required RetrievalIndexPort index,
      DeterministicSourceChunker chunker = const DeterministicSourceChunker()})
      : _scopeResolver = scopeResolver,
        _artifactSource = artifactSource,
        _index = index,
        _chunker = chunker;

  static const String lexicalProjectionVersion = 'rag1.lexical.v1';
  static const int maxQueryScalars = 200;
  static const int maxTokens = 32;
  static const int maxFiles = 64;
  static const int maxLimit = 20;
  static const int maxHitBytes = 6000;
  static const int maxResultBytes = 24000;

  final RetrievalScopeResolverPort _scopeResolver;
  final RetrievalArtifactSourcePort _artifactSource;
  final RetrievalIndexPort _index;
  final DeterministicSourceChunker _chunker;

  Future<RetrievalResult> retrieve(
      {required RetrievalScopeRequest scope,
      required String query,
      int limit = 8,
      RetrievalStrategy strategy = RetrievalStrategy.lexicalV1}) async {
    if (query.trim().isEmpty ||
        query.runes.length > maxQueryScalars ||
        limit < 1 ||
        limit > maxLimit ||
        strategy != RetrievalStrategy.lexicalV1) {
      throw const RetrievalException(RetrievalFailure.invalidRequest);
    }
    final expression = buildLexicalMatchExpression(query);
    if (expression.isEmpty) {
      throw const RetrievalException(RetrievalFailure.invalidRequest);
    }
    final rawIds = await _scopeResolver.resolveFileIds(scope);
    final fileIds = <String>{...rawIds}.toList()..sort();
    if (fileIds.isEmpty) {
      throw const RetrievalException(RetrievalFailure.scopeEmpty);
    }
    if (fileIds.length > maxFiles) {
      throw const RetrievalException(RetrievalFailure.invalidRequest);
    }

    final snapshots = <RetrievalArtifactSnapshot>[];
    final issues = <RetrievalFileIssue>[];
    for (final fileId in fileIds) {
      try {
        final loaded = await _artifactSource.loadCurrent(fileId);
        final projection = _chunker.project(
            fileId: fileId,
            artifactId: loaded.identity.artifactId,
            revision: loaded.identity.revision,
            document: loaded.sourceDocument);
        await _index.ensureBuild(
            snapshot: loaded.identity,
            chunkerVersion: DeterministicSourceChunker.chunkerVersion,
            lexicalProjectionVersion: lexicalProjectionVersion,
            chunks: projection.chunks);
        final current = await _artifactSource.readCurrentIdentity(fileId);
        if (current == null || !current.sameGeneration(loaded.identity)) {
          issues.add(RetrievalFileIssue(
              fileId: fileId, code: RetrievalFileIssueCode.sourceChanged));
          continue;
        }
        snapshots.add(loaded.identity);
        if (projection.unsupportedExcluded) {
          issues.add(RetrievalFileIssue(
              fileId: fileId,
              code: RetrievalFileIssueCode.unsupportedContentExcluded));
        }
      } on ParsedArtifactLifecycleException catch (error) {
        issues.add(RetrievalFileIssue(
          fileId: fileId,
          code: switch (error.failure) {
            ParsedArtifactLifecycleFailure.fileNotFound ||
            ParsedArtifactLifecycleFailure.sourceUnavailable =>
              RetrievalFileIssueCode.fileUnavailable,
            ParsedArtifactLifecycleFailure.artifactMissing =>
              RetrievalFileIssueCode.artifactMissing,
            ParsedArtifactLifecycleFailure.artifactCorrupt =>
              RetrievalFileIssueCode.artifactCorrupt,
            ParsedArtifactLifecycleFailure.payloadUnsupported =>
              RetrievalFileIssueCode.payloadUnsupported,
            _ => RetrievalFileIssueCode.indexBuildFailed,
          },
        ));
      } on RetrievalException catch (error) {
        if (error.failure == RetrievalFailure.invalidRequest ||
            error.failure == RetrievalFailure.accessDenied) {
          rethrow;
        }
        issues.add(RetrievalFileIssue(
            fileId: fileId, code: RetrievalFileIssueCode.indexBuildFailed));
      } catch (_) {
        issues.add(RetrievalFileIssue(
            fileId: fileId, code: RetrievalFileIssueCode.indexBuildFailed));
      }
    }
    if (snapshots.isEmpty) {
      if (issues.isEmpty) {
        throw const RetrievalException(RetrievalFailure.scopeUnavailable);
      }
      return RetrievalResult(
          frozenScopeSnapshot: RetrievalScopeSnapshot(const []),
          rankedHits: const [],
          perFileIssues: issues);
    }
    final searchResult = await _index.search(
        snapshots: snapshots,
        matchExpression: expression,
        limit: limit,
        maxHitBytes: maxHitBytes,
        maxResultBytes: maxResultBytes);
    for (final fileId in searchResult.sourceChangedFileIds) {
      issues.add(RetrievalFileIssue(
          fileId: fileId, code: RetrievalFileIssueCode.sourceChanged));
    }
    return RetrievalResult(
        frozenScopeSnapshot: RetrievalScopeSnapshot(snapshots),
        rankedHits: searchResult.hits,
        perFileIssues: issues);
  }

  Future<List<String>> resolveScopeFileIds(RetrievalScopeRequest scope) =>
      _scopeResolver.resolveFileIds(scope);

  Future<void> removeIndex(String fileId) => _index.removeIndex(fileId);
}

String buildLexicalMatchExpression(String query) {
  final words = RegExp(r'[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*')
      .allMatches(query)
      .map((m) => m.group(0)!.toLowerCase())
      .toList();
  final cjkRuns = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+')
      .allMatches(query)
      .map((m) => m.group(0)!)
      .toList();
  final groups = <String>[];
  var tokenCount = words.length;
  for (final word in words) {
    groups.add('"${word.replaceAll('"', '""')}"');
  }
  for (final run in cjkRuns) {
    final chars = run.runes.toList();
    final terms = chars.length == 1
        ? <String>[run]
        : <String>[
            for (var i = 0; i < chars.length - 1; i++)
              String.fromCharCodes(chars.sublist(i, i + 2))
          ];
    tokenCount += terms.length;
    groups.add('(${terms.map((term) => '"$term"').join(' AND ')})');
  }
  if (tokenCount > RetrievalService.maxTokens) {
    throw const RetrievalException(RetrievalFailure.invalidRequest);
  }
  return groups.join(' OR ');
}

String lexicalProjection(String input) {
  final output = <String>[];
  for (final match in RegExp(
          r'[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*|[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+')
      .allMatches(input)) {
    final token = match.group(0)!;
    final chars = token.runes.toList();
    if (RegExp(r'^[A-Za-z0-9]').hasMatch(token)) {
      output.add(token.toLowerCase());
    } else if (chars.length == 1) {
      output.add(token);
    } else {
      for (var i = 0; i < chars.length - 1; i++) {
        output.add(String.fromCharCodes(chars.sublist(i, i + 2)));
      }
    }
  }
  return output.join(' ');
}
