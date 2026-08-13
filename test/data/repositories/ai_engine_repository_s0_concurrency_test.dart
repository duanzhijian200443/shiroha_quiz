import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';

void main() {
  group('per-engineId concurrency (activated path)', () {
    test('two same-ID saves are serialized into paired write/save groups',
        () async {
      final writeGate = Completer<void>();
      final order = <String>[];
      final credentials = _GateCredentialStore(order: order)
        ..writeGate = writeGate;
      final store = _GateEngineStore(order: order);
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final saveA = repository.saveEngine(
        profile(id: 'engine-1', apiKey: 'A'),
      );
      final saveB = repository.saveEngine(
        profile(id: 'engine-1', apiKey: 'B'),
      );

      // While the first credential write is parked, the second save must not
      // have started writing (it is queued behind the same engineId lock).
      await _until(() => credentials.writeArrivals.length == 1);
      expect(credentials.writeArrivals.length, 1);

      writeGate.complete();
      await Future.wait<void>([saveA, saveB]);

      // Paired order: write A, save A, write B, save B - never
      // [write A, write B, save A, save B] (a credential/metadata cross-pair).
      expect(order, ['w', 's', 'w', 's']);
      expect(await credentials.readCredential('engine-1'), 'B');
      expect(store.engines.single.apiKey, '');
      expect(store.engines.single.id, 'engine-1');
    });

    test('same-ID save/delete both DONE never leave an orphan credential',
        () async {
      final writeGate = Completer<void>();
      final deleteGate = Completer<void>();
      final order = <String>[];
      final credentials = _GateCredentialStore(order: order)
        ..writeGate = writeGate;
      final store = _GateEngineStore(order: order)..deleteGate = deleteGate;
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final saveFuture = repository.saveEngine(
        profile(id: 'engine-1', apiKey: 'S'),
      );
      final deleteFuture = repository.deleteEngine('engine-1');

      // While the save's credential write is parked, the delete must be
      // queued behind the same engineId lock, not already deleting metadata.
      await _until(() => credentials.writeArrivals.length == 1);
      expect(store.deleteArrivals, isEmpty);

      writeGate.complete();
      await saveFuture;

      // Delete runs after the save completes; park its metadata delete.
      await _until(() => store.deleteArrivals.length == 1);
      deleteGate.complete();
      await deleteFuture;

      // Both DONE: final state must be consistent (never credential-present
      // with metadata absent).
      expect(await credentials.readCredential('engine-1'), isNull);
      expect(store.engines, isEmpty);
    });

    test('different engineIds proceed independently (no global lock)',
        () async {
      final writeGate = Completer<void>();
      final order = <String>[];
      final credentials = _GateCredentialStore(order: order)
        ..writeGate = writeGate;
      final store = _GateEngineStore(order: order);
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final save1 = repository.saveEngine(
        profile(id: 'engine-1', apiKey: 'A'),
      );
      final save2 = repository.saveEngine(
        profile(id: 'engine-2', apiKey: 'B'),
      );

      // Both engineIds reach the write stage while the gate is held: the
      // serialization is per-engineId, not global.
      await _until(() => credentials.writeArrivals.length == 2);
      expect(credentials.writeArrivals.toSet(), {'engine-1', 'engine-2'});

      writeGate.complete();
      await Future.wait<void>([save1, save2]);

      expect(await credentials.readCredential('engine-1'), 'A');
      expect(await credentials.readCredential('engine-2'), 'B');
      expect(store.engines, hasLength(2));
      expect(store.engines.every((e) => e.apiKey.isEmpty), isTrue);
    });

    test('same-ID rename and save are serialized without a cross-pair',
        () async {
      final writeGate = Completer<void>();
      final order = <String>[];
      final credentials = _GateCredentialStore(order: order)
        ..writeGate = writeGate;
      final store = _GateEngineStore(order: order)
        ..engines.add(profile(name: 'Old Name', apiKey: 'LEGACY_SECRET'));
      final repository = AiEngineRepository(
        store: store,
        credentialStore: credentials,
      );

      final renameFuture = repository.renameEngine(
        'engine-1',
        'Renamed',
        AiEngineType.text,
      );
      final saveFuture = repository.saveEngine(
        profile(id: 'engine-1', apiKey: 'S'),
      );

      writeGate.complete();
      await Future.wait<void>([renameFuture, saveFuture]);

      expect(await credentials.readCredential('engine-1'), 'S');
      expect(store.engines, hasLength(1));
      expect(store.engines.single.apiKey, '');
    });
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition not met within timeout');
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

class _GateCredentialStore implements EngineCredentialStore {
  _GateCredentialStore({required List<String> order}) : order = order;

  final Map<String, String> credentials = <String, String>{};

  Completer<void>? writeGate;

  /// EngineIds that entered writeCredential (before the gate).
  final List<String> writeArrivals = <String>[];

  /// Global event order across both stores: 'w' = credential write,
  /// 's' = metadata save.
  final List<String> order;

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    return credentials[engineId];
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    writeArrivals.add(engineId);
    final gate = writeGate;
    if (gate != null) await gate.future;
    order.add('w');
    credentials[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    credentials.remove(engineId);
  }
}

class _GateEngineStore implements AiEngineStore {
  _GateEngineStore({required List<String> order}) : order = order;

  final List<AiEngineProfile> engines = <AiEngineProfile>[];

  Completer<void>? deleteGate;

  /// EngineIds that entered deleteAiEngine (before the gate).
  final List<String> deleteArrivals = <String>[];

  /// Global event order shared with the credential fake ('s' = metadata
  /// save).
  final List<String> order;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      List<AiEngineProfile>.of(engines);

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async => null;

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    final index = engines.indexWhere((e) => e.id == profile.id);
    if (index >= 0) {
      engines[index] = profile;
    } else {
      engines.add(profile);
    }
    order.add('s');
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {}

  @override
  Future<void> deleteAiEngine(String id) async {
    deleteArrivals.add(id);
    final gate = deleteGate;
    if (gate != null) await gate.future;
    engines.removeWhere((e) => e.id == id);
  }
}
