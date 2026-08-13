library;

import 'dart:convert';

import '../retrieval/retrieval.dart';
import '../retrieval/retrieval_service.dart';
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
        'Search only the file content explicitly approved for this turn.',
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

final class AgentRetrievalToolDispatcher {
  AgentRetrievalToolDispatcher({required RetrievalService retrieval})
      : _retrieval = retrieval;
  final RetrievalService _retrieval;
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

  Future<String> dispatch(
      {required String argumentsJson,
      required RetrievalEgressGrant? grant,
      required String turnRequestId,
      required String conversationId,
      required String sourceUserMessageId,
      required String providerProfileId,
      required List<String> currentFileIds,
      required Future<bool> Function() serializationAllowed}) async {
    if (grant == null ||
        !grant.permits(
            turnRequestId: turnRequestId,
            conversationId: conversationId,
            sourceUserMessageId: sourceUserMessageId,
            providerProfileId: providerProfileId,
            currentFileIds: currentFileIds)) {
      return _failure('access_denied');
    }
    try {
      if (utf8.encode(argumentsJson).length > _maxArgumentsBytes) {
        return _failure('invalid_request');
      }
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.any(
              (key) => key != 'query' && key != 'file_ids' && key != 'limit') ||
          decoded['query'] is! String ||
          decoded['file_ids'] is! List ||
          decoded['limit'] != null && decoded['limit'] is! int) {
        return _failure('invalid_request');
      }
      final requested = (decoded['file_ids'] as List)
          .whereType<String>()
          .toList(growable: false);
      if (requested.isEmpty ||
          requested.length > RetrievalService.maxFiles ||
          requested.length != (decoded['file_ids'] as List).length ||
          requested.any((id) => !grant.approvedFileIds.contains(id)) ||
          requested.any((id) => !currentFileIds.contains(id))) {
        return _failure('access_denied');
      }
      final result = await _retrieval.retrieve(
          scope: RetrievalFilesScope(requested),
          query: decoded['query'] as String,
          limit: decoded['limit'] as int? ?? 8);
      if (!await serializationAllowed()) return _failure('access_denied');
      final encoded = jsonEncode(<String, Object?>{
        'ok': true,
        'result': <String, Object?>{
          'hits': <Map<String, Object?>>[
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
          ],
          'issues': <Map<String, Object?>>[
            for (final issue in result.perFileIssues)
              <String, Object?>{
                'file_id': issue.fileId,
                'code': issue.code.name
              }
          ],
        },
      });
      return utf8.encode(encoded).length <= _maxResultBytes
          ? encoded
          : _failure('internal_error');
    } on RetrievalException catch (error) {
      return _failure(error.failure.name);
    } catch (_) {
      return _failure('internal_error');
    }
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
