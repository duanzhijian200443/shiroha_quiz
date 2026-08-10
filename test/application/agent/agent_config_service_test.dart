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
    expect(encoded, contains('"schema_version":1'));
    expect(encoded, contains('"web_enabled":false'));
    expect(encoded, contains('"temperature":1.25'));
    expect(encoded, contains('"reasoning_effort":"max"'));
    expect(encoded, isNot(contains('api_key')));
    expect(encoded, isNot(contains('base_url')));
    expect(encoded, isNot(contains('model_name')));

    for (final invalid in <String>[
      '{}',
      '{"schema_version":2,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","web_enabled":false,'
          '"temperature":1.0,"reasoning_effort":"high"}',
      '{"schema_version":1,"provider_kind":"unknown",'
          '"main_profile_id":"profile-main","web_enabled":false,'
          '"temperature":1.0,"reasoning_effort":"high"}',
      '{"schema_version":1,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","web_enabled":false,'
          '"temperature":1.0,"reasoning_effort":"high",'
          '"unexpected":true}',
      '{"schema_version":1,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","web_enabled":false,'
          '"temperature":2.1,"reasoning_effort":"high"}',
      '{"schema_version":1,"provider_kind":"deepseek_responses",'
          '"main_profile_id":"profile-main","web_enabled":false,'
          '"temperature":1.0,"reasoning_effort":"low"}',
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

  test('settings save references a profile without changing engine state',
      () async {
    final store = _ConfigStore();
    final catalog = _ProfileCatalog(<AgentProfileSummary>[summary]);
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: catalog,
    );

    await service.save(config);
    final snapshot = await service.load();

    expect(snapshot.state, AgentSettingsState.ready);
    expect(snapshot.config, config);
    expect(snapshot.selectedProfile, summary);
    expect(snapshot.availableProfiles, <AgentProfileSummary>[summary]);
    expect(catalog.listCalls, 2);
    expect(store.encoded, codec.encode(config));
  });

  test('missing selected profile remains explicit in settings and runtime',
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
    final resolver = AgentRuntimeConfigResolver(
      configStore: _ConfigStore(encoded: codec.encode(config)),
      profileResolver: _ProfileResolver(profile),
    );

    final resolved = await resolver.resolve();

    expect(resolved.config, config);
    expect(resolved.config.temperature, 1.25);
    expect(resolved.config.reasoningEffort, AgentReasoningEffort.max);
    expect(resolved.profile, same(profile));
    expect(resolved.toString(), isNot(contains('fixture-secret-value')));
    expect(profile.toString(), isNot(contains('fixture-secret-value')));
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
