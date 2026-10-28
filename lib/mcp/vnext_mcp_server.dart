/// Independent Tools-only vNext projection. No identity or persistence owner.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Stdin;
import 'package:mcp_dart/mcp_dart.dart';

/// Trusted bridge transport/composition, never selected by client metadata.
abstract interface class VnextMcpPort {
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled, required bool Function() available});
  Future<void> close();
}

/// Safe business failure, distinct from an MCP JSON-RPC protocol error.
Map<String, Object?> vnextFailure(String code) =>
    {'profileVersion': 2, 'data': null, 'error': code};

/// Separate entrypoint; construction never enables an App or authenticates it.
final class VnextMcpServer {
  VnextMcpServer(this.port, {McpServer? protocolServer}) {
    _server = protocolServer ??
        McpServer(
          const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
          options: const McpServerOptions(
            instructions: 'Stage generated candidates for review in Shiroha. '
                'The App policy selects review drafts or direct saving. STAGED '
                'acknowledges publication only; query lifecycle for saved status. '
                'Reconcile uncertain submissions by '
                'their original submissionKey; never automatically retry a write.',
            capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
          ),
        );
    _server.server.onclose = () {
      _closed = true;
      // EOF closes admission immediately; entry completion still belongs to the
      // original port's drain/Owner barrier. Observe errors even for SDK users
      // that never call serveStdio, while preserving them for the owning caller.
      unawaited(_closePort().then((_) {
        if (!_settled.isCompleted) _settled.complete();
      }, onError: (Object error, StackTrace stack) {
        if (!_settled.isCompleted) _settled.completeError(error, stack);
      }));
    };
    unawaited(
        _settled.future.then((_) {}, onError: (Object _, StackTrace __) {}));
    for (final entry in inputSchemas.entries) {
      _server.registerTool(entry.key,
          description: entry.key == 'propose_generated_questions'
              ? 'Submit content-only Submission v1; the App policy chooses review or direct saving.'
              : entry.key == 'get_question_proposal'
                  ? 'Query currently authorized pending_review, committed or rejected '
                      'status and safe counts by original submissionKey.'
                  : 'Read currently authorized generation context or content.',
          inputSchema: JsonObject.fromJson(entry.value),
          outputSchema: JsonObject(properties: {
            'profileVersion': JsonInteger(minimum: 2, maximum: 2),
            'data': JsonUnion([
              entry.key == 'get_question_proposal'
                  ? JsonObject.fromJson(_lifecycleSchema)
                  : const JsonObject(),
              const JsonNull()
            ]),
            'error': JsonUnion([JsonString(), JsonNull()]),
          }, required: [
            'profileVersion',
            'data',
            'error'
          ], additionalProperties: false),
          annotations: ToolAnnotations(
              readOnlyHint: entry.key != 'propose_generated_questions',
              destructiveHint: false,
              idempotentHint: entry.key != 'open_generation_context',
              openWorldHint: false), callback: (arguments, extra) async {
        Map<String, Object?> result;
        try {
          final properties = entry.value['properties'] as Map;
          if (arguments.keys.any((key) => !properties.containsKey(key))) {
            result = vnextFailure('invalidRequest');
          } else {
            result = await port.call(entry.key, arguments,
                cancelled: extra.signal.onAbort,
                available: () => !_closed && !extra.signal.aborted);
          }
        } catch (_) {
          // Never export an exception, request body, or unknown-write claim.
          result = vnextFailure('unavailable');
        }
        return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
            structuredContent: result,
            isError: result['error'] != null);
      });
    }
  }
  final VnextMcpPort port;
  late final McpServer _server;
  bool _closed = false;
  final _settled = Completer<void>();
  Future<void>? _portClosing, _closing;
  Future<void> _closePort() => _portClosing ??= Future<void>.sync(port.close);

  Future<void> serveStdio({Stdin? input}) async {
    try {
      await _server.connect(StdioServerTransport(stdin: input));
      await _settled.future;
    } finally {
      await close();
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      // Closing the protocol first cancels protocol work. This is not evidence
      // that business work settled: join the SAME original port close below.
      try {
        await _server.close();
      } finally {
        await _closePort();
      }
    }();
  }

  static Map<String, dynamic> _object(Map<String, dynamic> fields,
          [List<String> required = const []]) =>
      {
        'type': 'object',
        'properties': fields,
        'required': required,
        'additionalProperties': false
      };
  static const _ref = {'type': 'string', 'pattern': r'^[A-Za-z0-9_-]{43}$'};
  static const _cursor = {
    'type': ['string', 'null'],
    'pattern': r'^[A-Za-z0-9_-]{43}$'
  };
  static const _page = {'type': 'integer', 'minimum': 1, 'maximum': 50};
  static const _query = {'type': 'string', 'minLength': 1, 'maxLength': 200};
  static final _lifecycleSchema = _object({
    'submissionKey': {'type': 'string', 'minLength': 1, 'maxLength': 64},
    'lifecycleStatus': {
      'type': 'string',
      'enum': ['pending_review', 'committed', 'rejected']
    },
    'requestedCount': {'type': 'integer', 'minimum': 1, 'maximum': 50},
    'actualCount': {'type': 'integer', 'minimum': 1, 'maximum': 50},
    'committedCount': {'type': 'integer', 'minimum': 0, 'maximum': 50},
    'rejectedCount': {'type': 'integer', 'minimum': 0, 'maximum': 50},
  }, [
    'submissionKey',
    'lifecycleStatus',
    'requestedCount',
    'actualCount',
    'committedCount',
    'rejectedCount'
  ]);
  static final Map<String, Map<String, dynamic>> inputSchemas = {
    'open_generation_context': _object({
      'targetRef': _ref,
      'pageSize': _page,
      'cursor': _cursor,
      'contextRef': _ref,
      'fileRefs': {
        'type': 'array',
        'items': _ref,
        'minItems': 1,
        'maxItems': 64,
        'uniqueItems': true
      },
    }),
    'search_questions': _object({
      'contextRef': _ref,
      'query': _query,
      'pageSize': _page,
      'cursor': _cursor
    }, [
      'contextRef',
      'query'
    ]),
    'get_question_detail': _object({'contextRef': _ref, 'questionRef': _ref},
        ['contextRef', 'questionRef']),
    'retrieve_file_content': _object({
      'contextRef': _ref,
      'query': _query,
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20}
    }, [
      'contextRef',
      'query'
    ]),
    'get_file_passage': _object(
        {'contextRef': _ref, 'passageRef': _ref, 'cursor': _cursor},
        ['contextRef', 'passageRef']),
    'propose_generated_questions': _object({
      'contextRef': _ref,
      'submission': _object({
        'schemaVersion': {'const': 1, 'type': 'integer'},
        'submissionKey': {'type': 'string', 'minLength': 1, 'maxLength': 64},
        'requestedCount': {'type': 'integer', 'minimum': 1},
        'items': {
          'type': 'array',
          'minItems': 1,
          'items': {'type': 'object'}
        }
      }, [
        'schemaVersion',
        'submissionKey',
        'requestedCount',
        'items'
      ])
    }, [
      'contextRef',
      'submission'
    ]),
    'get_question_proposal': _object({
      'submissionKey': {'type': 'string', 'minLength': 1, 'maxLength': 64}
    }, [
      'submissionKey'
    ]),
  };
}
