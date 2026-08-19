import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_retrieval_tool.dart';
import 'package:shiroha_quiz/application/agent/retrieval_egress_grant.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_service.dart';
import 'package:shiroha_quiz/domain/retrieval/retrieval_chunk.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';

void main() {
  final grant = RetrievalEgressGrant(
      agentTurnRequestId: 'turn-1',
      conversationId: 'conversation-1',
      sourceUserMessageId: 'message-1',
      providerProfileId: 'profile-1',
      approvedFileIds: ['file-1']);
  AgentRetrievalToolDispatcher dispatcher({_Index? index}) =>
      AgentRetrievalToolDispatcher(
          retrieval: RetrievalService(
              scopeResolver: _Scope(),
              artifactSource: _Source(),
              index: index ?? _Index(),
              chunker: const DeterministicSourceChunker()));

  test('catalog is separate and dispatcher denies missing or mismatched grant',
      () async {
    expect(AgentRetrievalToolCatalog.toolName, 'retrieve_file_content');
    final arguments = jsonEncode({
      'query': 'function',
      'file_ids': ['file-1']
    });
    for (final invalid in <RetrievalEgressGrant?>[null, grant]) {
      final output = await dispatcher().dispatch(
          argumentsJson: arguments,
          grant: invalid,
          turnRequestId: invalid == null ? 'turn-1' : 'turn-other',
          conversationId: 'conversation-1',
          sourceUserMessageId: 'message-1',
          providerProfileId: 'profile-1',
          currentFileIds: ['file-1'],
          serializationAllowed: () async => true);
      expect(jsonDecode(output)['error']['code'], 'access_denied');
    }
  });

  test('provider, file snapshot, and serialization-time checks are mandatory',
      () async {
    final arguments = jsonEncode({
      'query': 'function',
      'file_ids': ['file-1']
    });
    for (final profile in ['profile-other', 'profile-1']) {
      final output = await dispatcher().dispatch(
          argumentsJson: arguments,
          grant: grant,
          turnRequestId: 'turn-1',
          conversationId: 'conversation-1',
          sourceUserMessageId: 'message-1',
          providerProfileId: profile,
          currentFileIds: ['file-1'],
          serializationAllowed: () async => profile != 'profile-1');
      expect(jsonDecode(output)['error']['code'], 'access_denied');
    }
  });

  test('valid grant returns only bounded safe retrieval DTO fields', () async {
    final output = await dispatcher().dispatch(
        argumentsJson: jsonEncode({
          'query': 'function',
          'file_ids': ['file-1']
        }),
        grant: grant,
        turnRequestId: 'turn-1',
        conversationId: 'conversation-1',
        sourceUserMessageId: 'message-1',
        providerProfileId: 'profile-1',
        currentFileIds: ['file-1'],
        serializationAllowed: () async => true);
    final decoded = jsonDecode(output) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(jsonEncode(decoded), isNot(contains('storage_key')));
    expect(jsonEncode(decoded), isNot(contains('path')));
  });

  test('rejects extra JSON fields and unapproved scope expansion', () async {
    final invalid = await dispatcher().dispatch(
        argumentsJson: jsonEncode({
          'query': 'function',
          'file_ids': ['file-1'],
          'unexpected': true
        }),
        grant: grant,
        turnRequestId: 'turn-1',
        conversationId: 'conversation-1',
        sourceUserMessageId: 'message-1',
        providerProfileId: 'profile-1',
        currentFileIds: ['file-1', 'file-new'],
        serializationAllowed: () async => true);
    expect(jsonDecode(invalid)['error']['code'], 'invalid_request');

    final expanded = await dispatcher().dispatch(
        argumentsJson: jsonEncode({
          'query': 'function',
          'file_ids': ['file-new']
        }),
        grant: grant,
        turnRequestId: 'turn-1',
        conversationId: 'conversation-1',
        sourceUserMessageId: 'message-1',
        providerProfileId: 'profile-1',
        currentFileIds: ['file-1', 'file-new'],
        serializationAllowed: () async => true);
    expect(jsonDecode(expanded)['error']['code'], 'access_denied');
  });

  test('trims lowest-ranked whole hits to the serialized response budget',
      () async {
    final hits = <RetrievalHit>[
      for (var index = 0; index < 8; index++)
        _hit(
          index,
          heading: 'heading-$index-${'h' * 10000}',
        ),
    ];
    final output = await dispatcher(index: _Index(hits: hits)).dispatch(
        argumentsJson: jsonEncode({
          'query': 'function',
          'file_ids': ['file-1']
        }),
        grant: grant,
        turnRequestId: 'turn-1',
        conversationId: 'conversation-1',
        sourceUserMessageId: 'message-1',
        providerProfileId: 'profile-1',
        currentFileIds: ['file-1'],
        serializationAllowed: () async => true);

    final decoded = jsonDecode(output) as Map<String, dynamic>;
    final returned =
        (decoded['result'] as Map<String, dynamic>)['hits'] as List;
    expect(decoded['ok'], isTrue);
    expect(utf8.encode(output).length, lessThanOrEqualTo(64 * 1024));
    expect(returned.length, lessThan(hits.length));
    expect(returned, isNotEmpty);
    expect(returned.first['chunk_id'], 'chunk-0');
    expect(
      returned.map((hit) => hit['chunk_id']),
      <String>[
        for (var index = 0; index < returned.length; index++) 'chunk-$index'
      ],
    );
  });

  test('drops a pathological whole hit and still returns bounded valid JSON',
      () async {
    final output = await dispatcher(
      index: _Index(hits: <RetrievalHit>[
        _hit(0, heading: 'h' * (80 * 1024)),
      ]),
    ).dispatch(
        argumentsJson: jsonEncode({
          'query': 'function',
          'file_ids': ['file-1']
        }),
        grant: grant,
        turnRequestId: 'turn-1',
        conversationId: 'conversation-1',
        sourceUserMessageId: 'message-1',
        providerProfileId: 'profile-1',
        currentFileIds: ['file-1'],
        serializationAllowed: () async => true);

    final decoded = jsonDecode(output) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(utf8.encode(output).length, lessThanOrEqualTo(64 * 1024));
    expect((decoded['result'] as Map<String, dynamic>)['hits'], isEmpty);
  });
}

final class _Scope implements RetrievalScopeResolverPort {
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async =>
      ['file-1'];
}

final class _Source implements RetrievalArtifactSourcePort {
  final identity = RetrievalArtifactSnapshot(
      fileId: 'file-1',
      artifactId: 'artifact-1',
      revision: 1,
      payloadDigest: 'a' * 64);
  @override
  Future<
      ({
        String? displayLabel,
        RetrievalArtifactSnapshot identity,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId) async => (
        identity: identity,
        displayLabel: 'public.txt',
        sourceDocument: SourceDocument(sourceId: 'artifact-1', parts: [
          SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'artifact-1'),
              content: RichContent(nodes: const [TextNode('function')]))
        ])
      );
  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async =>
      identity;
}

final class _Index implements RetrievalIndexPort {
  _Index({this.hits = const <RetrievalHit>[]});

  final List<RetrievalHit> hits;

  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {}
  @override
  Future<void> removeIndex(String fileId) async {}

  @override
  Future<void> removeIndexGeneration(
      RetrievalArtifactSnapshot snapshot) async {}

  @override
  Future<RetrievalIndexSearchResult> search(
          {required List<RetrievalArtifactSnapshot> snapshots,
          required String matchExpression,
          required int limit,
          required int maxHitBytes,
          required int maxResultBytes}) async =>
      RetrievalIndexSearchResult(
          hits: hits, sourceChangedFileIds: const <String>[]);
}

RetrievalHit _hit(int index, {required String heading}) => RetrievalHit(
      fileId: 'file-1',
      artifactId: 'artifact-1',
      revision: 1,
      sourceId: 'artifact-1',
      chunkId: 'chunk-$index',
      content: 'function result $index',
      contentKind: RetrievalContentKind.paragraph,
      score: 100 - index.toDouble(),
      lexicalScore: 100 - index.toDouble(),
      locator: 'part:$index',
      partOrdinal: index,
      windowOrdinal: 0,
      nearestHeading: heading,
      displayLabel: 'public.txt',
      sourceRef: SourceRef.document(sourceId: 'artifact-1'),
    );
