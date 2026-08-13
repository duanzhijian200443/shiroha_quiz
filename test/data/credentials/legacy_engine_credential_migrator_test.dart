import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/credentials/ai_engine_credential_activation.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/credentials/legacy_engine_credential_migrator.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/persistence/legacy_engine_credential_migration_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseHelper helper;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    helper = DatabaseHelper.instance;
    await helper.database;
  });
  tearDown(() => DatabaseHelper.resetRuntimeProfileForTesting());

  test('secure present wins unchanged and legacy is scrubbed', () async {
    await _insert(helper, 'engine-a', 'CANARY_LEGACY_A');
    final secure = _FakeSecure({'engine-a': 'CANARY_SECURE_A'});
    await _migrate(helper, secure);
    expect(secure.values['engine-a'], 'CANARY_SECURE_A');
    expect(secure.writeCalls, isEmpty);
    expect(await _secret(helper, 'engine-a'), '');
  });

  test('missing writes, verifies exactly, then scrubs', () async {
    await _insert(helper, 'engine-b', 'CANARY_LEGACY_B');
    final secure = _FakeSecure();
    await _migrate(helper, secure);
    expect(secure.values['engine-b'], 'CANARY_LEGACY_B');
    expect(secure.events, ['read:engine-b', 'write:engine-b', 'read:engine-b']);
    expect(await _secret(helper, 'engine-b'), '');
  });

  test('write failure and verify mismatch preserve retry plaintext', () async {
    await _insert(helper, 'engine-c', 'CANARY_LEGACY_C');
    final writeFail = _FakeSecure()
      ..writeFailures['engine-c'] =
          EngineCredentialFailure.temporarilyUnavailable;
    await expectLater(
      _migrate(helper, writeFail),
      _fails(LegacyMigrationFailure.storeUnavailable),
    );
    expect(await _secret(helper, 'engine-c'), 'CANARY_LEGACY_C');

    await _insert(helper, 'engine-d', 'CANARY_LEGACY_D');
    final mismatch = _FakeSecure()..mismatchAfterWrite.add('engine-d');
    await expectLater(
      _migrate(helper, mismatch),
      _fails(LegacyMigrationFailure.verificationFailed),
    );
    expect(await _secret(helper, 'engine-d'), 'CANARY_LEGACY_D');
  });

  test('unavailable and corrupt stop without scrub or overwrite', () async {
    for (final entry in const {
      'engine-e': EngineCredentialFailure.temporarilyUnavailable,
      'engine-f': EngineCredentialFailure.dataCorrupt,
    }.entries) {
      await _insert(helper, entry.key, 'CANARY_LEGACY_EF');
      final secure = _FakeSecure()..readFailures[entry.key] = entry.value;
      await expectLater(
        _migrate(helper, secure),
        _fails(entry.value == EngineCredentialFailure.dataCorrupt
            ? LegacyMigrationFailure.secureCorrupt
            : LegacyMigrationFailure.storeUnavailable),
      );
      expect(await _secret(helper, entry.key), 'CANARY_LEGACY_EF');
      expect(secure.writeCalls, isNot(contains(entry.key)));
    }
  });

  test('partial batch retry is idempotent and secure-wins', () async {
    await _insert(helper, 'a-first', 'CANARY_BATCH_FIRST');
    await _insert(helper, 'b-second', 'CANARY_BATCH_SECOND');
    final secure = _FakeSecure()
      ..writeFailures['b-second'] =
          EngineCredentialFailure.temporarilyUnavailable;
    await expectLater(
      _migrate(helper, secure),
      _fails(LegacyMigrationFailure.storeUnavailable),
    );
    expect(await _secret(helper, 'a-first'), '');
    expect(await _secret(helper, 'b-second'), 'CANARY_BATCH_SECOND');

    secure.writeFailures.clear();
    secure.values['b-second'] = 'CANARY_SECURE_RETRY';
    await _migrate(helper, secure);
    expect(secure.values['a-first'], 'CANARY_BATCH_FIRST');
    expect(secure.values['b-second'], 'CANARY_SECURE_RETRY');
    expect(await helper.countLegacyPlaintextCredentials(), 0);
  });

  test('orphan ai_profiles scrub directly and DONE means plaintext zero',
      () async {
    final db = await helper.database;
    await db.insert('ai_profiles', {
      'id': 'legacy-profile',
      'name': 'Legacy',
      'text_api_key': 'CANARY_PROFILE_TEXT',
      'vision_api_key': 'CANARY_PROFILE_VISION',
    });
    final secure = _FakeSecure();
    expect(await _migrate(helper, secure), LegacyMigrationResult.done);
    final row = (await db.query('ai_profiles')).single;
    expect(row['text_api_key'], '');
    expect(row['vision_api_key'], '');
    expect(secure.events, isEmpty);
    expect(await helper.countLegacyPlaintextCredentials(), 0);
  });

  test('startup order is open, secure, migrate, repository', () async {
    await _insert(helper, 'engine-startup', 'CANARY_STARTUP');
    final secure = _FakeSecure();
    final order = <String>[];
    final repository = await activateAiEngineRepository(
      openDatabase: () async => order.add('open'),
      store: helper,
      migrationStore: _OrderedStore(helper, order),
      createCredentialStore: () {
        order.add('secure');
        return secure;
      },
    );
    expect(order.take(3), ['open', 'secure', 'migrate']);
    expect(repository, isA<AiEngineRepository>());
    expect((await repository.getEngines(AiEngineType.text)).single.apiKey,
        'CANARY_STARTUP');
  });

  test('startup failure exposes no runtime repository', () async {
    await _insert(helper, 'engine-fail', 'CANARY_FAIL');
    final secure = _FakeSecure()
      ..readFailures['engine-fail'] =
          EngineCredentialFailure.temporarilyUnavailable;
    AiEngineRepository? repository;
    await expectLater(
      () async {
        repository = await activateAiEngineRepository(
          openDatabase: () async {},
          store: helper,
          migrationStore: helper,
          createCredentialStore: () => secure,
        );
      }(),
      _fails(LegacyMigrationFailure.storeUnavailable),
    );
    expect(repository, isNull);
  });
}

Future<LegacyMigrationResult> _migrate(
        DatabaseHelper helper, EngineCredentialStore secure) =>
    LegacyEngineCredentialMigrator(
      legacyStore: helper,
      credentialStore: secure,
    ).migrate();

Matcher _fails(LegacyMigrationFailure failure) => throwsA(
      isA<LegacyMigrationException>()
          .having((error) => error.failure, 'failure', failure),
    );

Future<void> _insert(DatabaseHelper helper, String id, String secret) async {
  await (await helper.database).insert('ai_engines', {
    'id': id,
    'engine_type': 'text',
    'name': id,
    'api_key': secret,
    'base_url': 'https://example.invalid',
    'model_name': 'fixture-model',
    'is_active': 1,
  });
}

Future<String?> _secret(DatabaseHelper helper, String id) async {
  final rows = await (await helper.database).query(
    'ai_engines',
    columns: const ['api_key'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.single['api_key'] as String?;
}

final class _FakeSecure implements EngineCredentialStore {
  _FakeSecure([Map<String, String>? initial])
      : values = <String, String>{...?initial};
  final Map<String, String> values;
  final Map<String, EngineCredentialFailure> readFailures = {};
  final Map<String, EngineCredentialFailure> writeFailures = {};
  final Set<String> mismatchAfterWrite = {};
  final Set<String> _written = {};
  final List<String> writeCalls = [];
  final List<String> events = [];

  @override
  Future<String?> readCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    events.add('read:$engineId');
    final failure = readFailures[engineId];
    if (failure != null) throw EngineCredentialException(failure);
    if (_written.contains(engineId) && mismatchAfterWrite.contains(engineId)) {
      return 'CANARY_MISMATCH';
    }
    return values[engineId];
  }

  @override
  Future<void> writeCredential(String engineId, String secret) async {
    validatedEngineCredentialId(engineId);
    validatedEngineCredentialSecret(secret);
    writeCalls.add(engineId);
    events.add('write:$engineId');
    final failure = writeFailures[engineId];
    if (failure != null) throw EngineCredentialException(failure);
    values[engineId] = secret;
    _written.add(engineId);
  }

  @override
  Future<void> deleteCredential(String engineId) async {
    validatedEngineCredentialId(engineId);
    values.remove(engineId);
  }
}

final class _OrderedStore implements LegacyEngineCredentialMigrationStore {
  _OrderedStore(this.delegate, this.order);
  final DatabaseHelper delegate;
  final List<String> order;

  @override
  Future<List<LegacyEngineCredential>> listLegacyEngineCredentials() {
    order.add('migrate');
    return delegate.listLegacyEngineCredentials();
  }

  @override
  Future<int> countLegacyPlaintextCredentials() =>
      delegate.countLegacyPlaintextCredentials();
  @override
  Future<bool> scrubLegacyEngineCredential(String id, String secret) =>
      delegate.scrubLegacyEngineCredential(id, secret);
  @override
  Future<void> scrubLegacyAiProfileCredentials() =>
      delegate.scrubLegacyAiProfileCredentials();
}
