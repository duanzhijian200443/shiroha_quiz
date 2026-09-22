import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
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
    tempDir = await Directory.systemTemp.createTemp('b0_v24_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('v23 staged backup migrates through DatabaseHelper to v25', () async {
    final path = p.join(tempDir.path, 'staged-v23.db');
    final seed = await DatabaseHelper.instance.openPathForTesting(path);
    await seed.insert('ai_engines', <String, Object?>{
      'id': 'legacy-model-ref',
      'engine_type': 'text',
      'name': 'Legacy',
      'api_key': '',
      'base_url': 'https://api.deepseek.com',
      'model_name': 'deepseek-flash',
      'temperature': 0.4,
      'reasoning_effort': 'high',
      'is_active': 1,
    });
    await seed.execute('DROP TABLE ai_capability_bindings');
    await seed.execute('DROP TABLE ai_model_capability_claims');
    await seed.execute('DROP TABLE ai_models');
    await seed.execute('DROP TABLE ai_providers');
    await seed.execute('PRAGMA user_version = 23');
    await seed.close();

    await BackupSnapshotRepository(databaseHelper: DatabaseHelper.instance)
        .openStagedAndValidate(path);

    final migrated = await databaseFactory.openDatabase(path);
    try {
      expect(
        (await migrated.rawQuery('PRAGMA user_version')).single['user_version'],
        DatabaseHelper.databaseVersion,
      );
      expect(
        (await migrated.query('ai_providers')).single['provider_id'],
        'legacy-model-ref',
      );
      expect(
        (await migrated.query('ai_models')).single['model_ref'],
        'legacy-model-ref',
      );
      expect(
        (await migrated.query('ai_capability_bindings'))
            .map((row) => row['slot']),
        containsAll(<String>{'textModel', 'imageUnderstanding'}),
      );
    } finally {
      await migrated.close();
    }
  });
}
