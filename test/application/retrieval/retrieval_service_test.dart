import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/retrieval/retrieval_chunk.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';

void main() {
  test('query grammar treats input as data and projects CJK conjunction groups',
      () {
    expect(buildLexicalMatchExpression('函数 OR "evil" 2024'),
        '"or" OR "evil" OR "2024" OR ("函数")');
    expect(buildLexicalMatchExpression('二次函数'), '("二次" AND "次函" AND "函数")');
    expect(
        () => buildLexicalMatchExpression('一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四'),
        throwsA(isA<RetrievalException>()));
  });

  test(
      'captures ordered distinct scope, ensures exact build, and returns partial issues',
      () async {
    final source = _Source();
    final index = _Index();
    final service = RetrievalService(
        scopeResolver: _Scope(['b', 'a', 'b']),
        artifactSource: source,
        index: index,
        chunker: const DeterministicSourceChunker());
    source.failures['b'] =
        const RetrievalException(RetrievalFailure.temporarilyUnavailable);
    final result = await service.retrieve(
        scope: RetrievalFilesScope(['ignored']), query: '二次函数');
    expect(result.frozenScopeSnapshot.files.map((s) => s.fileId), ['a']);
    expect(index.ensured.single.fileId, 'a');
    expect(index.expression, '("二次" AND "次函" AND "函数")');
    expect(result.perFileIssues.single.code,
        RetrievalFileIssueCode.indexBuildFailed);
  });

  test(
      'generation change after ensure becomes sourceChanged and never searches stale build',
      () async {
    final source = _Source()..changeAfterLoad = true;
    final index = _Index();
    final service = RetrievalService(
        scopeResolver: _Scope(['a']),
        artifactSource: source,
        index: index,
        chunker: const DeterministicSourceChunker());
    final result = await service.retrieve(
        scope: RetrievalFilesScope(['a']), query: 'function');
    expect(result.rankedHits, isEmpty);
    expect(
        result.perFileIssues.single.code, RetrievalFileIssueCode.sourceChanged);
    expect(index.searchCalls, 0);
  });
}

final class _Scope implements RetrievalScopeResolverPort {
  _Scope(this.ids);
  final List<String> ids;
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async => ids;
}

final class _Source implements RetrievalArtifactSourcePort {
  final failures = <String, Object>{};
  bool changeAfterLoad = false;
  @override
  Future<
      ({
        String? displayLabel,
        RetrievalArtifactSnapshot identity,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId) async {
    final failure = failures[fileId];
    if (failure != null) throw failure;
    const artifact = 'artifact-1';
    return (
      identity: RetrievalArtifactSnapshot(
          fileId: fileId,
          artifactId: artifact,
          revision: 1,
          payloadDigest: 'a' * 64),
      displayLabel: 'public.txt',
      sourceDocument: SourceDocument(sourceId: artifact, parts: [
        SourceContentPart(
            sourceRef: SourceRef.document(sourceId: artifact),
            content: RichContent(nodes: const [TextNode('二次函数')]))
      ])
    );
  }

  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async =>
      RetrievalArtifactSnapshot(
          fileId: fileId,
          artifactId: changeAfterLoad ? 'artifact-2' : 'artifact-1',
          revision: changeAfterLoad ? 2 : 1,
          payloadDigest: (changeAfterLoad ? 'b' : 'a') * 64);
}

final class _Index implements RetrievalIndexPort {
  final ensured = <RetrievalArtifactSnapshot>[];
  String? expression;
  int searchCalls = 0;
  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    ensured.add(snapshot);
  }

  @override
  Future<void> removeIndex(String fileId) async {}
  @override
  Future<RetrievalIndexSearchResult> search(
      {required List<RetrievalArtifactSnapshot> snapshots,
      required String matchExpression,
      required int limit,
      required int maxHitBytes,
      required int maxResultBytes}) async {
    searchCalls++;
    expression = matchExpression;
    return RetrievalIndexSearchResult(
        hits: const <RetrievalHit>[], sourceChangedFileIds: const <String>[]);
  }
}
