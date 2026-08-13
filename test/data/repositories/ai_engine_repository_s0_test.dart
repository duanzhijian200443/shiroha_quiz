import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

void main() {
  group('activated-path hydration', () {
    test('secure present hydrates apiKey and ignores store plaintext',
        () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'secure-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'LEGACY_SECRET')],
        active: profile(apiKey: 'LEGACY_SECRET'),
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final engines = await repository.getEngines(AiEngineType.text);
      expect(engines.single.apiKey, 'secure-1');
      expect((await repository.getActiveTextEngine())!.apiKey, 'secure-1');
    });

    test('secure missing yields empty apiKey, never store plaintext', () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'LEGACY_SECRET')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final engines = await repository.getEngines(AiEngineType.text);
      expect(engines.single.apiKey, '');
      expect(engines.single.isComplete, isFalse);
      expect(engines.single.apiKey, isNot('LEGACY_SECRET'));
    });

    test('secure unavailable propagates typed transient failure', () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.temporarilyUnavailable,
        );
      final repository = AiEngineRepository(
        store: _RecordingEngineStore(engines: [profile()], active: profile()),
        credentialStore: credentials,
      );

      await expectLater(
        repository.getEngines(AiEngineType.text),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
    });

    test('secure corrupt propagates typed hard failure', () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.dataCorrupt,
        );
      final repository = AiEngineRepository(
        store: _RecordingEngineStore(engines: [profile()], active: profile()),
        credentialStore: credentials,
      );

      await expectLater(
        repository.getActiveTextEngine(),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.dataCorrupt,
          ),
        ),
      );
    });
  });

  group('activated-path saveEngine', () {
    test('normal create writes credential then scrubbed metadata', () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore();
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.saveEngine(profile(id: 'engine-1', apiKey: 'new-1'));

      expect(await credentials.readCredential('engine-1'), 'new-1');
      expect(store.savedProfiles.single.apiKey, '');
      expect(store.savedProfiles.single.id, 'engine-1');
    });

    test('normal update replaces the credential and scrubs metadata', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'old-1')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.saveEngine(profile(apiKey: 'new-1'));

      expect(await credentials.readCredential('engine-1'), 'new-1');
      expect(store.savedProfiles.single.apiKey, '');
    });

    test('metadata failure with old valid restores the old credential',
        () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'old-1')],
      )..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: 'new-1')),
        throwsA(isA<EngineCredentialCompensatedException>()),
      );
      expect(await credentials.readCredential('engine-1'), 'old-1');
      expect(store.savedProfiles.single.apiKey, '');
      expect(store.engines.single.apiKey, 'old-1');
    });

    test('metadata failure with old missing deletes the new credential',
        () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore()..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: 'new-1')),
        throwsA(isA<EngineCredentialCompensatedException>()),
      );
      expect(await credentials.readCredential('engine-1'), isNull);
    });

    test('metadata failure with old corrupt normalizes to missing', () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.dataCorrupt,
        );
      final store = _RecordingEngineStore()..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: 'new-1')),
        throwsA(isA<EngineCredentialNormalizedException>()),
      );
      credentials.readFailure = null;
      expect(await credentials.readCredential('engine-1'), isNull);
    });

    test('restore failure reports typed PARTIAL_FAILED with residue', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      )..blockedWriteSecrets.add('old-1');
      final store = _RecordingEngineStore()..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: 'new-1')),
        throwsA(
          isA<EngineCredentialPartialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      expect(await credentials.readCredential('engine-1'), 'new-1');
    });

    test('delete-new failure reports typed PARTIAL_FAILED', () async {
      final credentials = _FakeCredentialStore()..failDeleteCall = 1;
      final store = _RecordingEngineStore()..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: 'new-1')),
        throwsA(isA<EngineCredentialPartialException>()),
      );
      expect(await credentials.readCredential('engine-1'), 'new-1');
    });

    test('identical secret skips the credential write', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'same-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'same-1')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.saveEngine(profile(apiKey: 'same-1'));

      expect(credentials.writeCalls, isEmpty);
      expect(store.savedProfiles.single.apiKey, '');
      expect(await credentials.readCredential('engine-1'), 'same-1');
    });

    test('invalid secret is rejected before any mutation', () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore();
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.saveEngine(profile(apiKey: '')),
        throwsArgumentError,
      );
      expect(credentials.writeCalls, isEmpty);
      expect(store.savedProfiles, isEmpty);
    });
  });

  group('activated-path deleteEngine', () {
    test('normal delete removes credential and metadata', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'old-1')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.deleteEngine('engine-1');

      expect(await credentials.readCredential('engine-1'), isNull);
      expect(store.deletedIds, ['engine-1']);
      expect(store.engines, isEmpty);
    });

    test('credential delete failure leaves metadata untouched and typed',
        () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      )..deleteFailure = const EngineCredentialException(
          EngineCredentialFailure.temporarilyUnavailable,
        );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'old-1')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.deleteEngine('engine-1'),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      expect(store.deletedIds, isEmpty);
      expect(store.engines, hasLength(1));
      expect(await credentials.readCredential('engine-1'), 'old-1');
    });

    test('metadata failure with old valid restores the credential', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(apiKey: 'old-1')],
      )..failDelete = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.deleteEngine('engine-1'),
        throwsA(isA<EngineCredentialCompensatedException>()),
      );
      expect(await credentials.readCredential('engine-1'), 'old-1');
      expect(store.engines, hasLength(1));
    });

    test('metadata failure with old missing stays compensated', () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore(
        engines: [profile()],
      )..failDelete = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.deleteEngine('engine-1'),
        throwsA(isA<EngineCredentialCompensatedException>()),
      );
      expect(await credentials.readCredential('engine-1'), isNull);
      expect(store.engines, hasLength(1));
    });

    test('metadata failure with old corrupt normalizes to missing', () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.dataCorrupt,
        );
      final store = _RecordingEngineStore(
        engines: [profile()],
      )..failDelete = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.deleteEngine('engine-1'),
        throwsA(isA<EngineCredentialNormalizedException>()),
      );
      credentials.readFailure = null;
      expect(await credentials.readCredential('engine-1'), isNull);
      expect(store.engines, hasLength(1));
    });

    test('repeated delete with no row and no credential is idempotent',
        () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore();
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.deleteEngine('engine-1');
      await repository.deleteEngine('engine-1');

      expect(store.deletedIds, ['engine-1', 'engine-1']);
      expect(await credentials.readCredential('engine-1'), isNull);
    });

    test('orphan credential is removed even without a row', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'orphan-1'},
      );
      final store = _RecordingEngineStore();
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.deleteEngine('engine-1');

      expect(await credentials.readCredential('engine-1'), isNull);
      expect(store.deletedIds, ['engine-1']);
    });
  });

  group('activated-path rename and setActive', () {
    test('rename preserves the credential without rewriting it', () async {
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'KEEP'},
      );
      final store = _RecordingEngineStore(
        engines: [profile(name: 'Old Name', apiKey: 'LEGACY_SECRET')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.renameEngine('engine-1', 'New Name', AiEngineType.text);

      expect(await credentials.readCredential('engine-1'), 'KEEP');
      expect(credentials.writeCalls, isEmpty);
      expect(store.savedProfiles.single.name, 'New Name');
      expect(store.savedProfiles.single.apiKey, '');
    });

    test('rename with missing credential still succeeds and stays missing',
        () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore(
        engines: [profile(name: 'Old Name', apiKey: 'LEGACY_SECRET')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.renameEngine('engine-1', 'New Name', AiEngineType.text);

      expect(store.savedProfiles.single.name, 'New Name');
      expect(store.savedProfiles.single.apiKey, '');
      expect(await credentials.readCredential('engine-1'), isNull);
      expect(credentials.writeCalls, isEmpty);
      expect(credentials.deleteCalls, isEmpty);
    });

    test('rename propagates typed unavailable without SQLite fallback',
        () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.temporarilyUnavailable,
        );
      final store = _RecordingEngineStore(
        engines: [profile(name: 'Old Name', apiKey: 'LEGACY_SECRET')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.renameEngine('engine-1', 'New Name', AiEngineType.text),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      expect(store.savedProfiles, isEmpty);
      expect(store.engines.single.name, 'Old Name');
    });

    test('rename propagates typed corrupt without SQLite fallback', () async {
      final credentials = _FakeCredentialStore()
        ..readFailure = const EngineCredentialException(
          EngineCredentialFailure.dataCorrupt,
        );
      final store = _RecordingEngineStore(
        engines: [profile(name: 'Old Name', apiKey: 'LEGACY_SECRET')],
      );
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await expectLater(
        repository.renameEngine('engine-1', 'New Name', AiEngineType.text),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.dataCorrupt,
          ),
        ),
      );
      expect(store.savedProfiles, isEmpty);
    });

    test('setActive never touches the credential store', () async {
      final credentials = _FakeCredentialStore();
      final store = _RecordingEngineStore();
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      await repository.setActiveEngine('engine-1', AiEngineType.ocr);

      expect(store.activations, [('engine-1', AiEngineType.ocr)]);
      expect(credentials.readCalls, isEmpty);
      expect(credentials.writeCalls, isEmpty);
      expect(credentials.deleteCalls, isEmpty);
    });
  });

  group('privacy', () {
    test('exception strings never contain the canary secret', () async {
      const canary = 'CANARY_SECRET_VALUE';
      final credentials = _FakeCredentialStore(
        initial: const {'engine-1': 'old-1'},
      )..blockedWriteSecrets.add('old-1');
      final store = _RecordingEngineStore()..failSave = true;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      try {
        await repository.saveEngine(profile(apiKey: canary));
        fail('expected partial failure');
      } catch (error) {
        expect(error, isA<EngineCredentialPartialException>());
        expect(error.toString(), isNot(contains(canary)));
        expect(error.toString(), isNot(contains('old-1')));
      }
    });
  });
}

AiEngineProfile profile({
  String id = 'engine-1',
  AiEngineType type = AiEngineType.text,
  String name = 'Engine',
  String apiKey = 'secret-1',
  String baseUrl = 'https://example.invalid',
  String modelName = 'model-1',
}) {
  return AiEngineProfile(
    id: id,
    engineType: type,
    name: name,
    apiKey: apiKey,
    baseUrl: baseUrl,
    modelName: modelName,
    temperature: 0.7,
    reasoningEffort: '',
    isActive: true,
  );
}

class _FakeCredentialStore implements EngineCredentialStore {
  _FakeCredentialStore({Map<String, String>? initial})
      : credentials = <String, String>{...?initial};

  final Map<String, String> credentials;

  EngineCredentialException? readFailure;
  EngineCredentialException? writeFailure;
  EngineCredentialException? deleteFailure;
  final Set<String> blockedWriteSecrets = <String>{};
  int failDeleteCall = -1;

  final List<String> readCalls = <String>[];
  final List<String> writeCalls = <String>[];
  final List<String> deleteCalls = <String>[];
  final List<String> writtenSecrets = <String>[];

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    readCalls.add(engineId);
    final failure = readFailure;
    if (failure != null) throw failure;
    return credentials[engineId];
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    writeCalls.add(engineId);
    writtenSecrets.add(secret);
    if (blockedWriteSecrets.contains(secret)) {
      throw writeFailure ??
          const EngineCredentialException(
            EngineCredentialFailure.temporarilyUnavailable,
          );
    }
    final failure = writeFailure;
    if (failure != null) throw failure;
    credentials[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    deleteCalls.add(engineId);
    if (deleteCalls.length == failDeleteCall) {
      throw deleteFailure ??
          const EngineCredentialException(
            EngineCredentialFailure.temporarilyUnavailable,
          );
    }
    final failure = deleteFailure;
    if (failure != null) throw failure;
    credentials.remove(engineId);
  }
}

class _RecordingEngineStore implements AiEngineStore {
  _RecordingEngineStore({List<AiEngineProfile>? engines, this.active})
      : engines = <AiEngineProfile>[...?engines];

  final List<AiEngineProfile> engines;
  AiEngineProfile? active;
  bool failSave = false;
  bool failDelete = false;

  final List<AiEngineProfile> savedProfiles = <AiEngineProfile>[];
  final List<String> deletedIds = <String>[];
  final List<(String, AiEngineType)> activations = <(String, AiEngineType)>[];

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      List<AiEngineProfile>.of(engines);

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async => active;

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    savedProfiles.add(profile);
    if (failSave) throw StateError('metadata save failed');
    final index = engines.indexWhere((e) => e.id == profile.id);
    if (index >= 0) {
      engines[index] = profile;
    } else {
      engines.add(profile);
    }
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    activations.add((id, type));
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    if (failDelete) throw StateError('metadata delete failed');
    deletedIds.add(id);
    engines.removeWhere((e) => e.id == id);
  }
}
