import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

import '../../tool/train_c_l1b_live_runtime.dart';

void main() {
  test('isolated configure writes metadata and credential through authorities',
      () async {
    final metadata = _MemoryEngineStore();
    final credentials = _MemoryCredentialStore();
    final repository = AiEngineRepository(
      store: metadata,
      credentialStore: credentials,
    );
    const profile = AiEngineProfile(
      id: 'train-c-ocr',
      engineType: AiEngineType.ocr,
      name: 'TRAIN C OCR',
      apiKey: 'synthetic-secret',
      baseUrl: 'https://open.bigmodel.cn/api/paas',
      modelName: 'glm-ocr',
      temperature: 0,
      reasoningEffort: '',
      isActive: true,
    );

    final active = await configureTrainCL1BOcrProfile(
      repository: repository,
      profile: profile,
    );

    expect(active.id, profile.id);
    expect(active.apiKey, 'synthetic-secret');
    expect(metadata.saved.single.apiKey, isEmpty);
    expect(await credentials.readCredential(profile.id), 'synthetic-secret');
    expect(metadata.activeId, profile.id);
  });

  test('credential-ready capability alone cannot configure an OCR profile',
      () async {
    final repository = AiEngineRepository(
      store: _MemoryEngineStore(),
      credentialStore: _MemoryCredentialStore(),
    );
    expect(
      repository.getActiveOcrEngine(),
      completion(isNull),
    );
  });
}

final class _MemoryCredentialStore implements EngineCredentialStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> readCredential(String engineId) async => values[engineId];

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    values[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async =>
      values.remove(engineId);
}

final class _MemoryEngineStore implements AiEngineStore {
  final List<AiEngineProfile> saved = <AiEngineProfile>[];
  String? activeId;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      saved.where((profile) => profile.engineType == type).toList();

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    final id = activeId;
    if (id == null) return null;
    for (final profile in saved) {
      if (profile.id == id && profile.engineType == type) return profile;
    }
    return null;
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    saved.removeWhere((item) => item.id == profile.id);
    saved.add(profile);
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    activeId = id;
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    saved.removeWhere((item) => item.id == id);
    if (activeId == id) activeId = null;
  }
}
