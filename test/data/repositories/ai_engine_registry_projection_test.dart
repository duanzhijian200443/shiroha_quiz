import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_repository.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/memory_engine_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => DatabaseHelper.resetRuntimeProfileForTesting());
  tearDown(() => DatabaseHelper.resetRuntimeProfileForTesting());

  test('active legacy projection reads v24 authority and secure credential',
      () async {
    final credentials = MemoryEngineCredentialStore({'legacy-id': 'secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(_provider());
    await configStore.saveModel(_model());
    await configStore.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'legacy-id',
        temperature: 0.4,
        reasoningEffort: 'high',
        validationMode: AiBindingValidationMode.legacyPreserved,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    final active = await repository.getActiveTextEngine();
    expect(active!.id, 'legacy-id');
    expect(active.name, 'Legacy model name');
    expect(active.modelName, 'Legacy-Model');
    expect(active.apiKey, 'secret');
    expect(active.temperature, 0.4);
  });

  test('legacy save preserves model name and explicit provider kind', () async {
    final credentials = MemoryEngineCredentialStore();
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );
    await repository.saveEngine(
      const AiEngineProfile(
        id: 'new-id',
        engineType: AiEngineType.text,
        name: '我的顶配模型',
        apiKey: 'secret',
        baseUrl: 'https://example.test/v1',
        modelName: 'deepseek-v4-flash',
        temperature: 0.7,
        reasoningEffort: '',
        isActive: true,
      ),
      providerKind: AiProviderKind.deepseek,
      providerDisplayName: 'DeepSeek 官方',
    );

    final db = await DatabaseHelper.instance.database;
    expect(await db.query('ai_engines', where: 'id = ?', whereArgs: ['new-id']),
        isEmpty);
    expect((await configStore.readModel('new-id'))!.canonicalModelId,
        'deepseek-v4-flash');
    expect(await credentials.readCredential('new-id'), 'secret');
    final provider = (await configStore.readProvider('new-id'))!;
    expect(provider.kind, AiProviderKind.deepseek);
    expect(provider.displayName, 'DeepSeek 官方');
    final reloaded = await repository.getEngines(AiEngineType.text);
    expect(reloaded.single.name, '我的顶配模型');
  });

  test('legacy new provider without explicit identity fails closed', () async {
    final credentials = MemoryEngineCredentialStore();
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await expectLater(
      repository.saveEngine(
        const AiEngineProfile(
          id: 'new-id',
          engineType: AiEngineType.text,
          name: '配置名',
          apiKey: 'secret',
          baseUrl: 'https://api.deepseek.com',
          modelName: 'deepseek-v4-flash',
          temperature: 0.7,
          reasoningEffort: '',
          isActive: true,
        ),
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.invalidInput,
        ),
      ),
    );
    expect(await configStore.listProviders(), isEmpty);
    expect(await configStore.listModels(), isEmpty);
    expect(await configStore.listBindings(), isEmpty);
    expect(await credentials.readCredential('new-id'), isNull);
  });

  test('legacy edit preserves one-to-many provider and credential ownership',
      () async {
    final credentials =
        MemoryEngineCredentialStore({'provider-p': 'old-secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(
      AiProviderRecord(
        providerId: 'provider-p',
        kind: AiProviderKind.deepseek,
        displayName: 'Provider P',
        baseUrl: 'https://api.deepseek.com',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    for (final entry in const <String, String>{
      'model-m1': '配置一',
      'model-m2': '配置二',
    }.entries) {
      await configStore.saveModel(
        AiModelRecord(
          origin: AiModelOrigin.providerCatalog,
          modelRef: entry.key,
          providerId: 'provider-p',
          canonicalModelId: 'canonical-${entry.key}',
          displayName: entry.value,
          availability: AiModelAvailability.available,
          firstSeenAt: 1,
          lastSeenAt: 1,
        ),
      );
    }
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await repository.saveEngine(
      const AiEngineProfile(
        id: 'model-m1',
        engineType: AiEngineType.text,
        name: '保存后的配置一',
        apiKey: 'new-secret',
        baseUrl: 'https://api.deepseek.com',
        modelName: 'canonical-model-m1',
        temperature: 0.4,
        reasoningEffort: 'high',
        isActive: true,
      ),
    );
    await repository.renameEngine(
      'model-m1',
      '重命名配置一',
      AiEngineType.text,
    );

    final providers = await configStore.listProviders();
    final models = await configStore.listModels(providerId: 'provider-p');
    expect(providers, hasLength(1));
    expect(providers.single.providerId, 'provider-p');
    expect(providers.single.displayName, 'Provider P');
    expect(await configStore.readProvider('model-m1'), isNull);
    expect(await credentials.readCredential('provider-p'), 'new-secret');
    expect(await credentials.readCredential('model-m1'), isNull);
    expect(models.map((model) => model.modelRef),
        containsAll(<String>['model-m1', 'model-m2']));
    expect(models.every((model) => model.providerId == 'provider-p'), isTrue);
    expect(
      models.singleWhere((model) => model.modelRef == 'model-m1').displayName,
      '重命名配置一',
    );
    expect(
      models.singleWhere((model) => model.modelRef == 'model-m2').displayName,
      '配置二',
    );
    final projected = await repository.getEngines(AiEngineType.text);
    expect(
      projected.singleWhere((profile) => profile.id == 'model-m1').name,
      '重命名配置一',
    );
    expect(
      projected.singleWhere((profile) => profile.id == 'model-m2').name,
      '配置二',
    );

    await expectLater(
      repository.deleteEngine('model-m1'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.providerInUse,
        ),
      ),
    );
    expect(await configStore.listProviders(), hasLength(1));
    expect(await credentials.readCredential('provider-p'), 'new-secret');
  });

  test('legacy save rejects explicit unsupported before any mutation',
      () async {
    final credentials =
        MemoryEngineCredentialStore({'provider-p': 'old-secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(
      AiProviderRecord(
        providerId: 'provider-p',
        kind: AiProviderKind.deepseek,
        displayName: 'Provider P',
        baseUrl: 'https://api.deepseek.com',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await configStore.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'model-m1',
        providerId: 'provider-p',
        canonicalModelId: 'unsupported-model',
        displayName: '原配置名',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await configStore.saveClaims(
      'model-m1',
      AiCapabilityClaimSource.providerOfficial,
      <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'model-m1',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.providerOfficial,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
      ],
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await expectLater(
      repository.saveEngine(
        const AiEngineProfile(
          id: 'model-m1',
          engineType: AiEngineType.text,
          name: '不应保存',
          apiKey: 'new-secret',
          baseUrl: 'https://changed.example.test',
          modelName: 'unsupported-model',
          temperature: 0.4,
          reasoningEffort: '',
          isActive: true,
        ),
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.capabilityUnsupported,
        ),
      ),
    );

    final provider = (await configStore.readProvider('provider-p'))!;
    final model = (await configStore.readModel('model-m1'))!;
    expect(provider.revision, 0);
    expect(provider.baseUrl, 'https://api.deepseek.com');
    expect(model.displayName, '原配置名');
    expect(await configStore.listBindings(), isEmpty);
    expect(await credentials.readCredential('provider-p'), 'old-secret');
  });

  test('legacy save cannot change canonical identity or reuse old claims',
      () async {
    final credentials =
        MemoryEngineCredentialStore({'provider-p': 'old-secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(
      AiProviderRecord(
        providerId: 'provider-p',
        kind: AiProviderKind.deepseek,
        displayName: 'Provider P',
        baseUrl: 'https://api.deepseek.com',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await configStore.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'model-m1',
        providerId: 'provider-p',
        canonicalModelId: 'old-model',
        displayName: '旧配置',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await configStore.saveClaims(
      'model-m1',
      AiCapabilityClaimSource.providerOfficial,
      <AiCapabilityClaim>[
        for (final capability in const <AiModelCapability>[
          AiModelCapability.textInput,
          AiModelCapability.textOutput,
          AiModelCapability.toolCalling,
        ])
          AiCapabilityClaim(
            modelRef: 'model-m1',
            capability: capability,
            source: AiCapabilityClaimSource.providerOfficial,
            support: AiCapabilitySupport.supported,
            assertedAt: 1,
          ),
      ],
    );
    await configStore.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'model-m1',
        temperature: 0.4,
        reasoningEffort: 'high',
        validationMode: AiBindingValidationMode.legacyPreserved,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await expectLater(
      repository.saveEngine(
        const AiEngineProfile(
          id: 'model-m1',
          engineType: AiEngineType.text,
          name: '不应保存的新配置',
          apiKey: 'new-secret',
          baseUrl: 'https://changed.example.test',
          modelName: 'different-model',
          temperature: 0.9,
          reasoningEffort: '',
          isActive: true,
        ),
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.invalidInput,
        ),
      ),
    );

    final provider = (await configStore.readProvider('provider-p'))!;
    final model = (await configStore.readModel('model-m1'))!;
    final binding =
        (await configStore.readBinding(AiCapabilitySlot.textModel))!;
    final claims = await configStore.listClaims('model-m1');
    expect(provider.revision, 0);
    expect(provider.baseUrl, 'https://api.deepseek.com');
    expect(model.canonicalModelId, 'old-model');
    expect(model.displayName, '旧配置');
    expect(claims, hasLength(3));
    expect(binding.modelRef, 'model-m1');
    expect(binding.revision, 0);
    expect(binding.temperature, 0.4);
    expect(await credentials.readCredential('provider-p'), 'old-secret');
  });

  test('legacy activation rejects unavailable model with zero mutation',
      () async {
    final credentials =
        MemoryEngineCredentialStore({'provider-p': 'old-secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(
      AiProviderRecord(
        providerId: 'provider-p',
        kind: AiProviderKind.deepseek,
        displayName: 'Provider P',
        baseUrl: 'https://api.deepseek.com',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await configStore.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'model-current',
        providerId: 'provider-p',
        canonicalModelId: 'current-model',
        displayName: '当前配置',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await configStore.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'model-unavailable',
        providerId: 'provider-p',
        canonicalModelId: 'unavailable-model',
        displayName: '不可用配置',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await configStore.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'model-current',
        temperature: 0.7,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.legacyPreserved,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await expectLater(
      repository.setActiveEngine('model-unavailable', AiEngineType.text),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.modelUnavailable,
        ),
      ),
    );

    final binding =
        (await configStore.readBinding(AiCapabilitySlot.textModel))!;
    expect(binding.modelRef, 'model-current');
    expect(binding.revision, 0);
    expect(await credentials.readCredential('provider-p'), 'old-secret');
  });

  test('verified binding resolves exact Shiroha registry capabilities',
      () async {
    final credentials = MemoryEngineCredentialStore({'legacy-id': 'secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(_provider());
    await configStore.saveModel(
      AiModelRecord(
        origin: AiModelOrigin.providerCatalog,
        modelRef: 'legacy-id',
        providerId: 'legacy-id',
        canonicalModelId: 'deepseek-v4-flash',
        displayName: 'DeepSeek V4 Flash',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await configStore.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'legacy-id',
        temperature: 0.4,
        reasoningEffort: 'high',
        validationMode: AiBindingValidationMode.verified,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    expect((await repository.getActiveTextEngine())!.modelName,
        'deepseek-v4-flash');
  });

  test('legacy delete cannot remove a currently bound provider', () async {
    final credentials = MemoryEngineCredentialStore({'legacy-id': 'secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(_provider());
    await configStore.saveModel(_model());
    await configStore.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'legacy-id',
        temperature: 0.4,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.legacyPreserved,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: credentials,
      configRepository: AiConfigRepository(
        store: configStore,
        credentialStore: credentials,
      ),
    );

    await expectLater(
      repository.deleteEngine('legacy-id'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.providerInUse,
        ),
      ),
    );
    expect(await credentials.readCredential('legacy-id'), 'secret');
  });
}

AiProviderRecord _provider() => AiProviderRecord(
      providerId: 'legacy-id',
      kind: AiProviderKind.deepseek,
      displayName: 'Legacy',
      baseUrl: 'https://api.deepseek.com',
      state: AiProviderState.ready,
      revision: 0,
      createdAt: 1,
      updatedAt: 1,
    );

AiModelRecord _model() => AiModelRecord(
      origin: AiModelOrigin.providerCatalog,
      modelRef: 'legacy-id',
      providerId: 'legacy-id',
      canonicalModelId: 'Legacy-Model',
      displayName: 'Legacy model name',
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );
