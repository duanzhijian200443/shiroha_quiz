/// mcp.study.v0 exactly-six READ_ONLY stdio MCP server.
///
/// Owns the MCP server lifecycle: registers exactly the six frozen read-only
/// tools and serves over stdio through [serveStdio]. The production surface
/// is stdio-only: the server never accepts an arbitrary [Transport] and this
/// file defines no business semantics and never performs persistence or
/// filesystem access.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'study_mcp_adapter.dart';

const JsonSchema _nullableString = JsonUnion(<JsonSchema>[
  JsonString(),
  JsonNull(),
]);

const String _offsetBearingRfc3339Pattern =
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$';

const ToolInputSchema _listQuestionBanksInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'cursor': _nullableString,
    'limit': JsonInteger(minimum: 1, maximum: 100, defaultValue: 50),
  },
);

const ToolInputSchema _getStudyOverviewInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'bank_name': _nullableString,
    'timezone': JsonString(),
  },
  required: <String>['timezone'],
);

const ToolInputSchema _getDueReviewSummaryInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'bank_name': _nullableString,
    'timezone': _nullableString,
    'from': JsonString(pattern: _offsetBearingRfc3339Pattern),
    'to': JsonString(pattern: _offsetBearingRfc3339Pattern),
  },
  required: <String>['from', 'to'],
);

const ToolInputSchema _searchQuestionsInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'bank_name': JsonString(),
    'query': JsonString(minLength: 1, maxLength: 200),
    'cursor': _nullableString,
    'limit': JsonInteger(minimum: 1, maximum: 50),
  },
  required: <String>['bank_name', 'query'],
);

const ToolInputSchema _getQuestionDetailInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'question_id': JsonString(),
  },
  required: <String>['question_id'],
);

const ToolInputSchema _getWeakQuestionsInputSchema = ToolInputSchema(
  properties: <String, JsonSchema>{
    'bank_name': _nullableString,
    'cursor': _nullableString,
    'limit': JsonInteger(minimum: 1, maximum: 50),
  },
);

/// Wraps the mcp_dart [McpServer] for the frozen mcp.study.v0 tool surface.
final class StudyMcpServer {
  StudyMcpServer({required StudyMcpAdapter adapter}) : _adapter = adapter {
    _server = McpServer(
      const Implementation(
        name: 'shiroha_study_mcp',
        version: '0.1.0',
      ),
      options: const McpServerOptions(
        instructions: 'Shiroha Quiz mcp.study.v0 read-only study queries.',
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );
    _registerTools();
  }

  static const ToolAnnotations _readOnlyAnnotations = ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );

  final StudyMcpAdapter _adapter;
  late final McpServer _server;

  /// The exactly-six frozen tool names.
  List<String> get toolNames => List<String>.unmodifiable(
        StudyMcpAdapter.toolNames,
      );

  /// Whether the server is connected to a transport.
  bool get isConnected => _server.isConnected;

  /// Connects to the process stdin/stdout stdio transport.
  Future<void> serveStdio() => _server.connect(StdioServerTransport());

  /// Closes the transport and releases the server.
  Future<void> close() => _server.close();

  void _registerTools() {
    _server.registerTool(
      'list_question_banks',
      description:
          'List question banks with question, due, and mastered counts.',
      inputSchema: _listQuestionBanksInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('list_question_banks'),
    );
    _server.registerTool(
      'get_study_overview',
      description:
          'Global or bank-scoped study overview counts for the timezone day.',
      inputSchema: _getStudyOverviewInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_study_overview'),
    );
    _server.registerTool(
      'get_due_review_summary',
      description:
          'Due-now and scheduled review counts with local-date buckets over '
          'a half-open window.',
      inputSchema: _getDueReviewSummaryInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_due_review_summary'),
    );
    _server.registerTool(
      'search_questions',
      description:
          'Search questions in one bank and return safe stem previews.',
      inputSchema: _searchQuestionsInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('search_questions'),
    );
    _server.registerTool(
      'get_question_detail',
      description: 'Safe rich-content detail and due state for one question.',
      inputSchema: _getQuestionDetailInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_question_detail'),
    );
    _server.registerTool(
      'get_weak_questions',
      description: 'Weak-question summary with lapse and difficulty metrics.',
      inputSchema: _getWeakQuestionsInputSchema,
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_weak_questions'),
    );
  }

  ToolFunction _handlerFor(String toolName) {
    return (Map<String, dynamic> arguments, RequestHandlerExtra extra) async {
      final result = await _adapter.callTool(toolName, arguments);
      return CallToolResult(
        content: <Content>[
          TextContent(text: jsonEncode(result.envelope)),
        ],
        structuredContent: result.envelope,
        isError: result.isError,
      );
    };
  }
}
