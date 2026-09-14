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
    await store.saveModel(_model('near', 'deepseek-flash'));
    final service = _service(repository, const _Connection([]));

    final models = await service.listModelsForSlot(AiCapabilitySlot.textModel);
    expect(models.first.model.modelRef, 'exact');
    expect(models.first.compatible, isTrue);
    expect(models.last.model.modelRef, 'near');
    expect(models.last.compatible, isFalse);
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
