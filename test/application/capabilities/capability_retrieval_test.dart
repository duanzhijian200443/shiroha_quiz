import 'dart:convert';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_capability.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';

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

final class _Source implements RetrievalArtifactSourcePort {
  int loads = 0;
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
      })> loadCurrent(String fileId) async {
    loads++;
    return (
      identity: identity,
      displayLabel: 'public.txt',
      sourceDocument: SourceDocument(sourceId: 'artifact-1', parts: [
        SourceContentPart(
            sourceRef: SourceRef.document(sourceId: 'artifact-1'),
            content: RichContent(nodes: const [TextNode('function')]))
      ])
    );
  }

  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async =>
      identity;
}

final class _Scope implements RetrievalScopeResolverPort {
  int calls = 0;
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async {
    calls++;
    return ['file-1'];
  }
}

final class _Index implements RetrievalIndexPort, RetrievalIndexEvidencePort {
  _Index(this.effect);
  final RetrievalBuildEffect effect;
  int builds = 0;
  bool lostBuildResponse = false;
  bool failSearch = false;
  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    builds++;
  }

  @override
  Future<RetrievalBuildEffect> ensureBuildWithEvidence(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    builds++;
    if (lostBuildResponse) throw StateError('lost response');
    return effect;
  }

  @override
  Future<RetrievalIndexSearchResult> search(
      {required List<RetrievalArtifactSnapshot> snapshots,
      required String matchExpression,
      required int limit,
      required int maxHitBytes,
      required int maxResultBytes}) async {
    if (failSearch) throw StateError('private marker');
    return RetrievalIndexSearchResult(
        hits: const [], sourceChangedFileIds: const []);
  }

  @override
  Future<void> removeIndex(String fileId) async {}
  @override
  Future<void> removeIndexGeneration(
      RetrievalArtifactSnapshot snapshot) async {}
}

CapabilityContext _context(
        {RetrievalEgressGrant? grant,
        String turn = 'turn-1',
        String conversation = 'conversation-1',
        String message = 'message-1',
        String provider = 'profile-1',
        List<String> files = const ['file-1'],
        Future<bool> Function()? release}) =>
    CapabilityContext(
        principal: CapabilityPrincipal.builtInAgent,
        capabilities: const [retrieveFileContent],
        permissions: const [CapabilityPermission.read],
        scope: ConversationScope.global(),
        authorizedScope: ConversationScope.global(),
        retrievalGrant: grant,
        turnRequestId: turn,
        sourceConversationId: conversation,
        sourceMessageId: message,
        providerProfileId: provider,
        currentFileIds: files,
        serializationAllowed: release ?? () async => true);
RetrievalEgressGrant _grant() => RetrievalEgressGrant(
    agentTurnRequestId: 'turn-1',
    conversationId: 'conversation-1',
    sourceUserMessageId: 'message-1',
    providerProfileId: 'profile-1',
    approvedFileIds: const ['file-1']);

void main() {
  test('retrieval legacy parsing and business bounds preserve exact wire codes',
      () async {
    final source = _Source();
    final scope = _Scope();
    final index = _Index(RetrievalBuildEffect.unchanged);
    final dispatcher = AgentRetrievalToolDispatcher(
        retrieval: RetrievalService(
            scopeResolver: scope,
            artifactSource: source,
            index: index,
            chunker: const DeterministicSourceChunker()));
    final cases = <String, String>{
      '{': 'internal_error',
      '[]': 'invalid_request',
      '{}': 'invalid_request',
      '{"query":"function"}': 'invalid_request',
      '{"file_ids":["file-1"]}': 'invalid_request',
      '{"query":"function","file_ids":["file-1"],"approved":true}':
          'invalid_request',
      '{"query":"function","file_ids":[1]}': 'access_denied',
      '{"query":"function","file_ids":[]}': 'access_denied',
      '{"query":"","file_ids":["file-1"]}': 'invalidRequest',
      '{"query":"function","file_ids":["file-1"],"limit":0}': 'invalidRequest',
      '{"query":"function","file_ids":["file-1"],"limit":21}': 'invalidRequest',
      jsonEncode({
        'query': 'x' * 201,
        'file_ids': ['file-1']
      }): 'invalidRequest',
      ' ' * (16 * 1024 + 1): 'invalid_request',
    };
    for (final entry in cases.entries) {
      final response = await dispatcher.dispatchWithReceipt(
          argumentsJson: entry.key,
          grant: _grant(),
          turnRequestId: 'turn-1',
          conversationId: 'conversation-1',
          sourceUserMessageId: 'message-1',
          providerProfileId: 'profile-1',
          currentFileIds: ['file-1'],
          serializationAllowed: () async => true);
      expect(jsonDecode(response.json), {
        'ok': false,
        'error': {
          'code': entry.value,
          'message': 'File content is unavailable.',
          'retryable': false
        }
      });
      expect(response.receipt.knownEffect, CapabilityEffect.none);
    }
    expect(scope.calls, 0);
    expect(source.loads, 0);
    expect(index.builds, 0);
  });

  test(
      'direct executor rejects missing grant and every recipient/scope mismatch before retrieval',
      () async {
    final scope = _Scope();
    final source = _Source();
    final index = _Index(RetrievalBuildEffect.derivedCache);
    final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
      retrievalCapability(RetrievalService(
          scopeResolver: scope,
          artifactSource: source,
          index: index,
          chunker: const DeterministicSourceChunker()))
    ]));
    final input =
        RetrieveFileContentInput(query: 'function', fileIds: ['file-1']);
    for (final context in [
      _context(),
      _context(grant: _grant(), turn: 'wrong'),
      _context(grant: _grant(), conversation: 'wrong'),
      _context(grant: _grant(), message: 'wrong'),
      _context(grant: _grant(), provider: 'wrong'),
      _context(grant: _grant(), files: const [])
    ]) {
      final result =
          await executor.execute(retrieveFileContent, input, context);
      expect(result.failure, CapabilityFailure.accessDenied);
      expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
    }
    expect(scope.calls, 0);
    expect(source.loads, 0);
    expect(index.builds, 0);
  });

  test(
      'owning index evidence distinguishes READ cache hit from derived-cache commit',
      () async {
    for (final effect in RetrievalBuildEffect.values) {
      final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
        retrievalCapability(RetrievalService(
            scopeResolver: _Scope(),
            artifactSource: _Source(),
            index: _Index(effect),
            chunker: const DeterministicSourceChunker()))
      ]));
      final result = await executor.execute(
          retrieveFileContent,
          RetrieveFileContentInput(query: 'function', fileIds: ['file-1']),
          _context(grant: _grant()));
      expect(result.output, isNotNull);
      expect(result.receipt.status, CapabilityExecutionStatus.completed);
      expect(
          result.receipt.knownEffect,
          effect == RetrievalBuildEffect.unchanged
              ? CapabilityEffect.none
              : CapabilityEffect.derivedCache);
      expect(result.receipt.authorization.providerProfileId, 'profile-1');
    }
  });

  test(
      'revocation before release blocks content and retains confirmed derived-cache effect',
      () async {
    final index = _Index(RetrievalBuildEffect.derivedCache);
    final service = RetrievalService(
        scopeResolver: _Scope(),
        artifactSource: _Source(),
        index: index,
        chunker: const DeterministicSourceChunker());
    final executor = CapabilityExecutor(
        ApplicationCapabilityRegistry([retrievalCapability(service)]));
    final result = await executor.execute(
        retrieveFileContent,
        RetrieveFileContentInput(query: 'function', fileIds: ['file-1']),
        _context(
            grant: _grant(),
            release: () async {
              expect(index.builds, 1);
              return false;
            }));
    expect(result.output, isNull);
    expect(result.failure, CapabilityFailure.accessDenied);
    expect(result.receipt.status, CapabilityExecutionStatus.completed);
    expect(result.receipt.knownEffect, CapabilityEffect.derivedCache);
    final response = await AgentRetrievalToolDispatcher(
            retrieval: service, executor: executor)
        .dispatchWithReceipt(
            argumentsJson: '{"query":"function","file_ids":["file-1"]}',
            grant: _grant(),
            turnRequestId: 'turn-1',
            conversationId: 'conversation-1',
            sourceUserMessageId: 'message-1',
            providerProfileId: 'profile-1',
            currentFileIds: ['file-1'],
            serializationAllowed: () async => false);
    expect(jsonDecode(response.json)['error']['code'], 'access_denied');
    expect(response.receipt.knownEffect, CapabilityEffect.derivedCache);
  });

  test(
      'lost index response is unknown; failure after committed cache preserves known effect',
      () async {
    for (final lost in [true, false]) {
      final index = _Index(RetrievalBuildEffect.derivedCache)
        ..lostBuildResponse = lost
        ..failSearch = !lost;
      final executor = CapabilityExecutor(ApplicationCapabilityRegistry([
        retrievalCapability(RetrievalService(
            scopeResolver: _Scope(),
            artifactSource: _Source(),
            index: index,
            chunker: const DeterministicSourceChunker()))
      ]));
      final result = await executor.execute(
          retrieveFileContent,
          RetrieveFileContentInput(query: 'function', fileIds: ['file-1']),
          _context(grant: _grant()));
      expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(result.receipt.knownEffect,
          lost ? isNull : CapabilityEffect.derivedCache);
      expect(index.builds, 1);
    }
  });
}
