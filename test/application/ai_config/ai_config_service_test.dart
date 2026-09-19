import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_ports.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_repository.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/memory_engine_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteAiConfigStore store;
  late AiConfigRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    repository = AiConfigRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore({'provider-a': 'secret'}),
    );
    await store.insertProvider(_provider());
  });

  tearDown(() => DatabaseHelper.resetRuntimeProfileForTesting());

  test('exact registry supports only the exact curated model id', () async {
    await store.saveModel(_model('exact', 'deepseek-v4-flash'));
    await store.saveModel(_model('flash', 'deepseek-flash'));
    await store.saveModel(_model('near', 'deepseek-chat'));
    final service = _service(repository, const _Connection([]));

    final models = await service.listModelsForSlot(AiCapabilitySlot.textModel);
    expect(
      models.map((item) => item.model.modelRef).toList(),
      <String>['flash', 'exact', 'near'],
    );
    expect(models.first.compatible, isTrue);
    expect(models[1].compatible, isTrue);
    expect(models.last.selectionState, AiModelSelectionState.evidenceRequired);
    expect(models.last.compatible, isFalse);
  });

  test('registered text models are selectable and bind without claims',
      () async {
    await store.insertProvider(
      AiProviderRecord(
        providerId: 'provider-z',
        kind: AiProviderKind.zhipu,
        displayName: 'Zhipu',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await store.saveModel(_model('flash', 'deepseek-flash'));
    await store.saveModel(
      AiModelRecord(
        modelRef: 'zhipu-ref',
        providerId: 'provider-z',
        canonicalModelId: 'glm-5.3',
        displayName: 'GLM-5.3',
        availability: AiModelAvailability.available,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    final service = _service(repository, const _Connection([]));

    final models = await service.listModelsForSlot(AiCapabilitySlot.textModel);
    final byRef = {
      for (final item in models) item.model.modelRef: item,
    };
    expect(byRef['flash']!.selectionState, AiModelSelectionState.selectable);
    expect(byRef['flash']!.reasonCodes, isEmpty);
    expect(
      byRef['zhipu-ref']!.selectionState,
      AiModelSelectionState.selectable,
    );
    expect(byRef['zhipu-ref']!.reasonCodes, isEmpty);

    await service.applyBinding(
      slot: AiCapabilitySlot.textModel,
      modelRef: 'zhipu-ref',
      expectedRevision: null,
    );
    final binding = await store.readBinding(AiCapabilitySlot.textModel);
    expect(binding!.modelRef, 'zhipu-ref');
    expect(binding.validationMode, AiBindingValidationMode.verified);
    expect(binding.revision, 0);
  });

  test('selection state classifies eligibility with fixed priority', () async {
    await store.saveModel(_model('sel', 'deepseek-v4-flash'));
    await store.saveModel(_model('unknown-only', 'mystery-model'));
    await store.saveModel(_model('unsupported', 'partial-model'));
    await store.saveModel(_model('mixed', 'mixed-model'));
    await store.saveClaims(
      'unsupported',
      AiCapabilityClaimSource.userDeclaration,
      <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'unsupported',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.userDeclaration,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
      ],
    );
    await store.saveClaims(
      'mixed',
      AiCapabilityClaimSource.userDeclaration,
      <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'mixed',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.userDeclaration,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
      ],
    );
    await store.saveModel(
      AiModelRecord(
        modelRef: 'dead-b',
        providerId: 'provider-a',
        canonicalModelId: 'dead-b-model',
        displayName: 'B-dead',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await store.saveModel(
      AiModelRecord(
        modelRef: 'dead-a',
        providerId: 'provider-a',
        canonicalModelId: 'dead-a-model',
        displayName: 'A-dead',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    await store.saveClaims(
      'dead-a',
      AiCapabilityClaimSource.userDeclaration,
      <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'dead-a',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.userDeclaration,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
      ],
    );
    final service = _service(repository, const _Connection([]));

    final models = await service.listModelsForSlot(AiCapabilitySlot.textModel);

    expect(
      models.map((item) => item.model.modelRef).toList(),
      <String>[
        'sel',
        'unknown-only',
        'mixed',
        'unsupported',
        'dead-a',
        'dead-b',
      ],
    );
    final stateByRef = {
      for (final item in models) item.model.modelRef: item.selectionState,
    };
    expect(
      stateByRef,
      <String, AiModelSelectionState>{
        'sel': AiModelSelectionState.selectable,
        'unknown-only': AiModelSelectionState.evidenceRequired,
        'mixed': AiModelSelectionState.unsupported,
        'unsupported': AiModelSelectionState.unsupported,
        'dead-a': AiModelSelectionState.unavailable,
        'dead-b': AiModelSelectionState.unavailable,
      },
    );
    expect(models.first.compatible, isTrue);
    expect(
      models.where((item) => item.model.modelRef != 'sel').map(
            (item) => item.compatible,
          ),
      everyElement(isFalse),
    );
  });

  test('binding requires evidence and compare-and-set revision', () async {
    await store.saveModel(_model('model-a', 'unknown-model'));
    final service = _service(repository, const _Connection([]));
    await expectLater(
      service.applyBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'model-a',
        expectedRevision: null,
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.capabilityUnknown,
        ),
      ),
    );
    await store.saveClaims(
      'model-a',
      AiCapabilityClaimSource.userDeclaration,
      <AiCapabilityClaim>[
        for (final capability in const <AiModelCapability>[
          AiModelCapability.textInput,
          AiModelCapability.textOutput,
        ])
          AiCapabilityClaim(
            modelRef: 'model-a',
            capability: capability,
            source: AiCapabilityClaimSource.userDeclaration,
            support: AiCapabilitySupport.supported,
            assertedAt: 1,
          ),
      ],
    );
    await service.applyBinding(
      slot: AiCapabilitySlot.textModel,
      modelRef: 'model-a',
      expectedRevision: null,
    );
    expect((await store.readBinding(AiCapabilitySlot.textModel))!.revision, 0);
    await expectLater(
      service.applyBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'model-a',
        expectedRevision: null,
      ),
      throwsA(isA<AiConfigException>()),
    );
  });

  test('sync preserves refs and tombstones models absent from new snapshot',
      () async {
    await store.saveModel(_model('old-ref', 'old-model'));
    await store.saveModel(_model('stable-ref', 'stable-model'));
    final service = _service(
      repository,
      _Connection(<AiDiscoveredModel>[
        AiDiscoveredModel(canonicalModelId: 'stable-model'),
        AiDiscoveredModel(canonicalModelId: 'new-model'),
      ]),
    );

    await service.syncModels('provider-a');

    final models = await store.listModels(providerId: 'provider-a');
    expect(
      models
          .singleWhere((model) => model.canonicalModelId == 'old-model')
          .availability,
      AiModelAvailability.unavailable,
    );
    expect(
      models
          .singleWhere((model) => model.canonicalModelId == 'stable-model')
          .modelRef,
      'stable-ref',
    );
    expect(
      models
          .singleWhere((model) => model.canonicalModelId == 'new-model')
          .modelRef,
      'generated-1',
    );
    await expectLater(
      repository.resolveModel('old-ref'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.modelUnavailable,
        ),
      ),
    );
  });

  test('connection test records only safe success or failure status', () async {
    final service = _service(repository, const _Connection([]));
    await service.testConnection('provider-a');
    final succeeded = await store.readProvider('provider-a');
    expect(succeeded!.lastConnectionStatus, AiOperationStatus.succeeded);
    expect(succeeded.lastConnectionAt, 10);

    final failing = _service(
      repository,
      const _Connection(
        [],
        failure: AiConfigException(AiConfigFailure.connectionRejected),
      ),
    );
    await expectLater(
      failing.testConnection('provider-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.connectionRejected,
        ),
      ),
    );
    final failed = await store.readProvider('provider-a');
    expect(failed!.lastConnectionStatus, AiOperationStatus.failed);
    expect(await store.listModels(providerId: 'provider-a'), isEmpty);
  });

  test('failed sync leaves model snapshot unchanged', () async {
    await store.saveModel(_model('stable-ref', 'stable-model'));
    final before = await store.readModel('stable-ref');
    final service = _service(
      repository,
      const _Connection(
        [],
        failure: AiConfigException(AiConfigFailure.temporarilyUnavailable),
      ),
    );

    await expectLater(
      service.syncModels('provider-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.syncFailed,
        ),
      ),
    );
    final after = await store.readModel('stable-ref');
    expect(after!.availability, before!.availability);
    expect(after.lastSeenAt, before.lastSeenAt);
    expect(
      (await store.readProvider('provider-a'))!.lastSyncStatus,
      AiOperationStatus.failed,
    );
  });

  test('unavailable model fails closed with zero binding mutation', () async {
    await store.saveModel(
      AiModelRecord(
        modelRef: 'unavailable-ref',
        providerId: 'provider-a',
        canonicalModelId: 'deepseek-v4-flash',
        displayName: 'Unavailable',
        availability: AiModelAvailability.unavailable,
        firstSeenAt: 1,
        lastSeenAt: 1,
      ),
    );
    final service = _service(repository, const _Connection([]));

    await expectLater(
      service.applyBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'unavailable-ref',
        expectedRevision: null,
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.modelUnavailable,
        ),
      ),
    );
    expect(await store.readBinding(AiCapabilitySlot.textModel), isNull);
    final overview = (await service.listProviders()).single;
    expect(overview.modelCount, 0);
    expect(overview.hasModelAuthority, isTrue);
  });

  test('duplicate discovered canonical ids fail without snapshot mutation',
      () async {
    await store.saveModel(_model('stable-ref', 'stable-model'));
    final service = _service(
      repository,
      _Connection(<AiDiscoveredModel>[
        AiDiscoveredModel(canonicalModelId: 'duplicate-model'),
        AiDiscoveredModel(canonicalModelId: 'duplicate-model'),
      ]),
    );

    await expectLater(
      service.syncModels('provider-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.syncFailed,
        ),
      ),
    );
    final models = await store.listModels(providerId: 'provider-a');
    expect(models.single.modelRef, 'stable-ref');
    expect(models.single.availability, AiModelAvailability.available);
    expect(
      (await store.readProvider('provider-a'))!.lastSyncStatus,
      AiOperationStatus.failed,
    );
  });

  test('Provider UI seam creates independent instances and reports access',
      () async {
    final service = _service(repository, const _Connection([]));

    final created = await service.createProvider(
      kind: AiProviderKind.deepseek,
      displayName: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      credential: 'second-secret',
    );

    expect(created, 'generated-1');
    final providers = await service.listProviders();
    expect(providers, hasLength(2));
    expect(
      providers
          .singleWhere((item) => item.provider.providerId == created)
          .credentialState,
      AiCredentialState.present,
    );
  });

  test('Provider UI metadata edit preserves credential when replacement absent',
      () async {
    final service = _service(repository, const _Connection([]));

    await service.updateProvider(
      providerId: 'provider-a',
      expectedRevision: 0,
      kind: AiProviderKind.deepseek,
      displayName: 'Renamed',
      baseUrl: 'https://api.deepseek.com/v1',
    );

    final updated = await store.readProvider('provider-a');
    expect(updated!.displayName, 'Renamed');
    expect(updated.revision, 1);
    expect(await repository.credentialForProvider('provider-a'), 'secret');
  });

  test('Provider transport identity changes fail with zero authority mutation',
      () async {
    const modelRef = 'model-a';
    final model = _model(modelRef, 'deepseek-v4-flash');
    final claims = <AiCapabilityClaim>[
      for (final capability in const <AiModelCapability>[
        AiModelCapability.textInput,
        AiModelCapability.textOutput,
        AiModelCapability.toolCalling,
      ])
        AiCapabilityClaim(
          modelRef: modelRef,
          capability: capability,
          source: AiCapabilityClaimSource.providerOfficial,
          support: AiCapabilitySupport.supported,
          assertedAt: 1,
        ),
    ];
    final binding = AiCapabilityBinding(
      slot: AiCapabilitySlot.textModel,
      modelRef: modelRef,
      temperature: 0.7,
      reasoningEffort: '',
      validationMode: AiBindingValidationMode.verified,
      revision: 0,
      updatedAt: 1,
    );
    await store.saveModel(model);
    await store.saveClaims(
      modelRef,
      AiCapabilityClaimSource.providerOfficial,
      claims,
    );
    await store.saveBinding(binding, expectedRevision: null);
    final service = _service(repository, const _Connection([]));

    for (final mutation in <({AiProviderKind kind, String baseUrl})>[
      (
        kind: AiProviderKind.gemini,
        baseUrl: 'https://api.deepseek.com',
      ),
      (
        kind: AiProviderKind.deepseek,
        baseUrl: 'https://other.example.invalid',
      ),
    ]) {
      await expectLater(
        service.updateProvider(
          providerId: 'provider-a',
          expectedRevision: 0,
          kind: mutation.kind,
          displayName: 'Mutated',
          baseUrl: mutation.baseUrl,
          replacementCredential: 'replacement-secret',
        ),
        throwsA(
          isA<AiConfigException>().having(
            (error) => error.failure,
            'failure',
            AiConfigFailure.invalidInput,
          ),
        ),
      );

      final provider = await store.readProvider('provider-a');
      expect(provider!.kind, AiProviderKind.deepseek);
      expect(provider.displayName, 'DeepSeek');
      expect(provider.baseUrl, 'https://api.deepseek.com');
      expect(provider.revision, 0);
      final persistedModel = await store.readModel(modelRef);
      expect(persistedModel!.providerId, 'provider-a');
      expect(persistedModel.canonicalModelId, 'deepseek-v4-flash');
      final persistedClaims = await store.listClaims(modelRef);
      expect(persistedClaims, hasLength(claims.length));
      expect(
        persistedClaims.map(
          (claim) => (
            claim.modelRef,
            claim.capability,
            claim.source,
            claim.support,
            claim.assertedAt,
          ),
        ),
        unorderedEquals(
          claims.map(
            (claim) => (
              claim.modelRef,
              claim.capability,
              claim.source,
              claim.support,
              claim.assertedAt,
            ),
          ),
        ),
      );
      final persistedBinding =
          await store.readBinding(AiCapabilitySlot.textModel);
      expect(persistedBinding!.modelRef, modelRef);
      expect(persistedBinding.revision, 0);
      expect(await repository.credentialForProvider('provider-a'), 'secret');
    }
  });
}

AiConfigService _service(
  AiConfigRepository repository,
  AiProviderConnectionPort connection,
) {
  var next = 0;
  return AiConfigService(
    repository: repository,
    providerConnection: connection,
    modelRefFactory: () => 'generated-${++next}',
    clock: () => 10,
  );
}

final class _Connection implements AiProviderConnectionPort {
  const _Connection(this.models, {this.failure});
  final List<AiDiscoveredModel> models;
  final Object? failure;

  @override
  Future<AiDiscoveredModelSnapshot> discoverModels({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  }) async {
    if (failure case final error?) throw error;
    return AiDiscoveredModelSnapshot(models: models);
  }

  @override
  Future<void> testConnection({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  }) async {
    if (failure case final error?) throw error;
  }
}

AiProviderRecord _provider() => AiProviderRecord(
      providerId: 'provider-a',
      kind: AiProviderKind.deepseek,
      displayName: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      state: AiProviderState.ready,
      revision: 0,
      createdAt: 1,
      updatedAt: 1,
    );

AiModelRecord _model(String ref, String id) => AiModelRecord(
      modelRef: ref,
      providerId: 'provider-a',
      canonicalModelId: id,
      displayName: id,
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );
