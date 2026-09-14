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
    expect(active.name, 'Legacy');
    expect(active.modelName, 'Legacy-Model');
    expect(active.apiKey, 'secret');
    expect(active.temperature, 0.4);
  });

  test('legacy save writes only v24 authority', () async {
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
        name: 'New',
        apiKey: 'secret',
        baseUrl: 'https://example.test/v1',
        modelName: 'Exact-Model',
        temperature: 0.7,
        reasoningEffort: '',
        isActive: true,
      ),
    );

    final db = await DatabaseHelper.instance.database;
    expect(await db.query('ai_engines', where: 'id = ?', whereArgs: ['new-id']),
        isEmpty);
    expect((await configStore.readModel('new-id'))!.canonicalModelId,
        'Exact-Model');
    expect(await credentials.readCredential('new-id'), 'secret');
    expect((await configStore.readProvider('new-id'))!.kind,
        AiProviderKind.openAiCompatible);
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
    for (final modelRef in const <String>['model-m1', 'model-m2']) {
      await configStore.saveModel(
        AiModelRecord(
          modelRef: modelRef,
          providerId: 'provider-p',
          canonicalModelId: 'canonical-$modelRef',
          displayName: modelRef,
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
        name: 'Model M1',
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
      'Renamed Provider P',
      AiEngineType.text,
    );

    final providers = await configStore.listProviders();
    final models = await configStore.listModels(providerId: 'provider-p');
    expect(providers, hasLength(1));
    expect(providers.single.providerId, 'provider-p');
    expect(providers.single.displayName, 'Renamed Provider P');
    expect(await configStore.readProvider('model-m1'), isNull);
    expect(await credentials.readCredential('provider-p'), 'new-secret');
    expect(await credentials.readCredential('model-m1'), isNull);
    expect(models.map((model) => model.modelRef),
        containsAll(<String>['model-m1', 'model-m2']));
    expect(models.every((model) => model.providerId == 'provider-p'), isTrue);

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

  test('verified binding resolves exact Shiroha registry capabilities',
      () async {
    final credentials = MemoryEngineCredentialStore({'legacy-id': 'secret'});
    final configStore = SqliteAiConfigStore(
      databaseHelper: DatabaseHelper.instance,
    );
    await configStore.insertProvider(_provider());
    await configStore.saveModel(
      AiModelRecord(
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
      modelRef: 'legacy-id',
      providerId: 'legacy-id',
      canonicalModelId: 'Legacy-Model',
      displayName: 'Legacy',
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );
