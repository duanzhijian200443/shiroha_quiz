import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/credentials/secure_engine_credential_store.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';

void main() {
  group('SecureEngineCredentialStore', () {
    test('namespace maps engineId to engine.<engineId> only', () async {
      final backend = _FakeBackend();
      final store = SecureEngineCredentialStore(backend: backend);

      await store.writeCredential('engine-1', 'secret-1');
      expect(backend.writeKeys, ['engine.engine-1']);
      expect(backend.writtenValues, ['secret-1']);

      await store.readCredential('engine-1');
      expect(backend.readKeys, ['engine.engine-1']);

      await store.deleteCredential('engine-1');
      expect(backend.deleteKeys, ['engine.engine-1']);
    });

    test('read returns the stored secret when present', () async {
      final backend = _FakeBackend()..store['engine.engine-1'] = 'secret-1';
      final store = SecureEngineCredentialStore(backend: backend);

      expect(await store.readCredential('engine-1'), 'secret-1');
    });

    test('read returns null for a genuine missing credential', () async {
      final store = SecureEngineCredentialStore(backend: _FakeBackend());

      expect(await store.readCredential('engine-1'), isNull);
    });

    test('read maps empty, oversized, and NUL values to dataCorrupt', () async {
      for (final corruptValue in <String>[
        '',
        'x' * 4097,
        'a\u0000b',
      ]) {
        final backend = _FakeBackend()..store['engine.engine-1'] = corruptValue;
        final store = SecureEngineCredentialStore(backend: backend);

        await expectLater(
          store.readCredential('engine-1'),
          throwsA(
            isA<EngineCredentialException>().having(
              (e) => e.failure,
              'failure',
              EngineCredentialFailure.dataCorrupt,
            ),
          ),
        );
      }
    });

    test('read maps backend failures to typed temporarilyUnavailable',
        () async {
      final backend = _FakeBackend()
        ..readFailure = StateError('CANARY_BACKEND_READ');
      final store = SecureEngineCredentialStore(backend: backend);

      await expectLater(
        store.readCredential('engine-1'),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      await _expectNoCanary(
        () => store.readCredential('engine-1'),
        'CANARY_BACKEND_READ',
      );
    });

    test('write validates before any IO', () async {
      final backend = _FakeBackend();
      final store = SecureEngineCredentialStore(backend: backend);

      for (final invalid in <String>['', 'x' * 4097, 'a\u0000b']) {
        await expectLater(
          store.writeCredential('engine-1', invalid),
          throwsArgumentError,
        );
      }
      expect(backend.writeKeys, isEmpty);
      expect(backend.writtenValues, isEmpty);

      await store.writeCredential('engine-1', 'secret-1');
      expect(backend.writeKeys, ['engine.engine-1']);
      expect(backend.writtenValues, ['secret-1']);
    });

    test('write maps backend failures to typed temporarilyUnavailable',
        () async {
      final backend = _FakeBackend()
        ..writeFailure = StateError('CANARY_BACKEND_WRITE');
      final store = SecureEngineCredentialStore(backend: backend);

      await expectLater(
        store.writeCredential('engine-1', 'secret-1'),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      await _expectNoCanary(
        () => store.writeCredential('engine-1', 'secret-1'),
        'CANARY_BACKEND_WRITE',
      );
    });

    test('delete uses the exact key and is idempotent', () async {
      final backend = _FakeBackend()..store['engine.engine-1'] = 'secret-1';
      final store = SecureEngineCredentialStore(backend: backend);

      await store.deleteCredential('engine-1');
      expect(await store.readCredential('engine-1'), isNull);

      await store.deleteCredential('engine-1');
      expect(backend.deleteKeys, ['engine.engine-1', 'engine.engine-1']);
      expect(await store.readCredential('engine-1'), isNull);
    });

    test('delete maps backend failures to typed temporarilyUnavailable',
        () async {
      final backend = _FakeBackend()
        ..deleteFailure = StateError('CANARY_BACKEND_DELETE');
      final store = SecureEngineCredentialStore(backend: backend);

      await expectLater(
        store.deleteCredential('engine-1'),
        throwsA(
          isA<EngineCredentialException>().having(
            (e) => e.failure,
            'failure',
            EngineCredentialFailure.temporarilyUnavailable,
          ),
        ),
      );
      await _expectNoCanary(
        () => store.deleteCredential('engine-1'),
        'CANARY_BACKEND_DELETE',
      );
    });

    test('privacy: no secret or raw cause in toString/errors', () async {
      const canary = 'CANARY_SECRET_VALUE';
      final backend = _FakeBackend()
        ..store['engine.engine-1'] = canary
        ..readFailure = StateError('raw: $canary');
      final store = SecureEngineCredentialStore(backend: backend);

      expect(store.toString(), isNot(contains(canary)));
      expect(store.toString(), 'SecureEngineCredentialStore');

      try {
        await store.readCredential('engine-1');
        fail('expected typed failure');
      } on EngineCredentialException catch (error) {
        expect(error.toString(), isNot(contains(canary)));
        expect(error.toString(),
            'EngineCredentialException(temporarilyUnavailable)');
      }
    });

    test('path isolation: adapter never calls readAll/deleteAll', () {
      final source = File(
        'lib/data/credentials/secure_engine_credential_store.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('readAll')));
      expect(source, isNot(contains('deleteAll')));
    });
  });
}

Future<void> _expectNoCanary(
  Future<void> Function() action,
  String canary,
) async {
  try {
    await action();
    fail('expected typed failure');
  } on EngineCredentialException catch (error) {
    expect(error.toString(), isNot(contains(canary)));
  }
}

class _FakeBackend implements SecureKeyValueBackend {
  final Map<String, String> store = <String, String>{};

  Object? readFailure;
  Object? writeFailure;
  Object? deleteFailure;

  final List<String> readKeys = <String>[];
  final List<String> writeKeys = <String>[];
  final List<String> writtenValues = <String>[];
  final List<String> deleteKeys = <String>[];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    final failure = readFailure;
    if (failure != null) throw failure;
    return store[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeKeys.add(key);
    writtenValues.add(value);
    final failure = writeFailure;
    if (failure != null) throw failure;
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteKeys.add(key);
    final failure = deleteFailure;
    if (failure != null) throw failure;
    store.remove(key);
  }
}
