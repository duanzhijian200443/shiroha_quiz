// Test-only scripted model output. This server cannot call MCP or App services.
// Requests/results remain in memory; never log full prompts or tool payloads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class ScriptedMcpCall {
  ScriptedMcpCall(this.tool, this.arguments);
  final String tool;
  final Map<String, dynamic> Function(List<Map<String, dynamic>>) arguments;
}

final class OfflineCodexResponses {
  OfflineCodexResponses(this.calls);
  final List<ScriptedMcpCall> calls;
  final outputs = <Map<String, dynamic>>[];
  final issued = <Map<String, dynamic>>[];
  final failures = <String>[];
  HttpServer? _server;
  Future<void>? _serving;
  int requests = 0;
  bool finished = false;
  Uri get base => Uri.parse('http://127.0.0.1:${_server!.port}/v1');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serving = _serve();
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      try {
        if (request.method != 'POST' ||
            request.uri.path != '/v1/responses' ||
            request.headers.value(HttpHeaders.authorizationHeader) != null) {
          throw StateError('unexpected_request_or_auth');
        }
        var size = 0;
        final bytes = <int>[];
        await for (final chunk in request) {
          size += chunk.length;
          if (size > 2 * 1024 * 1024) throw StateError('request_limit');
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map;
        if (finished || requests > calls.length || body['stream'] != true) {
          throw StateError('unexpected_model_retry');
        }
        final index = requests++;
        // Codex may retain earlier results in input. Check every output before
        // accepting the latest one: history may contain only issued IDs, once
        // each, and the initial request cannot contain any tool result.
        final allowedIds = {
          for (var i = 0; i < issued.length; i++) 'probe-call-$i'
        };
        final returned = <String, Map>{};
        for (final item in (body['input'] as List).whereType<Map>()) {
          if (item['type'] != 'function_call_output') continue;
          final id = item['call_id'];
          if (id is! String ||
              !allowedIds.contains(id) ||
              returned.containsKey(id)) {
            throw StateError('invalid_output_set');
          }
          returned[id] = item;
        }
        if (index > 0) {
          final latest = returned['probe-call-${index - 1}'];
          if (latest == null) throw StateError('missing_original_output');
          outputs.add(decodeOutput(latest['output']));
        }
        Map<String, dynamic> item;
        if (index < calls.length) {
          final step = calls[index];
          // Use the actual advertised tool name, not a fabricated MCP route.
          final namespaces = (body['tools'] as List)
              .whereType<Map>()
              .where((tool) =>
                  tool['type'] == 'namespace' &&
                  tool['name'] == 'mcp__shiroha_vnext')
              .toList();
          final tools = namespaces.length == 1
              ? (namespaces.single['tools'] as List)
                  .whereType<Map>()
                  .where((tool) =>
                      tool['type'] == 'function' && tool['name'] == step.tool)
                  .toList()
              : <Map>[];
          if (tools.length != 1) throw StateError('mcp_tool_not_advertised');
          final args = step.arguments(outputs);
          item = {
            'type': 'function_call',
            'call_id': 'probe-call-$index',
            'namespace': 'mcp__shiroha_vnext',
            'name': tools.single['name'],
            'arguments': jsonEncode(args),
          };
          issued.add({'tool': step.tool, 'arguments': args});
        } else {
          finished = true;
          item = {
            'type': 'message',
            'id': 'probe-message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'Offline probe complete.'}
            ],
          };
        }
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        void event(Map<String, dynamic> data) => request.response
            .write('event: ${data['type']}\ndata: ${jsonEncode(data)}\n\n');
        event({
          'type': 'response.created',
          'response': {'id': 'probe-response-$index'}
        });
        event({'type': 'response.output_item.done', 'item': item});
        event({
          'type': 'response.completed',
          'response': {
            'id': 'probe-response-$index',
            'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0},
          }
        });
        await request.response.close();
      } catch (error) {
        // Do not persist arbitrary assertion text, request bodies or exceptions.
        const categories = {
          'unexpected_request_or_auth',
          'request_limit',
          'unexpected_model_retry',
          'missing_original_output',
          'invalid_output_set',
          'mcp_tool_not_advertised',
          'Unrecognized original tool output'
        };
        failures.add(error is StateError && categories.contains(error.message)
            ? error.message
            : 'offline_response_rejected_at_$requests');
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }
  }

  static Map<String, dynamic> decodeOutput(Object? output) {
    if (output is String) {
      // Pinned Codex McpToolOutput prefixes the original structured JSON with
      // this timing header. Strip only its exact grammar, never replace data.
      final text = output.replaceFirst(
          RegExp(r'^Wall time: [0-9]+\.[0-9]{4} seconds\nOutput:\n'), '');
      return decodeOutput(jsonDecode(text));
    }
    if (output is List && output.length == 1) {
      return decodeOutput((output.single as Map)['text']);
    }
    if (output is Map) {
      if (output['structuredContent'] != null) {
        return (output['structuredContent'] as Map).cast<String, dynamic>();
      }
      if (output['content'] != null) return decodeOutput(output['content']);
      if (output.containsKey('data') || output.containsKey('error')) {
        return output.cast<String, dynamic>();
      }
    }
    throw StateError('Unrecognized original tool output');
  }

  Future<void> close() async {
    await _server?.close(force: true);
    await _serving;
  }
}
