library;

import 'dart:convert';

import '../retrieval/retrieval.dart';
import '../retrieval/retrieval_service.dart';
import '../retrieval/retrieval_capability.dart';
import '../capabilities/capability.dart';
import 'agent_tool_projection.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/source/source_ref.dart';
import 'agent_provider.dart';
import 'retrieval_egress_grant.dart';

final class AgentRetrievalToolCatalog {
  const AgentRetrievalToolCatalog();
  static const String toolName = 'retrieve_file_content';
  static final AgentFunctionToolDefinition definition =
      AgentFunctionToolDefinition(
    name: toolName,
    description:
        'Search only file content explicitly approved for this turn. Use the '
        'exact file_ids listed in the system prompt. Use this tool, not study '
        'tools, when the answer depends on an attachment.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'query': <String, Object?>{
          'type': 'string',
          'minLength': 1,
          'maxLength': 200
        },
        'file_ids': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
          'minItems': 1,
          'maxItems': 64
        },
        'limit': <String, Object?>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 20,
          'default': 8
        },
      },
      'required': <String>['query', 'file_ids'],
    },
  );
}

final class AgentRetrievalToolProjection {
  AgentRetrievalToolProjection(
      {required RetrievalService retrieval, CapabilityExecutor? executor})
      : _retrieval = retrieval,
        _executor = executor ??
            CapabilityExecutor(ApplicationCapabilityRegistry(
                [retrievalCapability(retrieval)]));
  final RetrievalService _retrieval;
  final CapabilityExecutor _executor;
  static const int _maxArgumentsBytes = 16 * 1024;
  static const int _maxResultBytes = 64 * 1024;

  Future<List<String>> effectiveFileIds({
    required ConversationScope scope,
    required List<String> conversationFileIds,
  }) async {
    if (scope.kind == ConversationScopeKind.global) {
      return List<String>.unmodifiable(conversationFileIds);
    }
    final projectId = scope.projectId;
    if (projectId == null) return const <String>[];
    final projectFileIds =
        (await _retrieval.resolveScopeFileIds(RetrievalProjectScope(projectId)))
            .toSet();
    return List<String>.unmodifiable(
        conversationFileIds.where(projectFileIds.contains));
  }

  Future<AgentToolDispatchResult> dispatchWithReceipt(
      {required String argumentsJson,
      required CapabilityContext context}) async {
    AgentToolDispatchResult reject(CapabilityFailure code, String wireCode) =>
        AgentToolDispatchResult(
            json: _failure(wireCode),
            receipt:
                _executor.reject(retrieveFileContent, context, code).receipt);
    // Preserve legacy precedence: grant denial precedes JSON shape errors.
    if (!retrievalContextPermits(context)) {
      return reject(CapabilityFailure.accessDenied, 'access_denied');
    }
    final RetrieveFileContentInput input;
    try {
      if (utf8.encode(argumentsJson).length > _maxArgumentsBytes) {
        return reject(CapabilityFailure.invalidRequest, 'invalid_request');
      }
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.any(
              (key) => key != 'query' && key != 'file_ids' && key != 'limit') ||
          decoded['query'] is! String ||
          decoded['file_ids'] is! List ||
          decoded['limit'] != null && decoded['limit'] is! int) {
        return reject(CapabilityFailure.invalidRequest, 'invalid_request');
      }
      final requested = (decoded['file_ids'] as List)
          .whereType<String>()
          .toList(growable: false);
      if (requested.length != (decoded['file_ids'] as List).length) {
        return reject(CapabilityFailure.accessDenied, 'access_denied');
      }
      input = RetrieveFileContentInput(
          query: decoded['query'] as String,
          fileIds: requested,
          limit: decoded['limit'] as int? ?? 8);
    } catch (_) {
      return reject(CapabilityFailure.internalError, 'internal_error');
    }
    final result = await _executor.execute(retrieveFileContent, input, context);
    if (result.failure case final failure?) {
      return AgentToolDispatchResult(
          json: _failure(switch (failure) {
            CapabilityFailure.accessDenied => 'access_denied',
            CapabilityFailure.retrievalAccessDenied => 'accessDenied',
            CapabilityFailure.invalidRequest => 'invalidRequest',
            CapabilityFailure.retrievalScopeEmpty => 'scopeEmpty',
            CapabilityFailure.retrievalScopeUnavailable => 'scopeUnavailable',
            CapabilityFailure.retrievalSourceChanged => 'sourceChanged',
            CapabilityFailure.retrievalTemporarilyUnavailable =>
              'temporarilyUnavailable',
            CapabilityFailure.retrievalInternalError => 'internalError',
            _ => 'internal_error',
          }),
          receipt: result.receipt);
    }
    try {
      return AgentToolDispatchResult(
          json: _boundedSuccess(result.output!), receipt: result.receipt);
    } catch (_) {
      return AgentToolDispatchResult(
          json: _failure('internal_error'),
          receipt:
              result.receipt.withFailure(CapabilityFailure.encodingFailed));
    }
  }

  String _boundedSuccess(RetrievalResult result) {
    final hits = <Map<String, Object?>>[
      for (final hit in result.rankedHits)
        <String, Object?>{
          'file_id': hit.fileId,
          'artifact_id': hit.artifactId,
          'revision': hit.revision,
          'source_id': hit.sourceId,
          'chunk_id': hit.chunkId,
          'content': hit.content,
          'content_kind': hit.contentKind.name,
          'score': hit.score,
          'lexical_score': hit.lexicalScore,
          'embedding_score': null,
          'locator': hit.locator,
          'part_ordinal': hit.partOrdinal,
          'window_ordinal': hit.windowOrdinal,
          'nearest_heading': hit.nearestHeading,
          'display_label': hit.displayLabel,
          'source_ref': _sourceRefJson(hit.sourceRef),
        }
    ];
    final issues = <Map<String, Object?>>[
      for (final issue in result.perFileIssues)
        <String, Object?>{'file_id': issue.fileId, 'code': issue.code.name}
    ];
    String encode() => jsonEncode(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{'hits': hits, 'issues': issues},
        });

    var encoded = encode();
    while (utf8.encode(encoded).length > _maxResultBytes && hits.isNotEmpty) {
      hits.removeLast();
      encoded = encode();
    }
    while (utf8.encode(encoded).length > _maxResultBytes && issues.isNotEmpty) {
      issues.removeLast();
      encoded = encode();
    }
    return encoded;
  }

  String _failure(String code) => jsonEncode(<String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': code,
          'message': 'File content is unavailable.',
          'retryable': false
        }
      });

  Map<String, Object?> _sourceRefJson(SourceRef ref) {
    Map<String, Object?> point(SourcePoint value) => <String, Object?>{
          'page_number': value.pageNumber,
          'block_id': value.blockId,
          'reading_order': value.readingOrder,
        };
    return <String, Object?>{
      'source_id': ref.sourceId,
      'display_label': ref.displayLabel,
      'start': ref.start == null ? null : point(ref.start!),
      'end': ref.end == null ? null : point(ref.end!),
    };
  }
}

final class AgentRetrievalToolDispatcher {
  AgentRetrievalToolDispatcher(
      {required RetrievalService retrieval, CapabilityExecutor? executor})
      : _projection = AgentRetrievalToolProjection(
            retrieval: retrieval, executor: executor);
  final AgentRetrievalToolProjection _projection;
  Future<List<String>> effectiveFileIds(
          {required ConversationScope scope,
          required List<String> conversationFileIds}) =>
      _projection.effectiveFileIds(
          scope: scope, conversationFileIds: conversationFileIds);
  Future<AgentToolDispatchResult> dispatchWithReceipt(
          {required String argumentsJson,
          required RetrievalEgressGrant? grant,
          required String turnRequestId,
          required String conversationId,
          required String sourceUserMessageId,
          required String providerProfileId,
          required List<String> currentFileIds,
          required Future<bool> Function() serializationAllowed,
          Future<void>? cancellationSignal,
          bool Function()? isCancelled,
          DateTime? deadline}) =>
      _projection.dispatchWithReceipt(
          argumentsJson: argumentsJson,
          context: CapabilityContext(
              principal: CapabilityPrincipal.builtInAgent,
              capabilities: const [retrieveFileContent],
              permissions: const [CapabilityPermission.read],
              scope: ConversationScope.global(),
              authorizedScope: ConversationScope.global(),
              retrievalGrant: grant,
              turnRequestId: turnRequestId,
              sourceConversationId: conversationId,
              sourceMessageId: sourceUserMessageId,
              providerProfileId: providerProfileId,
              currentFileIds: currentFileIds,
              serializationAllowed: serializationAllowed,
              cancellationSignal: cancellationSignal,
              isCancelled: isCancelled,
              deadline: deadline));
  Future<String> dispatch(
          {required String argumentsJson,
          required RetrievalEgressGrant? grant,
          required String turnRequestId,
          required String conversationId,
          required String sourceUserMessageId,
          required String providerProfileId,
          required List<String> currentFileIds,
          required Future<bool> Function() serializationAllowed}) async =>
      (await dispatchWithReceipt(
              argumentsJson: argumentsJson,
              grant: grant,
              turnRequestId: turnRequestId,
              conversationId: conversationId,
              sourceUserMessageId: sourceUserMessageId,
              providerProfileId: providerProfileId,
              currentFileIds: currentFileIds,
              serializationAllowed: serializationAllowed))
          .json;
}
