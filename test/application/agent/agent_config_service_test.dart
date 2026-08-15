import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';

void main() {
  const codec = AgentConfigCodec();
  final config = AgentConfig(
    providerKind: AgentProviderKind.deepSeekResponses,
    mainProfileId: 'profile-main',
    temperature: 1.25,
    reasoningEffort: AgentReasoningEffort.max,
  );
  final summary = AgentProfileSummary(
    profileId: 'profile-main',
    displayName: 'DeepSeek Main',
    modelName: 'fixture-model',
  );

  test('agent config codec is strict, versioned, and credential-free', () {
    final encoded = codec.encode(config);

    expect(codec.decode(encoded), config);
    expect(encoded, contains('"schema_version":2'));
    expect(encoded, contains('"web_enabled":false'));
    expect(encoded, contains('"temperature":1.25'));
    expect(encoded, contains('"reasoning_effort":"max"'));
    expect(encoded, isNot(contains('api_key')));
    expect(encoded, isNot(contains('base_url')));
    expect(encoded, isNot(contains('model_name')));

    // Schema v1 backward compatibility: decode v1 config gives fallbackProfileId = null
    const v1Source = '{"schema_version":1,"provider_kind":"deepseek_responses",'
        '"main_profile_id":"profile-main","web_enabled":false,'
        '"temperature":1.0,"reasoning_effort":"high"}';
    final decodedV1 = codec.decode(v1Source);
    expect(decodedV1.mainProfileId, 'profile-main');
    expect(decodedV1.fallbackProfileId, isNull);

    // Schema v2 round-trip with explicit fallback
    final configWithFallback = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
      fallbackProfileId: 'profile-fallback',
      temperature: 1.0,
      reasoningEffort: AgentReasoningEffort.high,
    );
    final encodedV2 = codec.encode(configWithFallback);
    expect(encodedV2, contains('"schema_version":2'));
    expect(encodedV2, contains('"fallback_profile_id":"profile-fallback"'));
    expect(codec.decode(encodedV2), configWithFallback);

    for (final invalid in <String>[
      '{}',
      '{"schema_version":3,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","fallback_profile_id":null,'
          '"web_enabled":false,"temperature":1.0,"reasoning_effort":"high"}',
      '{"schema_version":2,"provider_kind":"unknown",'
          '"main_profile_id":"profile-main","fallback_profile_id":null,'
          '"web_enabled":false,"temperature":1.0,"reasoning_effort":"high"}',
      '{"schema_version":2,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","fallback_profile_id":null,'
          '"web_enabled":false,"temperature":1.0,"reasoning_effort":"high",'
          '"unexpected":true}',
      '{"schema_version":2,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","fallback_profile_id":null,'
          '"web_enabled":false,"temperature":2.1,"reasoning_effort":"high"}',
      '{"schema_version":2,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","fallback_profile_id":null,'
          '"web_enabled":false,"temperature":1.0,"reasoning_effort":"low"}',
      // fallback == main is invalid
      '{"schema_version":2,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","fallback_profile_id":"profile-main",'
          '"web_enabled":false,"temperature":1.0,"reasoning_effort":"high"}',
    ]) {
      expect(
        () => codec.decode(invalid),
        throwsA(
          isA<AgentConfigException>().having(
            (error) => error.failure,
            'failure',
            AgentConfigFailure.corruptStoredConfig,
          ),
        ),
      );
    }
  });

  test('agent tuning defaults and input bounds are independent and typed', () {
    final defaults = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
    );

    expect(defaults.temperature, 1.0);
    expect(defaults.reasoningEffort, AgentReasoningEffort.high);
    expect(defaults.fallbackProfileId, isNull);

    // Fallback identical to main profile is rejected
    expect(
      () => AgentConfig(
        providerKind: AgentProviderKind.deepSeekResponses,
        mainProfileId: 'profile-main',
        fallbackProfileId: 'profile-main',
      ),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.invalidInput,
        ),
      ),
    );

    for (final temperature in <double>[-0.01, 2.01, double.nan]) {
      expect(
        () => AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'profile-main',
          temperature: temperature,
        ),
        throwsA(
          isA<AgentConfigException>().having(
            (error) => error.failure,
            'failure',
            AgentConfigFailure.invalidInput,
          ),
        ),
      );
    }
  });

  test('settings save references profiles without changing engine state',
      () async {
    final fallbackSummary = AgentProfileSummary(
      profileId: 'profile-fallback',
      displayName: 'DeepSeek Fallback',
      modelName: 'fixture-model-fb',
    );
    final store = _ConfigStore();
    final catalog = _ProfileCatalog(<AgentProfileSummary>[
      summary,
      fallbackSummary,
    ]);
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: catalog,
    );

    final configWithFallback = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
      fallbackProfileId: 'profile-fallback',
      temperature: 1.25,
      reasoningEffort: AgentReasoningEffort.max,
    );

    await service.save(configWithFallback);
    final snapshot = await service.load();

    expect(snapshot.state, AgentSettingsState.ready);
    expect(snapshot.config, configWithFallback);
    expect(snapshot.selectedProfile, summary);
    expect(snapshot.selectedFallbackProfile, fallbackSummary);
    expect(snapshot.fallbackUnavailable, isFalse);
    expect(snapshot.availableProfiles, <AgentProfileSummary>[
      summary,
      fallbackSummary,
    ]);
    expect(store.encoded, codec.encode(configWithFallback));

    // Save with nonexistent fallback profile throws profileNotFound
    final invalidFallbackConfig = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
      fallbackProfileId: 'nonexistent-fallback',
    );
    await expectLater(
      service.save(invalidFallbackConfig),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.profileNotFound,
        ),
      ),
    );
  });

  test('missing or deleted fallback profile keeps primary usable', () async {
    final configWithFallback = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
      fallbackProfileId: 'profile-fallback-deleted',
    );
    final store = _ConfigStore(encoded: codec.encode(configWithFallback));
    final settings = AgentSettingsService(
      configStore: store,
      profileCatalog: _ProfileCatalog(<AgentProfileSummary>[summary]),
    );
    final snapshot = await settings.load();

    expect(snapshot.state, AgentSettingsState.ready);
    expect(snapshot.selectedProfile, summary);
    expect(snapshot.selectedFallbackProfile, isNull);
    expect(snapshot.fallbackUnavailable, isTrue);

    final mainProfile = AgentProviderProfile(
      profileId: 'profile-main',
      apiKey: 'main-key',
      baseUrl: 'https://example.invalid/v1',
      modelName: 'fixture-main-model',
    );
    final runtime = AgentRuntimeConfigResolver(
      configStore: store,
      profileResolver: _ProfileResolver(mainProfile),
    );
    final resolved = await runtime.resolve();
    expect(resolved.profile.profileId, 'profile-main');
    expect(resolved.fallbackProfile, isNull);
  });

  test(
      'missing selected primary profile remains explicit in settings and runtime',
      () async {
    final store = _ConfigStore(encoded: codec.encode(config));
    final settings = AgentSettingsService(
      configStore: store,
      profileCatalog: _ProfileCatalog(const <AgentProfileSummary>[]),
    );
    final snapshot = await settings.load();

    expect(snapshot.state, AgentSettingsState.profileUnavailable);
    expect(snapshot.config, config);
    expect(snapshot.selectedProfile, isNull);

    final runtime = AgentRuntimeConfigResolver(
      configStore: store,
      profileResolver: _ProfileResolver(null),
    );
    await expectLater(
      runtime.resolve(),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.profileNotFound,
        ),
      ),
    );
  });

  test('runtime profile is resolved separately and string output is redacted',
      () async {
    final profile = AgentProviderProfile(
      profileId: 'profile-main',
      apiKey: 'fixture-secret-value',
      baseUrl: 'https://example.invalid/v1',
      modelName: 'fixture-model',
    );
    final fallbackProfile = AgentProviderProfile(
      profileId: 'profile-fallback',
      apiKey: 'fallback-secret-value',
      baseUrl: 'https://example.invalid/v1',
      modelName: 'fallback-model',
    );
    final configWithFb = AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
      fallbackProfileId: 'profile-fallback',
      temperature: 1.25,
      reasoningEffort: AgentReasoningEffort.max,
    );
    final resolver = AgentRuntimeConfigResolver(
      configStore: _ConfigStore(encoded: codec.encode(configWithFb)),
      profileResolver: _MultiProfileResolver(<String, AgentProviderProfile>{
        'profile-main': profile,
        'profile-fallback': fallbackProfile,
      }),
    );

    final resolved = await resolver.resolve();

    expect(resolved.config, configWithFb);
    expect(resolved.config.temperature, 1.25);
    expect(resolved.config.reasoningEffort, AgentReasoningEffort.max);
    expect(resolved.profile, same(profile));
    expect(resolved.fallbackProfile, same(fallbackProfile));
    expect(resolved.toString(), isNot(contains('fixture-secret-value')));
    expect(resolved.toString(), isNot(contains('fallback-secret-value')));
    expect(profile.toString(), isNot(contains('fixture-secret-value')));
    expect(
        fallbackProfile.toString(), isNot(contains('fallback-secret-value')));
  });

  test('store and profile failures map to fixed safe config categories',
      () async {
    final unavailableSettings = AgentSettingsService(
      configStore: _ConfigStore(failure: StateError('SENSITIVE_MARKER')),
      profileCatalog: _ProfileCatalog(<AgentProfileSummary>[summary]),
    );
    await expectLater(
      unavailableSettings.load(),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.temporarilyUnavailable,
        ),
      ),
    );

    final corruptRuntime = AgentRuntimeConfigResolver(
      configStore: _ConfigStore(encoded: codec.encode(config)),
      profileResolver: _ProfileResolver(
        null,
        failure: const AgentProfileException(AgentProfileFailure.dataCorrupt),
      ),
    );
    await expectLater(
      corruptRuntime.resolve(),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.profileIncomplete,
        ),
      ),
    );
  });
}

final class _ConfigStore implements AgentConfigStorePort {
  _ConfigStore({this.encoded, this.failure});

  String? encoded;
  final Object? failure;

  @override
  Future<String?> readAgentConfig() async {
    if (failure != null) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
    return encoded;
  }

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    if (failure != null) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
    encoded = encodedConfig;
  }
}

final class _ProfileCatalog implements AgentProfileCatalogPort {
  _ProfileCatalog(this.profiles);

  final List<AgentProfileSummary> profiles;
  int listCalls = 0;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async {
    listCalls++;
    return profiles;
  }
}

final class _ProfileResolver implements AgentProviderProfileResolverPort {
  _ProfileResolver(this.profile, {this.failure});

  final AgentProviderProfile? profile;
  final AgentProfileException? failure;

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async {
    if (failure case final error?) throw error;
    return profile?.profileId == profileId ? profile : null;
  }
}

final class _MultiProfileResolver implements AgentProviderProfileResolverPort {
  _MultiProfileResolver(this.profiles);

  final Map<String, AgentProviderProfile> profiles;

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async {
    return profiles[profileId];
  }
}
