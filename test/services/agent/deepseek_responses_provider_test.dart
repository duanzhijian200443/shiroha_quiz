import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/services/agent/deepseek_responses_provider.dart';

import 'fixtures/deepseek_responses_sse_fixtures.dart';

void main() {
  group('DeepSeekResponsesProvider request mapping', () {
    test(
      'maps initial request, function tools, and native Web exactly once',
      () async {
        final client = _FixtureClient(textDeltaAndCompletedSse);
        final provider = _provider(client: client);
        final request = _request(
          tools: <AgentFunctionToolDefinition>[
            AgentFunctionToolDefinition(
              name: 'search_questions',
              description: 'Search the local question bank.',
              inputSchema: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'query': <String, Object?>{'type': 'string'},
                },
              },
            ),
          ],
          enableNativeWebSearch: true,
        );

        final events = await provider
            .stream(request, AgentCancellationController().token)
            .toList();
        final body = jsonDecode(client.requestBody!) as Map<String, dynamic>;
        final messages = body['messages']! as List<dynamic>;
        final tools = body['tools']! as List<dynamic>;

        expect(provider.capabilities.functionTools, isTrue);
        expect(provider.capabilities.nativeWebSearch, isTrue);
        expect(client.requestUrl, 'https://provider.invalid/v1/responses');
        expect(client.method, 'POST');
        expect(client.authorization, 'Bearer fixture-secret');
        expect(client.accept, 'text/event-stream');
        expect(body['stream'], isTrue);
        expect(body['model'], 'fixture-model');
        expect(body['max_output_tokens'], 321);
        expect(messages, <Object?>[
          <String, Object?>{'role': 'system', 'content': 'system fixture'},
          <String, Object?>{'role': 'user', 'content': 'user fixture'},
        ]);
        expect(tools, <Object?>[
          <String, Object?>{
            'type': 'function',
            'name': 'search_questions',
            'description': 'Search the local question bank.',
            'parameters': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'query': <String, Object?>{'type': 'string'},
              },
            },
          },
          <String, Object?>{'type': 'web_search'},
        ]);
        expect(client.requestBody, isNot(contains('third_party')));
        expect(
          events.whereType<AgentProviderTextDelta>().map((event) => event.text),
          <String>['visible ', 'answer'],
        );
        expect(
          events.whereType<AgentProviderCompleted>().single.responseId,
          'resp-text-1',
        );
        expect(
          events.map((event) => event.toString()).join(),
          isNot(
            anyOf(contains('PRIVATE_REASONING'), contains('PRIVATE_THINKING')),
          ),
        );
        expect(client.closeCalls, 1);
      },
    );

    test(
      'maps continuation to previous response and function outputs',
      () async {
        final client = _FixtureClient(textDeltaAndCompletedSse);
        final provider = _provider(client: client);
        final request = _request(
          previousResponseId: 'resp-before',
          toolOutputs: <AgentFunctionToolOutput>[
            AgentFunctionToolOutput(
              callId: 'call-before',
              output: '{"count":2}',
            ),
          ],
        );

        await provider
            .stream(request, AgentCancellationController().token)
            .drain<void>();
        final body = jsonDecode(client.requestBody!) as Map<String, dynamic>;

        expect(body['previous_response_id'], 'resp-before');
        expect(body['messages'], <Object?>[
          <String, Object?>{
            'type': 'function_call_output',
            'call_id': 'call-before',
            'output': '{"count":2}',
          },
        ]);
        expect(body, isNot(containsPair('tools', anything)));
        expect(body['messages'].toString(), isNot(contains('system fixture')));
      },
    );

    test('normalizes both supported endpoint base shapes', () {
      expect(
        DeepSeekResponsesProvider.buildEndpoint(
          'https://provider.invalid/v1/',
        ).toString(),
        'https://provider.invalid/v1/responses',
      );
      expect(
        DeepSeekResponsesProvider.buildEndpoint(
          'https://provider.invalid/root',
        ).toString(),
        'https://provider.invalid/root/v1/responses',
      );
    });
  });

  group('DeepSeekResponsesProvider streaming', () {
    test('emits completed function call and native Web phases', () async {
      final provider = _provider(client: _FixtureClient(functionAndWebSse));

      final events = await provider
          .stream(_request(), AgentCancellationController().token)
          .toList();
      final call = events.whereType<AgentProviderFunctionCall>().single;

      expect(call.callId, 'call-1');
      expect(call.name, 'search_questions');
      expect(call.argumentsJson, '{"query":"fixture"}');
      expect(
        events.whereType<AgentProviderWebSearchEvent>().map(
              (event) => event.phase,
            ),
        <AgentProviderWebSearchPhase>[
          AgentProviderWebSearchPhase.searching,
          AgentProviderWebSearchPhase.completed,
        ],
      );
      expect(
        events.whereType<AgentProviderCompleted>().single.responseId,
        'resp-tool-1',
      );
    });

    test(
      'closes the per-stream client when cancellation is requested',
      () async {
        final client = _PendingBodyClient();
        final cancellation = AgentCancellationController();
        final result = _provider(
          client: client,
        ).stream(_request(), cancellation.token).toList();
        await client.sent.future;

        cancellation.cancel();

        await expectLater(
          result,
          throwsA(_providerFailure(AgentProviderFailure.cancelled)),
        );
        expect(client.closeCalls, 1);
      },
    );
  });

  group('DeepSeekResponsesProvider safe failures', () {
    for (final entry in <(int, AgentProviderFailure)>[
      (401, AgentProviderFailure.authentication),
      (429, AgentProviderFailure.rateLimited),
      (503, AgentProviderFailure.temporarilyUnavailable),
    ]) {
      test('maps HTTP ${entry.$1} without response body leakage', () async {
        final provider = _provider(
          client: _FixtureClient(
            'PRIVATE_HTTP_BODY_MARKER',
            statusCode: entry.$1,
          ),
        );

        await expectLater(
          provider.stream(_request(), AgentCancellationController().token),
          emitsError(
            allOf(
              _providerFailure(entry.$2),
              isA<AgentProviderException>().having(
                (error) => error.toString(),
                'safe string',
                isNot(contains('PRIVATE_HTTP_BODY_MARKER')),
              ),
            ),
          ),
        );
      });
    }

    test('maps request timeout to fixed timeout failure', () async {
      final client = _NeverSendingClient();
      final provider = _provider(
        client: client,
        requestTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        provider.stream(_request(), AgentCancellationController().token),
        emitsError(_providerFailure(AgentProviderFailure.timeout)),
      );
      expect(client.closeCalls, 1);
    });

    for (final entry in <(String, AgentProviderFailure)>[
      (malformedSse, AgentProviderFailure.malformedResponse),
      (providerFailureSse, AgentProviderFailure.temporarilyUnavailable),
      (providerErrorSse, AgentProviderFailure.rateLimited),
    ]) {
      test('maps malformed/provider SSE to ${entry.$2.name}', () async {
        final provider = _provider(client: _FixtureClient(entry.$1));

        await expectLater(
          provider.stream(_request(), AgentCancellationController().token),
          emitsError(
            allOf(
              _providerFailure(entry.$2),
              isA<AgentProviderException>().having(
                (error) => error.toString(),
                'redacted error',
                isNot(contains('PRIVATE_')),
              ),
            ),
          ),
        );
      });
    }

    test(
      'maps unexpected client errors without raw exception leakage',
      () async {
        final provider = _provider(
          client: _ThrowingClient(StateError('PRIVATE_CLIENT_MARKER')),
        );

        await expectLater(
          provider.stream(_request(), AgentCancellationController().token),
          emitsError(
            allOf(
              _providerFailure(AgentProviderFailure.internalError),
              isA<AgentProviderException>().having(
                (error) => error.toString(),
                'safe string',
                isNot(contains('PRIVATE_CLIENT_MARKER')),
              ),
            ),
          ),
        );
      },
    );
  });
}

DeepSeekResponsesProvider _provider({
  required http.Client client,
  Duration requestTimeout = const Duration(seconds: 1),
}) {
  return DeepSeekResponsesProvider(
    profile: AgentProviderProfile(
      profileId: 'fixture-profile',
      apiKey: 'fixture-secret',
      baseUrl: 'https://provider.invalid/v1',
      modelName: 'fixture-model',
      temperature: 0.2,
      reasoningEffort: 'high',
    ),
    clientFactory: () => client,
    requestTimeout: requestTimeout,
  );
}

AgentProviderRequest _request({
  List<AgentFunctionToolDefinition> tools =
      const <AgentFunctionToolDefinition>[],
  List<AgentFunctionToolOutput> toolOutputs = const <AgentFunctionToolOutput>[],
  String? previousResponseId,
  bool enableNativeWebSearch = false,
}) {
  return AgentProviderRequest(
    systemPrompt: 'system fixture',
    messages: <AgentProviderMessage>[
      AgentProviderMessage(
        role: AgentProviderMessageRole.user,
        content: 'user fixture',
      ),
    ],
    tools: tools,
    toolOutputs: toolOutputs,
    previousResponseId: previousResponseId,
    enableNativeWebSearch: enableNativeWebSearch,
    maxOutputTokens: 321,
  );
}

Matcher _providerFailure(AgentProviderFailure failure) {
  return isA<AgentProviderException>().having(
    (error) => error.failure,
    'failure',
    failure,
  );
}

class _FixtureClient extends http.BaseClient {
  _FixtureClient(this.fixture, {this.statusCode = 200});

  final String fixture;
  final int statusCode;
  String? requestUrl;
  String? method;
  String? authorization;
  String? accept;
  String? requestBody;
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestUrl = request.url.toString();
    method = request.method;
    authorization = request.headers['authorization'];
    accept = request.headers['accept'];
    requestBody = await request.finalize().bytesToString();
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(fixture)),
      statusCode,
    );
  }

  @override
  void close() {
    closeCalls++;
  }
}

final class _PendingBodyClient extends http.BaseClient {
  final Completer<void> sent = Completer<void>();
  final StreamController<List<int>> _body = StreamController<List<int>>();
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    sent.complete();
    return http.StreamedResponse(_body.stream, 200);
  }

  @override
  void close() {
    closeCalls++;
    if (!_body.isClosed) unawaited(_body.close());
  }
}

final class _NeverSendingClient extends http.BaseClient {
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() {
    closeCalls++;
  }
}

final class _ThrowingClient extends http.BaseClient {
  _ThrowingClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw error;
  }
}
