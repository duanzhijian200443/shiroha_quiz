import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

import 'support/memory_engine_credential_store.dart';

void main() {
  const textProfile = AiEngineProfile(
    id: 'text-profile',
    engineType: AiEngineType.text,
    name: 'Text Profile',
    apiKey: 'fixture-value',
    baseUrl: 'https://example.invalid',
    modelName: 'fixture-model',
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );
  const ocrProfile = AiEngineProfile(
    id: 'ocr-profile',
    engineType: AiEngineType.ocr,
    name: 'OCR Profile',
    apiKey: 'fixture-value',
    baseUrl: 'https://example.invalid',
    modelName: 'fixture-model',
    temperature: 0,
    reasoningEffort: '',
    isActive: true,
  );

  test('repository requires an explicit strongly typed store', () {
    final source = File('lib/data/repositories/ai_engine_repository.dart')
        .readAsStringSync();

    expect(source, contains('required AiEngineStore store'));
    expect(source, contains('required EngineCredentialStore credentialStore'));
    expect(source, isNot(contains('EngineCredentialStore?')));
    expect(source, isNot(contains('dynamic')));
    expect(source, isNot(contains('defaultDatabaseHelperProvider')));
    expect(source, isNot(contains('_effectiveDb')));
    expect(source, isNot(contains('static AiEngineRepository')));
  });

  test('read, save, activate, and delete delegate to the store', () async {
    final store = _RecordingAiEngineStore(
      engines: const [textProfile, ocrProfile],
      activeProfiles: const {
        AiEngineType.text: textProfile,
        AiEngineType.ocr: ocrProfile,
      },
    );
    final repository = AiEngineRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore({
        textProfile.id: textProfile.apiKey,
        ocrProfile.id: ocrProfile.apiKey,
      }),
    );

    expect(
      (await repository.getEngines(AiEngineType.text)).single.apiKey,
      textProfile.apiKey,
    );
    expect((await repository.getActiveTextEngine())!.id, textProfile.id);
    expect((await repository.getActiveOcrEngine())!.id, ocrProfile.id);
    await repository.saveEngine(ocrProfile);
    await repository.setActiveEngine(ocrProfile.id, AiEngineType.ocr);
    await repository.deleteEngine(ocrProfile.id);

    expect(store.listCalls, [AiEngineType.text]);
    expect(store.activeCalls, [
      AiEngineType.text,
      AiEngineType.ocr,
    ]);
    expect(store.savedProfiles.single.id, ocrProfile.id);
    expect(store.savedProfiles.single.apiKey, '');
    expect(store.activations, [(ocrProfile.id, AiEngineType.ocr)]);
    expect(store.deletedIds, [ocrProfile.id]);
  });

  test('store failures propagate instead of becoming empty or successful',
      () async {
    final store = _RecordingAiEngineStore(
      failure: StateError('SENSITIVE_STORE_FAILURE_MARKER'),
    );
    final repository = AiEngineRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore(),
    );

    await expectLater(
      repository.getEngines(AiEngineType.text),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.getActiveTextEngine(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.saveEngine(textProfile),
      throwsA(isA<EngineCredentialCompensatedException>()),
    );
    await expectLater(
      repository.setActiveEngine(textProfile.id, AiEngineType.text),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.deleteEngine(textProfile.id),
      throwsA(isA<EngineCredentialCompensatedException>()),
    );
  });

  test('DatabaseHelper has no reverse Repository dependency or provider state',
      () {
    final source =
        File('lib/core/database/database_helper.dart').readAsStringSync();

    expect(source, isNot(contains('ai_engine_repository.dart')));
    expect(source, isNot(contains('defaultDatabaseHelperProvider')));
    expect(source, contains('implements AiEngineStore'));
  });
}

class _RecordingAiEngineStore implements AiEngineStore {
  _RecordingAiEngineStore({
    this.engines = const <AiEngineProfile>[],
    this.activeProfiles = const <AiEngineType, AiEngineProfile>{},
    this.failure,
  });

  final List<AiEngineProfile> engines;
  final Map<AiEngineType, AiEngineProfile> activeProfiles;
  final Object? failure;

  final List<AiEngineType> listCalls = <AiEngineType>[];
  final List<AiEngineType> activeCalls = <AiEngineType>[];
  final List<AiEngineProfile> savedProfiles = <AiEngineProfile>[];
  final List<(String, AiEngineType)> activations = <(String, AiEngineType)>[];
  final List<String> deletedIds = <String>[];

  Never _throwFailure() => throw failure!;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    if (failure != null) _throwFailure();
    listCalls.add(type);
    return engines;
  }

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    if (failure != null) _throwFailure();
    activeCalls.add(type);
    return activeProfiles[type];
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    if (failure != null) _throwFailure();
    savedProfiles.add(profile);
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    if (failure != null) _throwFailure();
    activations.add((id, type));
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    if (failure != null) _throwFailure();
    deletedIds.add(id);
  }
}
