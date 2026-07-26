import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test('isolated smoke profile is selected before repository database access',
      () async {
    final repository = AiEngineRepository(
      store: DatabaseHelper.instance,
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
}
