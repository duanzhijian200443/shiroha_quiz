import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_repository.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_store.dart';
import 'package:shiroha_quiz/data/repositories/registry_agent_profile_repository.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/services/agent/deepseek_agent_model_compatibility_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/memory_engine_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteAiConfigStore store;
  late AiConfigRepository repository;
  late RegistryAgentProfileRepository catalog;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    repository = AiConfigRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore({
        'provider-ds': 'ds-secret',
      }),
    );
    catalog = RegistryAgentProfileRepository(aiConfigRepository: repository);
    await store.insertProvider(_provider(
      providerId: 'provider-ds',
      kind: AiProviderKind.deepseek,
      displayName: 'DeepSeek',
    ));
  });

  tearDown(() => DatabaseHelper.resetRuntimeProfileForTesting());

  test('agent candidates list directly from the Model Registry', () async {
    // deepseek-flash: providerCatalog row with the official curated claims.
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));
    // A zhipu provider with a curated row and a userDefined row.
    await store.insertProvider(_provider(
      providerId: 'provider-z',
      kind: AiProviderKind.zhipu,
      displayName: 'Zhipu',
    ));
    await store.saveModel(
      _model('custom-ref', 'my-private-glm', providerId: 'provider-z'),
    );
    // Historical tombstone never lists.
    await store.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'dead-ref',
        providerId: 'provider-ds',
        canonicalModelId: 'dead-model',
        displayName: 'dead-model',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );

    final profiles = await catalog.listMainProfiles();

    expect(
      profiles.map((profile) => profile.modelName),
      unorderedEquals(
        <String>['deepseek-flash', 'glm-ocr', 'my-private-glm'],
      ),
    );
    final flash = profiles
        .singleWhere((profile) => profile.modelName == 'deepseek-flash');
    expect(flash.providerDisplayName, 'DeepSeek');
    expect(flash.modelProviderKind, AiProviderKind.deepseek);
    expect(
      flash.capabilities[AiModelCapability.toolCalling],
      AiCapabilitySupport.supported,
    );
    final custom = profiles
        .singleWhere((profile) => profile.modelName == 'my-private-glm');
    expect(custom.providerDisplayName, 'Zhipu');
    expect(
      custom.capabilities[AiModelCapability.toolCalling],
      AiCapabilitySupport.unknown,
    );
  });

  test('resolveMainProfile hydrates runtime config and fails closed', () async {
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));

    final profile = await catalog.resolveMainProfile('flash-ref');
    expect(profile, isNotNull);
    expect(profile!.profileId, 'flash-ref');
    expect(profile.modelName, 'deepseek-flash');
    expect(profile.baseUrl, 'https://api.deepseek.com');
    expect(profile.modelProviderKind, AiProviderKind.deepseek);
    // REDACTED string representation never leaks the credential.
    expect(profile.toString(), 'AgentProviderProfile(REDACTED)');

    // Unknown modelRef resolves to null.
    expect(await catalog.resolveMainProfile('missing-ref'), isNull);

    // Unavailable modelRef fails closed.
    await store.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'dead-ref',
        providerId: 'provider-ds',
        canonicalModelId: 'dead-model',
        displayName: 'dead-model',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    expect(await catalog.resolveMainProfile('dead-ref'), isNull);
  });

  test('missing credential fails closed as an incomplete profile', () async {
    await store.saveModel(_model('no-key-ref', 'deepseek-flash'));
    final keylessRepository = AiConfigRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore(const {}),
    );
    final keylessCatalog = RegistryAgentProfileRepository(
      aiConfigRepository: keylessRepository,
    );

    await expectLater(
      keylessCatalog.resolveMainProfile('no-key-ref'),
      throwsA(
        isA<AgentProfileException>().having(
          (error) => error.failure,
          'failure',
          AgentProfileFailure.dataCorrupt,
        ),
      ),
    );
  });

  test('Agent settings work with no textModel capability binding', () async {
    // §32: the registry has deepseek-flash, no capability binding exists,
    // and the Agent still lists it — bindings are not its candidate source.
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));
    final service = AgentSettingsService(
      configStore: _ConfigStore(),
      profileCatalog: catalog,
      transportCompatibility: const DeepSeekAgentModelCompatibilityAdapter(),
    );

    final snapshot = await service.load();
    expect(await store.readBinding(AiCapabilitySlot.textModel), isNull);
    expect(snapshot.availableProfiles.single.profileId, 'flash-ref');
    expect(snapshot.incompatibleProfiles, isEmpty);
  });

  test('Agent selection is independent of the textModel binding', () async {
    // §33: textModel binding = glm-5.3 (a zhipu model); Agent main =
    // deepseek-flash. Both coexist; Agent never follows the binding.
    await store.insertProvider(_provider(
      providerId: 'provider-z',
      kind: AiProviderKind.zhipu,
      displayName: 'Zhipu',
    ));
    await store.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'glm-ref',
        providerId: 'provider-z',
        canonicalModelId: 'glm-5.3',
        displayName: 'glm-5.3',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));
    await store.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'glm-ref',
        temperature: 0.7,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.verified,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );

    final configStore = _ConfigStore()
      ..encoded = const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'flash-ref',
          temperature: 1.0,
          reasoningEffort: AgentReasoningEffort.high,
        ),
      );
    final service = AgentSettingsService(
      configStore: configStore,
      profileCatalog: catalog,
      transportCompatibility: const DeepSeekAgentModelCompatibilityAdapter(),
    );

    final snapshot = await service.load();
    expect(snapshot.state, AgentSettingsState.ready);
    expect(snapshot.selectedProfile!.modelName, 'deepseek-flash');
    expect((await store.readBinding(AiCapabilitySlot.textModel))!.modelRef,
        'glm-ref');
  });

  test('Agent runtime policy is independent of capability binding values',
      () async {
    // §34: the binding stores temperature 0.7 / no reasoning effort; the
    // Agent config stores 1.0 / high, and resolution must keep them apart.
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));
    await store.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'flash-ref',
        temperature: 0.7,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.verified,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final resolver = AgentRuntimeConfigResolver(
      configStore: _ConfigStore()
        ..encoded = const AgentConfigCodec().encode(
          AgentConfig(
            providerKind: AgentProviderKind.deepSeekResponses,
            mainProfileId: 'flash-ref',
            fallbackProfileId: null,
            webEnabled: false,
            temperature: 1.0,
            reasoningEffort: AgentReasoningEffort.high,
          ),
        ),
      profileResolver: catalog,
      transportCompatibility: const DeepSeekAgentModelCompatibilityAdapter(),
    );

    final resolved = await resolver.resolve();
    expect(resolved.config.temperature, 1.0);
    expect(resolved.config.reasoningEffort, AgentReasoningEffort.high);
    expect(resolved.profile.profileId, 'flash-ref');
    expect((await store.readBinding(AiCapabilitySlot.textModel))!.temperature,
        0.7);
  });

  test('incompatible stored fallback is dropped, primary keeps working',
      () async {
    // §38: fallback stays bounded — an incompatible configured fallback is
    // dropped without substituting a third model.
    await store.saveModel(_model('flash-ref', 'deepseek-flash'));
    await store.saveModel(_model('zhipu-ref', 'glm-5.3'));
    await store.insertProvider(_provider(
      providerId: 'provider-z',
      kind: AiProviderKind.zhipu,
      displayName: 'Zhipu',
    ));
    final resolver = AgentRuntimeConfigResolver(
      configStore: _ConfigStore()
        ..encoded = const AgentConfigCodec().encode(
          AgentConfig(
            providerKind: AgentProviderKind.deepSeekResponses,
            mainProfileId: 'flash-ref',
            fallbackProfileId: 'zhipu-ref',
          ),
        ),
      profileResolver: catalog,
      transportCompatibility: const DeepSeekAgentModelCompatibilityAdapter(),
    );

    final resolved = await resolver.resolve();
    expect(resolved.profile.profileId, 'flash-ref');
    expect(resolved.fallbackProfile, isNull);
  });
}

AiProviderRecord _provider({
  required String providerId,
  required AiProviderKind kind,
  required String displayName,
}) =>
    AiProviderRecord(
      providerId: providerId,
      kind: kind,
      displayName: displayName,
      baseUrl: 'https://api.deepseek.com',
      state: AiProviderState.ready,
      revision: 0,
      createdAt: 1,
      updatedAt: 1,
    );

AiModelRecord _model(String ref, String id, {String? providerId}) =>
    AiModelRecord(
      origin: AiModelOrigin.providerCatalog,
      modelRef: ref,
      providerId: providerId ?? 'provider-ds',
      canonicalModelId: id,
      displayName: id,
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );

final class _ConfigStore implements AgentConfigStorePort {
  String? encoded;

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}
