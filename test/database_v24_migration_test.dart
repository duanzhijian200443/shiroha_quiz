import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/ai_config_v24_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('ai_config_v24_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('fresh database creates and validates the v24 authority', () async {
    final db = await DatabaseHelper.instance.openPathForTesting(
      inMemoryDatabasePath,
    );
    try {
      expect(DatabaseHelper.databaseVersion, aiConfigSchemaVersion);
      await expectLater(validateAiConfigV24Schema(db), completes);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ai_%'",
      );
      expect(
        tables.map((row) => row['name']),
        containsAll(<String>{
          'ai_providers',
          'ai_models',
          'ai_model_capability_claims',
          'ai_capability_bindings',
        }),
      );
    } finally {
      await db.close();
    }
  });

  test('v23 migration preserves identities without merging or claims',
      () async {
    final path = p.join(tempDir.path, 'legacy.db');
    final seed = await DatabaseHelper.instance.openPathForTesting(path);
    await seed.execute('DROP TABLE ai_capability_bindings');
    await seed.execute('DROP TABLE ai_model_capability_claims');
    await seed.execute('DROP TABLE ai_models');
    await seed.execute('DROP TABLE ai_providers');
    await seed.execute('PRAGMA user_version = 23');
    await seed.execute(
      'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    for (final row in <Map<String, Object?>>[
      <String, Object?>{
        'id': 'engine-a',
        'engine_type': 'text',
        'name': 'Account',
        'api_key': '',
        'base_url': 'https://api.deepseek.com',
        'model_name': 'deepseek-flash',
        'temperature': 0.4,
        'reasoning_effort': 'high',
        'is_active': 1,
      },
      <String, Object?>{
        'id': 'engine-b',
        'engine_type': 'vision',
        'name': 'Account',
        'api_key': '',
        'base_url': 'https://api.deepseek.com',
        'model_name': 'Vision-Exact',
        'temperature': 0.6,
        'reasoning_effort': '',
        'is_active': 1,
      },
      <String, Object?>{
        'id': 'engine-incomplete',
        'engine_type': 'ocr',
        'name': '',
        'api_key': '',
        'base_url': '',
        'model_name': '',
        'temperature': 0.0,
        'reasoning_effort': '',
        'is_active': 0,
      },
      <String, Object?>{
        'id': 'engine-ocr',
        'engine_type': 'ocr',
        'name': 'OCR',
        'api_key': '',
        'base_url': 'https://open.bigmodel.cn',
        'model_name': 'glm-ocr',
        'temperature': 0.0,
        'reasoning_effort': '',
        'is_active': 1,
      },
      <String, Object?>{
        'id': 'engine-invalid-model',
        'engine_type': 'text',
        'name': 'Invalid model id',
        'api_key': '',
        'base_url': 'https://example.invalid',
        'model_name': ' silently-rewritten-model',
        'temperature': 0.7,
        'reasoning_effort': '',
        'is_active': 0,
      },
    ]) {
      await seed.insert('ai_engines', row);
    }
    await seed.insert('app_settings', <String, Object?>{
      'key': 'active_text_engine_id',
      'value': 'engine-a',
    });
    await seed.insert('app_settings', <String, Object?>{
      'key': 'active_vision_engine_id',
      'value': 'engine-b',
    });
    await seed.insert('app_settings', <String, Object?>{
      'key': 'active_ocr_engine_id',
      'value': 'dangling-engine-id',
    });
    await seed.close();

    final migrated = await DatabaseHelper.instance.openPathForTesting(path);
    try {
      expect(
        (await migrated.query('ai_providers')).map((row) => row['provider_id']),
        containsAll(<String>{
          'engine-a',
          'engine-b',
          'engine-incomplete',
          'engine-ocr',
          'engine-invalid-model',
        }),
      );
      expect(await migrated.query('ai_models'), hasLength(3));
      expect(await migrated.query('ai_model_capability_claims'), isEmpty);
      final bindings = await migrated.query(
        'ai_capability_bindings',
        orderBy: 'slot ASC',
      );
      expect(bindings, hasLength(3));
      expect(
        bindings.every(
          (row) => row['validation_mode'] == 'legacyPreserved',
        ),
        isTrue,
      );
      expect(
        bindings.singleWhere(
            (row) => row['slot'] == 'documentRecognition')['model_ref'],
        'engine-ocr',
      );
      expect(
        (await migrated.query(
          'ai_providers',
          where: 'provider_id = ?',
          whereArgs: <Object?>['engine-incomplete'],
        ))
            .single['state'],
        'legacy_incomplete',
      );
      expect(
        await migrated.query(
          'ai_models',
          where: 'model_ref = ?',
          whereArgs: <Object?>['engine-invalid-model'],
        ),
        isEmpty,
      );
      expect(
        (await migrated.query(
          'ai_providers',
          where: 'provider_id = ?',
          whereArgs: <Object?>['engine-invalid-model'],
        ))
            .single['state'],
        'legacy_incomplete',
      );
      expect(
        (await migrated.query('ai_engines')).map((row) => row['id']),
        containsAll(<String>{
          'engine-a',
          'engine-b',
          'engine-incomplete',
          'engine-ocr',
          'engine-invalid-model',
        }),
      );
    } finally {
      await migrated.close();
    }
  });

  test('failed v23 migration rolls back schema and user version', () async {
    final path = p.join(tempDir.path, 'invalid-legacy.db');
    final seed = await DatabaseHelper.instance.openPathForTesting(path);
    await seed.execute('DROP TABLE ai_capability_bindings');
    await seed.execute('DROP TABLE ai_model_capability_claims');
    await seed.execute('DROP TABLE ai_models');
    await seed.execute('DROP TABLE ai_providers');
    await seed.insert('ai_engines', <String, Object?>{
      'id': 'invalid/id',
      'engine_type': 'text',
      'name': 'Invalid',
      'api_key': '',
      'base_url': 'https://example.invalid',
      'model_name': 'model',
      'temperature': 0.7,
      'reasoning_effort': '',
      'is_active': 1,
    });
    await seed.execute('PRAGMA user_version = 23');
    await seed.close();

    await expectLater(
      DatabaseHelper.instance.openPathForTesting(path),
      throwsA(
        isA<AiConfigSchemaException>().having(
          (error) => error.failure,
          'failure',
          AiConfigSchemaFailure.invalidLegacyId,
        ),
      ),
    );

    final probe = await databaseFactory.openDatabase(path);
    try {
      expect(
        (await probe.rawQuery('PRAGMA user_version')).single['user_version'],
        23,
      );
      expect(
        await probe.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ai_providers'",
        ),
        isEmpty,
      );
      expect((await probe.query('ai_engines')).single['id'], 'invalid/id');
    } finally {
      await probe.close();
    }
  });
}
