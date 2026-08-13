import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_engine_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('database_runtime_');
  });

  tearDown(() async {
    try {
      await DatabaseHelper.resetRuntimeProfileForTesting();
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('isolated smoke profile is selected before repository database access',
      () async {
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
      credentialStore: MemoryEngineCredentialStore(),
    );

    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );

    await repository.saveEngine(const AiEngineProfile(
      id: 'runtime-profile-fixture',
      engineType: AiEngineType.ocr,
      name: 'runtime-profile-fixture',
      apiKey: 'fixture-value',
      baseUrl: 'https://example.invalid',
      modelName: 'fixture-model',
      temperature: 0,
      reasoningEffort: '',
      isActive: true,
    ));

    expect(
      DatabaseHelper.runtimeProfile,
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );
    expect(
      DatabaseHelper.openedDatabasePathForTesting,
      inMemoryDatabasePath,
    );
  });

  test('runtime profile cannot change after database opening begins', () async {
    await DatabaseHelper.instance.database;

    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.isolatedSmokeInMemory,
      ),
      throwsStateError,
    );
  });

  test('runtime profile can only be configured once', () {
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );

    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.isolatedSmokeInMemory,
      ),
      throwsStateError,
    );
  });

  test('closing a previously opened database does not unlock the profile',
      () async {
    await DatabaseHelper.instance.database;
    await DatabaseHelper.instance.close();

    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.isolatedSmokeInMemory,
      ),
      throwsStateError,
    );
  });

  test('isolated delete only closes the in-memory database', () async {
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );
    await DatabaseHelper.instance.database;

    await DatabaseHelper.deleteDatabaseFile();

    expect(DatabaseHelper.openedDatabasePathForTesting, isNull);
    expect(
      DatabaseHelper.runtimeProfile,
      DatabaseRuntimeProfile.isolatedSmokeInMemory,
    );
  });

  test('explicit read-only profile requires an existing absolute path', () {
    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.explicitReadOnly,
      ),
      throwsA(
        isA<DatabaseRuntimeException>().having(
          (error) => error.failure,
          'failure',
          DatabaseRuntimeFailure.invalidPath,
        ),
      ),
    );

    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.explicitReadOnly,
        databasePath: 'relative.db',
      ),
      throwsA(isA<DatabaseRuntimeException>()),
    );

    final missingPath = p.join(tempDir.path, 'missing.db');
    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.explicitReadOnly,
        databasePath: missingPath,
      ),
      throwsA(isA<DatabaseRuntimeException>()),
    );
    expect(File(missingPath).existsSync(), isFalse);
  });

  test('non-read-only profiles reject an explicit path', () async {
    final path = p.join(tempDir.path, 'existing.db');
    await File(path).create();

    expect(
      () => DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.production,
        databasePath: path,
      ),
      throwsA(
        isA<DatabaseRuntimeException>().having(
          (error) => error.failure,
          'failure',
          DatabaseRuntimeFailure.unexpectedPath,
        ),
      ),
    );
  });

  test('explicit read-only opens existing v19 without permitting writes',
      () async {
    final path = p.join(tempDir.path, 'read_only_v19.db');
    final created = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      await created.insert('bank_folders', <String, Object?>{
        'bank_name': 'Runtime Proof',
        'folder_name': 'Unchanged',
      });
    } finally {
      await created.close();
    }

    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitReadOnly,
      databasePath: path,
    );
    try {
      final database = await DatabaseHelper.instance.database;

      expect(
        DatabaseHelper.runtimeProfile,
        DatabaseRuntimeProfile.explicitReadOnly,
      );
      expect(
        DatabaseHelper.openedDatabasePathForTesting,
        File(path).resolveSymbolicLinksSync(),
      );
      expect(
        await database.query(
          'bank_folders',
          where: 'bank_name = ?',
          whereArgs: <Object?>['Runtime Proof'],
        ),
        <Map<String, Object?>>[
          <String, Object?>{
            'bank_name': 'Runtime Proof',
            'folder_name': 'Unchanged',
          },
        ],
      );
      await expectLater(
        database.insert('bank_folders', <String, Object?>{
          'bank_name': 'Forbidden',
          'folder_name': 'Write',
        }),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      await DatabaseHelper.deleteDatabaseFile();
    }
    expect(File(path).existsSync(), isTrue);
  });

  test('explicit read-only rejects v18 without migrating it', () async {
    final path = p.join(tempDir.path, 'read_only_v18.db');
    final raw = await databaseFactory.openDatabase(path);
    try {
      await raw.execute('PRAGMA user_version = 18');
    } finally {
      await raw.close();
    }

    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitReadOnly,
      databasePath: path,
    );

    await expectLater(
      DatabaseHelper.instance.database,
      throwsA(
        isA<DatabaseRuntimeException>().having(
          (error) => error.failure,
          'failure',
          DatabaseRuntimeFailure.unsupportedSchemaVersion,
        ),
      ),
    );

    final reopened = await databaseFactory.openDatabase(path);
    try {
      final version = await reopened.rawQuery('PRAGMA user_version');
      expect(version.single['user_version'], 18);
    } finally {
      await reopened.close();
    }
  });
}
