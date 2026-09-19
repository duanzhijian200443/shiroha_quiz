import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_ports.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_config_repository.dart';
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

  test('provider metadata never contains secret and preserve keeps credential',
      () async {
    final credentials = MemoryEngineCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );
    final provider = _provider();
    await repository.createProvider(provider, ReplaceAiCredential('secret'));

    expect((await repository.listProviders()).single.credential,
        AiCredentialState.present);
    final db = await DatabaseHelper.instance.database;
    final columns = await db.rawQuery('PRAGMA table_info(ai_providers)');
    expect(columns.map((row) => row['name']), isNot(contains('api_key')));

    await repository.updateProvider(
      _provider(revision: 1, displayName: 'Renamed'),
      expectedRevision: 0,
    );
    expect(await credentials.readCredential('provider-a'), 'secret');
    expect((await store.readProvider('provider-a'))!.displayName, 'Renamed');
  });

  test('same kind, base URL, and display name remain separate providers',
      () async {
    final credentials = MemoryEngineCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );
    await repository.createProvider(
      _provider(),
      ReplaceAiCredential('secret-a'),
    );
    await repository.createProvider(
      AiProviderRecord(
        providerId: 'provider-b',
        kind: AiProviderKind.deepseek,
        displayName: 'Provider',
        baseUrl: 'https://api.deepseek.com',
        state: AiProviderState.ready,
        revision: 0,
        createdAt: 1,
        updatedAt: 1,
      ),
      ReplaceAiCredential('secret-b'),
    );

    expect(await repository.listProviders(), hasLength(2));
    expect(await credentials.readCredential('provider-a'), 'secret-a');
    expect(await credentials.readCredential('provider-b'), 'secret-b');
  });

  test('duplicate provider identity fails without replacing metadata',
      () async {
    final credentials = MemoryEngineCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );
    await repository.createProvider(
      _provider(),
      ReplaceAiCredential('first-secret'),
    );

    await expectLater(
      repository.createProvider(
        _provider(displayName: 'Replacement'),
        ReplaceAiCredential('replacement-secret'),
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.providerAlreadyExists,
        ),
      ),
    );
    expect((await store.readProvider('provider-a'))!.displayName, 'Provider');
    expect(await credentials.readCredential('provider-a'), 'first-secret');
  });

  test('bound provider deletion fails closed without deleting credential',
      () async {
    final credentials = MemoryEngineCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );
    await repository.createProvider(
      _provider(),
      ReplaceAiCredential('secret'),
    );
    await store.saveModel(_model());
    await store.saveBinding(
      AiCapabilityBinding(
        slot: AiCapabilitySlot.textModel,
        modelRef: 'model-a',
        temperature: 0.7,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.verified,
        revision: 0,
        updatedAt: 1,
      ),
      expectedRevision: null,
    );

    await expectLater(
      repository.deleteProvider('provider-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.providerInUse,
        ),
      ),
    );
    expect(await credentials.readCredential('provider-a'), 'secret');
  });

  test('agent-referenced provider deletion fails closed', () async {
    final credentials = MemoryEngineCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
      agentReferences: const _AgentReferences(<String>{'model-a'}),
    );
    await repository.createProvider(
      _provider(),
      ReplaceAiCredential('secret'),
    );
    await store.saveModel(_model());

    await expectLater(
      repository.deleteProvider('provider-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.providerInUse,
        ),
      ),
    );
    expect(await credentials.readCredential('provider-a'), 'secret');
  });

  test('corrupt old credential is normalized if metadata save fails', () async {
    final credentials = _CorruptThenWritableCredentialStore();
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    await store.insertProvider(_provider());
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );

    await expectLater(
      repository.updateProvider(
        _provider(revision: 100),
        expectedRevision: 99,
        credential: ReplaceAiCredential('replacement'),
      ),
      throwsA(isA<EngineCredentialNormalizedException>()),
    );
    expect(credentials.secret, isNull);
  });

  test('same-provider credential and metadata updates are serialized',
      () async {
    final credentials = _ControlledCredentialStore('initial');
    final store = SqliteAiConfigStore(databaseHelper: DatabaseHelper.instance);
    await store.insertProvider(_provider());
    final repository = AiConfigRepository(
      store: store,
      credentialStore: credentials,
    );

    final first = repository.updateProvider(
      _provider(revision: 1, displayName: 'First'),
      expectedRevision: 0,
      credential: ReplaceAiCredential('first-secret'),
    );
    await credentials.firstWriteStarted.future;
    final second = repository.updateProvider(
      _provider(revision: 2, displayName: 'Second'),
      expectedRevision: 1,
      credential: ReplaceAiCredential('second-secret'),
    );
    credentials.releaseFirstWrite.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(credentials.secret, 'second-secret');
    final provider = await store.readProvider('provider-a');
    expect(provider!.revision, 2);
    expect(provider.displayName, 'Second');
  });
}

final class _AgentReferences implements AgentModelReferencePort {
  const _AgentReferences(this.refs);

  final Set<String> refs;

  @override
  Future<Set<String>> referencedModelRefs() async => refs;
}

final class _CorruptThenWritableCredentialStore
    implements EngineCredentialStore {
  bool _corrupt = true;
  String? secret;

  @override
  Future<String?> readCredential(String engineId) async {
    if (_corrupt) {
      throw const EngineCredentialException(
        EngineCredentialFailure.dataCorrupt,
      );
    }
    return secret;
  }

  @override
  Future<void> writeCredential(String engineId, String value) async {
    _corrupt = false;
    secret = value;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    _corrupt = false;
    secret = null;
  }
}

final class _ControlledCredentialStore implements EngineCredentialStore {
  _ControlledCredentialStore(this.secret);

  String? secret;
  final Completer<void> firstWriteStarted = Completer<void>();
  final Completer<void> releaseFirstWrite = Completer<void>();

  @override
  Future<String?> readCredential(String engineId) async => secret;

  @override
  Future<void> writeCredential(String engineId, String value) async {
    if (value == 'first-secret') {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    secret = value;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    secret = null;
  }
}

AiProviderRecord _provider(
    {int revision = 0, String displayName = 'Provider'}) {
  return AiProviderRecord(
    providerId: 'provider-a',
    kind: AiProviderKind.deepseek,
    displayName: displayName,
    baseUrl: 'https://api.deepseek.com',
    state: AiProviderState.ready,
    revision: revision,
    createdAt: 1,
    updatedAt: 1,
  );
}

AiModelRecord _model() => AiModelRecord(
      origin: AiModelOrigin.providerCatalog,
      modelRef: 'model-a',
      providerId: 'provider-a',
      canonicalModelId: 'custom-model',
      displayName: 'Custom',
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );
