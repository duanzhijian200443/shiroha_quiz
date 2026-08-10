import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/agent_profile_repository.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

void main() {
  const complete = AiEngineProfile(
    id: 'profile-main',
    engineType: AiEngineType.text,
    name: 'DeepSeek Main',
    apiKey: 'fixture-secret-value',
    baseUrl: 'https://example.invalid/v1',
    modelName: 'fixture-model',
    temperature: 0.2,
    reasoningEffort: 'high',
    isActive: false,
  );

  test('profile adapter exposes safe summaries and resolves credentials',
      () async {
    final engineRepository = _EngineRepository(<AiEngineProfile>[
      complete,
      const AiEngineProfile(
        id: 'ocr-profile',
        engineType: AiEngineType.ocr,
        name: 'OCR',
        apiKey: 'ocr-secret',
        baseUrl: 'https://ocr.invalid',
        modelName: 'ocr-model',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      ),
    ]);
    final repository = AiEngineAgentProfileRepository(
      engineRepository: engineRepository,
    );

    final summaries = await repository.listMainProfiles();
    final resolved = await repository.resolveMainProfile('profile-main');

    expect(summaries, hasLength(1));
    expect(summaries.single.profileId, 'profile-main');
    expect(summaries.single.modelName, 'fixture-model');
    expect(
        summaries.single.toString(), isNot(contains('fixture-secret-value')));
    expect(resolved?.apiKey, 'fixture-secret-value');
    expect(resolved.toString(), isNot(contains('fixture-secret-value')));
    expect(engineRepository.requestedTypes, <AiEngineType>[
      AiEngineType.text,
      AiEngineType.text,
    ]);
    expect(engineRepository.activationCalls, 0);
  });

  test('unselected incomplete profile is omitted but cannot be resolved',
      () async {
    const incomplete = AiEngineProfile(
      id: 'incomplete',
      engineType: AiEngineType.text,
      name: 'Incomplete',
      apiKey: '',
      baseUrl: 'https://example.invalid',
      modelName: 'fixture-model',
      temperature: 0,
      reasoningEffort: '',
      isActive: false,
    );
    final repository = AiEngineAgentProfileRepository(
      engineRepository: _EngineRepository(
        const <AiEngineProfile>[complete, incomplete],
      ),
    );

    expect(await repository.listMainProfiles(), hasLength(1));
    await expectLater(
      repository.resolveMainProfile('incomplete'),
      throwsA(
        isA<AgentProfileException>().having(
          (error) => error.failure,
          'failure',
          AgentProfileFailure.dataCorrupt,
        ),
      ),
    );
  });

  test('duplicate profile ids fail instead of selecting ambiguous secrets',
      () async {
    final repository = AiEngineAgentProfileRepository(
      engineRepository: _EngineRepository(
        const <AiEngineProfile>[complete, complete],
      ),
    );

    await expectLater(
      repository.listMainProfiles(),
      throwsA(
        isA<AgentProfileException>().having(
          (error) => error.failure,
          'failure',
          AgentProfileFailure.dataCorrupt,
        ),
      ),
    );
  });

  test('legacy repository failure is normalized without raw leakage', () async {
    final repository = AiEngineAgentProfileRepository(
      engineRepository: _EngineRepository(
        const <AiEngineProfile>[],
        failure: StateError('SENSITIVE_PROFILE_MARKER'),
      ),
    );

    await expectLater(
      repository.listMainProfiles(),
      throwsA(
        isA<AgentProfileException>()
            .having(
              (error) => error.failure,
              'failure',
              AgentProfileFailure.temporarilyUnavailable,
            )
            .having(
              (error) => error.toString(),
              'safe string',
              isNot(contains('SENSITIVE_PROFILE_MARKER')),
            ),
      ),
    );
  });
}

final class _EngineRepository extends Fake implements AiEngineRepository {
  _EngineRepository(this.profiles, {this.failure});

  final List<AiEngineProfile> profiles;
  final Object? failure;
  final List<AiEngineType> requestedTypes = <AiEngineType>[];
  int activationCalls = 0;

  @override
  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    if (failure case final error?) throw error;
    requestedTypes.add(type);
    return profiles;
  }

  @override
  Future<void> setActiveEngine(String id, AiEngineType type) async {
    activationCalls++;
  }
}
