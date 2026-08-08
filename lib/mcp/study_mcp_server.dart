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
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('list_question_banks'),
    );
    _server.registerTool(
      'get_study_overview',
      description:
          'Global or bank-scoped study overview counts for the timezone day.',
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_study_overview'),
    );
    _server.registerTool(
      'get_due_review_summary',
      description:
          'Due-now and scheduled review counts with local-date buckets over '
          'a half-open window.',
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_due_review_summary'),
    );
    _server.registerTool(
      'search_questions',
      description:
          'Search questions in one bank and return safe stem previews.',
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('search_questions'),
    );
    _server.registerTool(
      'get_question_detail',
      description: 'Safe rich-content detail and due state for one question.',
      annotations: _readOnlyAnnotations,
      callback: _handlerFor('get_question_detail'),
    );
    _server.registerTool(
      'get_weak_questions',
      description: 'Weak-question summary with lapse and difficulty metrics.',
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
