import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/services/llm_providers/ai_provider_connection.dart';

void main() {
  test('provider kind selects endpoint and canonical id stays exact', () async {
    late Uri requested;
    final connection = HttpAiProviderConnection(
      client: MockClient((request) async {
        requested = request.url;
        expect(request.headers['Authorization'], 'Bearer secret');
        return http.Response(
          '{"data":[{"id":"Model-Exact","capabilities":{"textInput":true}}]}',
          200,
        );
      }),
    );

    final snapshot = await connection.discoverModels(
      providerKind: AiProviderKind.deepseek,
      baseUrl: 'https://api.deepseek.com',
      credential: 'secret',
    );

    expect(requested.toString(), 'https://api.deepseek.com/models');
    expect(snapshot.models.single.canonicalModelId, 'Model-Exact');
    expect(
      snapshot.models.single.officialCapabilities[AiModelCapability.textInput],
      AiCapabilitySupport.supported,
    );
  });

  test('base URL never selects a different provider adapter', () async {
    late Uri requested;
    final connection = HttpAiProviderConnection(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response('{"data":[]}', 200);
      }),
    );
    await connection.discoverModels(
      providerKind: AiProviderKind.openAiCompatible,
      baseUrl: 'https://generativelanguage.googleapis.com/proxy',
      credential: 'secret',
    );
    expect(
      requested.toString(),
      'https://generativelanguage.googleapis.com/proxy/models',
    );
  });

  test('provider failures expose fixed categories without body or credential',
      () async {
    final connection = HttpAiProviderConnection(
      client: MockClient((request) async {
        return http.Response('SENSITIVE_PROVIDER_BODY', 401);
      }),
    );

    await expectLater(
      connection.discoverModels(
        providerKind: AiProviderKind.deepseek,
        baseUrl: 'https://api.deepseek.com',
        credential: 'SENSITIVE_CREDENTIAL',
      ),
      throwsA(
        isA<AiConfigException>()
            .having(
              (error) => error.failure,
              'failure',
              AiConfigFailure.connectionRejected,
            )
            .having(
              (error) => error.toString(),
              'redacted error',
              allOf(
                isNot(contains('SENSITIVE_PROVIDER_BODY')),
                isNot(contains('SENSITIVE_CREDENTIAL')),
              ),
            ),
      ),
    );
  });
}
