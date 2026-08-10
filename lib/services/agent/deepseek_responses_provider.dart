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

  static const Set<String> _supportedModels = <String>{
    'deepseek-v4-flash',
  };

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
      if (!_supportedModels.contains(_profile.modelName)) {
        throw const AgentProviderException(
          AgentProviderFailure.unsupportedModel,
        );
      }
      final endpoint = buildEndpoint(_profile.baseUrl);
      final requestBody = _requestBody(request);
      client = _clientFactory();
      unawaited(cancellationToken.whenCancelled.then((_) => closeClient()));

      final httpRequest = http.Request('POST', endpoint)
        ..headers.addAll(<String, String>{
          'Accept': 'text/event-stream',
          'Authorization': 'Bearer ${_profile.apiKey}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(requestBody);
      final response = await client.send(httpRequest).timeout(_requestTimeout);
      cancellationToken.throwIfCancelled();
      if (response.statusCode != 200) {
        throw AgentProviderException(_httpFailure(response.statusCode));
      }

      final continuationState = request.continuationState;
      if (continuationState != null &&
          continuationState is! _DeepSeekResponsesContinuationState) {
        throw const AgentProviderException(AgentProviderFailure.invalidRequest);
      }

      final continuationItems = <Map<String, Object?>>[
        if (continuationState is _DeepSeekResponsesContinuationState)
          ...continuationState._outputItems,
        ...request.toolOutputs.map((output) => <String, Object?>{
              'type': 'function_call_output',
              'call_id': output.callId,
              'output': output.output,
            }),
      ];
      await for (final event in _parser.parse(
        response.stream.timeout(_requestTimeout),
        onContinuationItem: (item) {
          continuationItems.add(_freezeJsonMap(item));
        },
      )) {
        cancellationToken.throwIfCancelled();
        if (event case AgentProviderCompleted(:final responseId)) {
          yield AgentProviderCompleted(
            responseId,
            continuationState: continuationItems.isEmpty
                ? null
                : _DeepSeekResponsesContinuationState(continuationItems),
          );
        } else {
          yield event;
        }
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
    final continuationState = request.continuationState;
    if (continuationState != null &&
        continuationState is! _DeepSeekResponsesContinuationState) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
    final input = <Map<String, Object?>>[
      ...request.messages.map(
        (message) => <String, Object?>{
          'role': switch (message.role) {
            AgentProviderMessageRole.user => 'user',
            AgentProviderMessageRole.assistant => 'assistant',
          },
          'content': message.content,
        },
      ),
      if (continuationState is _DeepSeekResponsesContinuationState)
        ...continuationState._outputItems,
      ...request.toolOutputs.map(
        (output) => <String, Object?>{
          'type': 'function_call_output',
          'call_id': output.callId,
          'output': output.output,
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
      'instructions': request.systemPrompt,
      'input': input,
      'max_output_tokens': request.maxOutputTokens,
      'temperature': request.temperature,
      'reasoning': <String, Object?>{
        'effort': request.reasoningEffort.storageValue,
      },
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

final class _DeepSeekResponsesContinuationState
    implements AgentProviderContinuationState {
  _DeepSeekResponsesContinuationState(List<Map<String, Object?>> outputItems)
      : _outputItems = List<Map<String, Object?>>.unmodifiable(outputItems);

  final List<Map<String, Object?>> _outputItems;

  @override
  String toString() => 'DeepSeekResponsesContinuationState(REDACTED)';
}

Map<String, Object?> _freezeJsonMap(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(
    source.map(
      (key, value) => MapEntry<String, Object?>(key, _freezeJsonValue(value)),
    ),
  );
}

Object? _freezeJsonValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map(
        (key, nested) => MapEntry<String, Object?>(
          key.toString(),
          _freezeJsonValue(nested),
        ),
      ),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJsonValue));
  }
  return value;
}
