import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';

void main() {
  group('EngineCredentialStore input validation', () {
    test('rejects empty, oversized, NUL, and path-like engine ids', () {
      expect(() => validatedEngineCredentialId(''), throwsArgumentError);
      expect(
        () => validatedEngineCredentialId('a' * 129),
        throwsArgumentError,
      );
      expect(
        () => validatedEngineCredentialId('a\u0000b'),
        throwsArgumentError,
      );
      expect(() => validatedEngineCredentialId('a/b'), throwsArgumentError);
      expect(() => validatedEngineCredentialId('a\nb'), throwsArgumentError);
      expect(validatedEngineCredentialId('engine-1'), 'engine-1');
    });

    test('rejects empty, oversized, and NUL secrets without echoing them', () {
      expect(() => validatedEngineCredentialSecret(''), throwsArgumentError);
      expect(
        () => validatedEngineCredentialSecret('a' * 4097),
        throwsArgumentError,
      );
      expect(
        () => validatedEngineCredentialSecret('a\u0000b'),
        throwsArgumentError,
      );

      const canary = 'CANARY_SECRET_VALUE';
      try {
        validatedEngineCredentialSecret(canary);
      } on ArgumentError catch (error) {
        expect(error.message, isNot(contains('CANARY')));
        expect(error.toString(), isNot(contains('CANARY')));
      }
      expect(validatedEngineCredentialSecret('valid-secret'), 'valid-secret');
    });
  });

  group('typed credential exceptions are redacted', () {
    test('toString never contains secret, cause, or path', () {
      const canary = 'CANARY_SECRET_VALUE';

      const unavailable = EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
      const corrupt = EngineCredentialException(
        EngineCredentialFailure.dataCorrupt,
      );
      const compensated = EngineCredentialCompensatedException();
      const normalized = EngineCredentialNormalizedException();
      const partial = EngineCredentialPartialException(
        EngineCredentialFailure.missing,
      );

      for (final error in <Object>[
        unavailable,
        corrupt,
        compensated,
        normalized,
        partial,
      ]) {
        expect(error.toString(), isNot(contains(canary)));
        expect(error.toString(), isNot(contains('C:')));
        expect(error.toString(), isNot(contains('/')));
      }

      expect(unavailable.toString(),
          'EngineCredentialException(temporarilyUnavailable)');
      expect(corrupt.toString(), 'EngineCredentialException(dataCorrupt)');
      expect(compensated.toString(), 'EngineCredentialCompensatedException');
      expect(normalized.toString(), 'EngineCredentialNormalizedException');
      expect(
        partial.toString(),
        'EngineCredentialPartialException(missing)',
      );
    });
  });

  group('contract-conformant fake', () {
    test('read distinguishes present, missing, unavailable, and corrupt',
        () async {
      final store = _FakeCredentialStore(
        initial: const {'engine-1': 'secret-1'},
      );

      expect(await store.readCredential('engine-1'), 'secret-1');
      expect(await store.readCredential('engine-2'), isNull);

      store.readFailure = const EngineCredentialException(
        EngineCredentialFailure.temporarilyUnavailable,
      );
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

      store.readFailure = const EngineCredentialException(
        EngineCredentialFailure.dataCorrupt,
      );
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
    });

    test('write/delete round-trip is idempotent', () async {
      final store = _FakeCredentialStore();

      await store.writeCredential('engine-1', 'secret-1');
      expect(await store.readCredential('engine-1'), 'secret-1');

      await store.deleteCredential('engine-1');
      expect(await store.readCredential('engine-1'), isNull);

      await store.deleteCredential('engine-1');
      expect(await store.readCredential('engine-1'), isNull);
    });

    test('validates inputs before any IO', () async {
      final store = _FakeCredentialStore();

      await expectLater(
        store.writeCredential('engine-1', ''),
        throwsArgumentError,
      );
      await expectLater(
        store.writeCredential('a/b', 'secret'),
        throwsArgumentError,
      );
      await expectLater(store.readCredential('a/b'), throwsArgumentError);
      await expectLater(store.deleteCredential('a/b'), throwsArgumentError);
      expect(store.readCalls, isEmpty);
      expect(store.writeCalls, isEmpty);
      expect(store.deleteCalls, isEmpty);
    });
  });
}

class _FakeCredentialStore implements EngineCredentialStore {
  _FakeCredentialStore({Map<String, String>? initial})
      : credentials = <String, String>{...?initial};

  final Map<String, String> credentials;

  EngineCredentialException? readFailure;
  EngineCredentialException? writeFailure;
  EngineCredentialException? deleteFailure;

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
    final failure = writeFailure;
    if (failure != null) throw failure;
    credentials[engineId] = secret;
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    deleteCalls.add(engineId);
    final failure = deleteFailure;
    if (failure != null) throw failure;
    credentials.remove(engineId);
  }
}
