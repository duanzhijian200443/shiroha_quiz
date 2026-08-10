import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_provider.dart';
import 'deepseek_responses_sse_parser.dart';

typedef AgentHttpClientFactory = http.Client Function();

final class DeepSeekResponsesProvider implements AgentProviderPort {
  DeepSeekResponsesProvider({
    required AgentProviderProfile profile,
    required AgentHttpClientFactory clientFactory,
    Duration requestTimeout = const Duration(seconds: 120),
    DeepSeekResponsesSseParser parser = const DeepSeekResponsesSseParser(),
  })  : _profile = profile,
        _clientFactory = clientFactory,
        _requestTimeout = requestTimeout,
        _parser = parser;

  final AgentProviderProfile _profile;
  final AgentHttpClientFactory _clientFactory;
  final Duration _requestTimeout;
  final DeepSeekResponsesSseParser _parser;

  @override
  AgentProviderCapabilities get capabilities => const AgentProviderCapabilities(
        functionTools: true,
        nativeWebSearch: true,
      );

  static Uri buildEndpoint(String baseUrl) {
    try {
      final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
      final uri = Uri.parse(
        normalized.endsWith('/v1')
            ? '$normalized/responses'
            : '$normalized/v1/responses',
      );
      if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        throw const AgentProviderException(AgentProviderFailure.invalidRequest);
      }
      return uri;
    } on AgentProviderException {
      rethrow;
    } catch (_) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
  }

  @override
  Stream<AgentProviderEvent> stream(
    AgentProviderRequest request,
    AgentCancellationToken cancellationToken,
  ) async* {
    http.Client? client;
    var clientClosed = false;

    void closeClient() {
      if (!clientClosed) {
        clientClosed = true;
        client?.close();
      }
    }

    try {
      cancellationToken.throwIfCancelled();
      final endpoint = buildEndpoint(_profile.baseUrl);
      client = _clientFactory();
      unawaited(cancellationToken.whenCancelled.then((_) => closeClient()));

      final httpRequest = http.Request('POST', endpoint)
        ..headers.addAll(<String, String>{
          'Accept': 'text/event-stream',
          'Authorization': 'Bearer ${_profile.apiKey}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(_requestBody(request));
      final response = await client.send(httpRequest).timeout(_requestTimeout);
      cancellationToken.throwIfCancelled();
      if (response.statusCode != 200) {
        throw AgentProviderException(_httpFailure(response.statusCode));
      }

      await for (final event in _parser.parse(
        response.stream.timeout(_requestTimeout),
      )) {
        cancellationToken.throwIfCancelled();
        yield event;
      }
      cancellationToken.throwIfCancelled();
    } catch (error) {
      if (cancellationToken.isCancelled) {
        throw const AgentProviderException(AgentProviderFailure.cancelled);
      }
      if (error is AgentProviderException) rethrow;
      if (error is TimeoutException) {
        throw const AgentProviderException(AgentProviderFailure.timeout);
      }
      if (error is http.ClientException) {
        throw const AgentProviderException(
          AgentProviderFailure.temporarilyUnavailable,
        );
      }
      throw const AgentProviderException(AgentProviderFailure.internalError);
    } finally {
      closeClient();
    }
  }

  Map<String, Object?> _requestBody(AgentProviderRequest request) {
    final isToolContinuation =
        request.previousResponseId != null && request.toolOutputs.isNotEmpty;
    final messages = isToolContinuation
        ? request.toolOutputs
            .map<Map<String, Object?>>(
              (output) => <String, Object?>{
                'type': 'function_call_output',
                'call_id': output.callId,
                'output': output.output,
              },
            )
            .toList(growable: false)
        : <Map<String, Object?>>[
            <String, Object?>{
              'role': 'system',
              'content': request.systemPrompt,
            },
            ...request.messages.map(
              (message) => <String, Object?>{
                'role': switch (message.role) {
                  AgentProviderMessageRole.user => 'user',
                  AgentProviderMessageRole.assistant => 'assistant',
                },
                'content': message.content,
              },
            ),
          ];
    final tools = <Map<String, Object?>>[
      ...request.tools.map(
        (tool) => <String, Object?>{
          'type': 'function',
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.inputSchema,
        },
      ),
      if (request.enableNativeWebSearch)
        <String, Object?>{'type': 'web_search'},
    ];

    return <String, Object?>{
      'stream': true,
      'model': _profile.modelName,
      'messages': messages,
      'max_output_tokens': request.maxOutputTokens,
      if (request.previousResponseId case final previousResponseId?)
        'previous_response_id': previousResponseId,
      if (tools.isNotEmpty) 'tools': tools,
    };
  }

  AgentProviderFailure _httpFailure(int statusCode) {
    return switch (statusCode) {
      400 || 404 || 405 || 422 => AgentProviderFailure.invalidRequest,
      401 || 403 => AgentProviderFailure.authentication,
      408 || 504 => AgentProviderFailure.timeout,
      429 => AgentProviderFailure.rateLimited,
      >= 500 && < 600 => AgentProviderFailure.temporarilyUnavailable,
      _ => AgentProviderFailure.internalError,
    };
  }
}
