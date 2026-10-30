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

/// A connection-owned port that also joins the SDK's final response output.
/// The request ID correlates output only; it grants no business authority.
abstract interface class VnextMcpResponsePort implements VnextMcpPort {
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available,
      Object? responseId});
}

/// Safe business failure, distinct from an MCP JSON-RPC protocol error.
Map<String, Object?> vnextFailure(String code,
        {int profileVersion = 2,
        VnextDataSource source = const VnextDataSource('unselected')}) =>
    {
      'profileVersion': profileVersion,
      'data': null,
      'error': code,
      if (profileVersion == 3) 'source': source.toJson()
    };

final class VnextDataSource {
  const VnextDataSource(this.kind, [this.deviceRef]);
  final String kind;
  final String? deviceRef;
  Map<String, Object?> toJson() => {'kind': kind, 'deviceRef': deviceRef};
}

bool validVnextSource(Object? value) =>
    value is Map &&
    value.length == 2 &&
    const ['unselected', 'windows', 'android'].contains(value['kind']) &&
    value.containsKey('deviceRef') &&
    (value['kind'] == 'unselected' && value['deviceRef'] == null ||
        value['deviceRef'] is String &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
                .hasMatch(value['deviceRef'] as String));

/// Separate entrypoint; construction never enables an App or authenticates it.
final class VnextMcpServer {
  VnextMcpServer(this.port,
      {McpServer? protocolServer, this.profileVersion = 2}) {
    final schemas = schemasFor(profileVersion);
    _server = protocolServer ??
        McpServer(
          Implementation(
              name: profileVersion == 3 ? 'shiroha' : 'shiroha_mcp_vnext',
              version: profileVersion == 3 ? '0.1.0' : '0.2.0'),
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
    for (final entry in schemas.entries) {
      _server.registerTool(entry.key,
          description: entry.key == 'propose_generated_questions'
              ? 'Submit content-only Submission v1; the App policy chooses review or direct saving.'
              : entry.key == 'get_question_proposal'
                  ? 'Query currently authorized pending_review, committed or rejected '
                      'status and safe counts by original submissionKey.'
                  : 'Read currently authorized generation context or content.',
          inputSchema: JsonObject.fromJson(entry.value),
          outputSchema: JsonObject(properties: {
            'profileVersion':
                JsonInteger(minimum: profileVersion, maximum: profileVersion),
            'data': JsonUnion([
              profileVersion == 3 && _studyOutputs.containsKey(entry.key)
                  ? JsonObject.fromJson(_studyOutputs[entry.key]!)
                  : entry.key == 'get_question_proposal'
                      ? JsonObject.fromJson(_lifecycleSchema)
                      : const JsonObject(),
              const JsonNull()
            ]),
            'error': JsonUnion([JsonString(), JsonNull()]),
            if (profileVersion == 3)
              'source': JsonObject.fromJson({
                'type': 'object',
                'properties': {
                  'kind': {
                    'type': 'string',
                    'enum': ['unselected', 'windows', 'android']
                  },
                  'deviceRef': {
                    'type': ['string', 'null'],
                    'minLength': 1,
                    'maxLength': 128,
                    'pattern': r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
                  },
                },
                'required': ['kind', 'deviceRef'],
                'additionalProperties': false,
              }),
          }, required: [
            'profileVersion',
            'data',
            'error',
            if (profileVersion == 3) 'source',
          ], additionalProperties: false),
          annotations: ToolAnnotations(
              readOnlyHint: entry.key != 'propose_generated_questions' &&
                  !(profileVersion == 3 &&
                      entry.key == 'retrieve_file_content'),
              destructiveHint: false,
              idempotentHint: entry.key != 'open_generation_context' &&
                  entry.key != 'open_context',
              openWorldHint: false), callback: (arguments, extra) async {
        Map<String, Object?> result;
        try {
          final properties = entry.value['properties'] as Map;
          if (arguments.keys.any((key) => !properties.containsKey(key))) {
            result =
                vnextFailure('invalidRequest', profileVersion: profileVersion);
          } else if (port case final VnextMcpResponsePort responsePort) {
            result = await responsePort.call(entry.key, arguments,
                responseId: extra.requestId,
                cancelled: extra.signal.onAbort,
                available: () => !_closed && !extra.signal.aborted);
          } else {
            result = await port.call(entry.key, arguments,
                cancelled: extra.signal.onAbort,
                available: () => !_closed && !extra.signal.aborted);
          }
        } catch (_) {
          // Never export an exception, request body, or unknown-write claim.
          result = vnextFailure('unavailable', profileVersion: profileVersion);
        }
        return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
            structuredContent: result,
            isError: result['error'] != null);
      });
    }
  }
  final VnextMcpPort port;
  final int profileVersion;
  late final McpServer _server;
  bool _closed = false;
  final _settled = Completer<void>();
  Future<void>? _portClosing, _closing;
  Future<void> _closePort() => _portClosing ??= Future<void>.sync(port.close);

  Future<void> serveStdio({Stdin? input}) async {
    await serveTransport(StdioServerTransport(stdin: input));
  }

  /// The same seven-tool projection over an already authenticated channel.
  Future<void> serveTransport(Transport transport) async {
    try {
      await _server.connect(transport);
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
  static Map<String, Map<String, dynamic>> schemasFor(int profile) =>
      switch (profile) {
        2 => inputSchemas,
        3 => unifiedInputSchemas,
        _ => throw ArgumentError('Unsupported business profile'),
      };

  static const _count = {
    'type': 'integer',
    'minimum': 0,
    'maximum': 9007199254740991,
  };
  static final _studyOutputs = <String, Map<String, dynamic>>{
    'list_question_banks': _object({
      'statisticsAuthorized': {'type': 'boolean'},
      'nextCursor': _cursor,
      'items': {
        'type': 'array',
        'maxItems': 50,
        'items': _object({
          'targetRef': _ref,
          'bankName': {'type': 'string', 'minLength': 1, 'maxLength': 256},
          'folderName': {
            'type': ['string', 'null'],
            'maxLength': 256
          },
          'questionCount': _count,
          'dueCount': _count,
          'masteredCount': _count,
        }, [
          'targetRef',
          'bankName',
          'folderName'
        ])
      },
    }, [
      'statisticsAuthorized',
      'nextCursor',
      'items'
    ]),
    'get_study_overview': _object({
      'questionCount': _count,
      'masteredCount': _count,
      'dueCount': _count,
      'todayPracticeCount': _count,
      'wrongQuestionCount': _count,
    }, [
      'questionCount',
      'masteredCount',
      'dueCount',
      'todayPracticeCount',
      'wrongQuestionCount'
    ]),
    'get_due_review_summary': _object({
      'dueNow': _count,
      'scheduledCount': _count,
      'buckets': {
        'type': 'array',
        'maxItems': 92,
        'items': _object({
          'date': {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'},
          'count': _count,
        }, [
          'date',
          'count'
        ])
      },
    }, [
      'dueNow',
      'scheduledCount',
      'buckets'
    ]),
    'get_weak_questions': _object({
      'nextCursor': _cursor,
      'items': {
        'type': 'array',
        'maxItems': 50,
        'items': _object({
          'questionRef': _ref,
          'bankName': {'type': 'string', 'minLength': 1, 'maxLength': 256},
          'stemPreview': {'type': 'string', 'maxLength': 32768},
          'lapseCount': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 9007199254740991
          },
          'difficulty': {'type': 'number'},
          'lastLapseAt': {
            'type': ['string', 'null'],
            'maxLength': 40
          },
        }, [
          'questionRef',
          'bankName',
          'stemPreview',
          'lapseCount',
          'difficulty',
          'lastLapseAt'
        ])
      },
    }, [
      'nextCursor',
      'items'
    ]),
  };

  static final unifiedInputSchemas = <String, Map<String, dynamic>>{
    'open_context': _object({
      ...(inputSchemas['open_generation_context']!['properties']
          as Map<String, dynamic>),
      'scope': {
        'type': 'string',
        'enum': ['authorized', 'bank']
      },
    }),
    'list_question_banks': _object(
        {'contextRef': _ref, 'pageSize': _page, 'cursor': _cursor},
        ['contextRef']),
    'get_study_overview': _object({
      'contextRef': _ref,
      'timezone': {'type': 'string', 'minLength': 1, 'maxLength': 64}
    }, [
      'contextRef'
    ]),
    'get_due_review_summary': _object({
      'contextRef': _ref,
      'timezone': {'type': 'string', 'minLength': 1, 'maxLength': 64},
      'from': {'type': 'string', 'format': 'date-time'},
      'to': {'type': 'string', 'format': 'date-time'}
    }, [
      'contextRef',
      'from',
      'to'
    ]),
    'get_weak_questions': _object(
        {'contextRef': _ref, 'pageSize': _page, 'cursor': _cursor},
        ['contextRef']),
    for (final entry in inputSchemas.entries)
      if (entry.key != 'open_generation_context') entry.key: entry.value,
  };

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
