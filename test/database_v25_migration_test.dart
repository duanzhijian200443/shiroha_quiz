import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/ai_config_v24_schema.dart';
import 'package:shiroha_quiz/core/database/ai_config_v25_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v25 migration is idempotent when user_version is reset below 25',
      () async {
    final dir = await Directory.systemTemp.createTemp('ai_v25_reopen_');
    final path = p.join(dir.path, 'reopen.db');
    await DatabaseHelper.resetRuntimeProfileForTesting();
    try {
      final seeded = await DatabaseHelper.instance.openPathForTesting(path);
      await seeded.execute('PRAGMA user_version = 19');
      await seeded.close();
      final db = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        expect(await db.getVersion(), 25);
        await validateAiConfigV25Schema(db);
      } finally {
        await db.close();
      }
    } finally {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      await dir.delete(recursive: true);
    }
  });

  test('v24 upgrade preserves ambiguous origins, claims and binding modes',
      () async {
    final dir = await Directory.systemTemp.createTemp('ai_v25_');
    final path = p.join(dir.path, 'upgrade.db');
    await DatabaseHelper.resetRuntimeProfileForTesting();
    try {
      final seed = await DatabaseHelper.instance.openPathForTesting(path);
      for (final table in [
        'ai_capability_bindings',
        'ai_model_capability_claims',
        'ai_models',
        'ai_providers'
      ]) {
        await seed.execute('DROP TABLE $table');
      }
      await createAiConfigV24Schema(seed);
      await seed.insert('ai_providers', {
        'provider_id': 'z',
        'provider_kind': 'zhipu',
        'display_name': 'Z',
        'base_url': 'https://example.invalid',
        'state': 'ready',
        'revision': 3,
        'created_at': 1,
        'updated_at': 2,
        'last_connection_status': 'never',
        'last_sync_status': 'succeeded',
        'last_sync_at': 2,
      });
      for (final id in ['ambiguous', 'missing', 'glm-ocr']) {
        await seed.insert('ai_models', {
          'model_ref': 'ref-$id',
          'provider_id': 'z',
          'canonical_model_id': id,
          'display_name': 'Label $id',
          'availability': id == 'ambiguous' ? 'available' : 'unavailable',
          'first_seen_at': 1,
          'last_seen_at': 2,
        });
      }
      await seed.insert('ai_model_capability_claims', {
        'model_ref': 'ref-ambiguous',
        'capability': 'imageInput',
        'source': 'providerOfficial',
        'support': 'unsupported',
        'asserted_at': 2,
      });
      for (final entry in {
        'textModel': 'verified',
        'documentRecognition': 'legacyPreserved'
      }.entries) {
        await seed.insert('ai_capability_bindings', {
          'slot': entry.key,
          'model_ref':
              entry.key == 'textModel' ? 'ref-ambiguous' : 'ref-glm-ocr',
          'temperature': 0.4,
          'reasoning_effort': '',
          'validation_mode': entry.value,
          'revision': 7,
          'updated_at': 2,
        });
      }
      final beforeModels = await seed.query('ai_models', orderBy: 'model_ref');
      final beforeBindings =
          await seed.query('ai_capability_bindings', orderBy: 'slot');
      final beforeClaims = await seed.query('ai_model_capability_claims');
      await seed.execute('PRAGMA user_version = 24');
      await seed.close();
      final db = await DatabaseHelper.instance.openPathForTesting(path);
      try {
        expect(await db.getVersion(), 25);
        await validateAiConfigV25Schema(db);
        expect(await db.query('ai_capability_bindings', orderBy: 'slot'),
            beforeBindings);
        expect(await db.query('ai_model_capability_claims'), beforeClaims);
        final models = await db.query('ai_models', orderBy: 'model_ref');
        expect(models, hasLength(beforeModels.length));
        for (var i = 0; i < models.length; i++) {
          final curated = models[i]['canonical_model_id'] == 'glm-ocr';
          expect(models[i]['origin'], curated ? 'curated' : 'legacyImported');
          final expected = {
            ...beforeModels[i],
            'origin': curated ? 'curated' : 'legacyImported'
          };
          if (curated) expected['availability'] = 'available';
          expect(models[i], expected);
        }
        await db.update('ai_capability_bindings',
            {'validation_mode': 'userSelectedUnknown'},
            where: 'slot = ?', whereArgs: ['textModel']);
        await expectLater(
            db.update(
                'ai_capability_bindings', {'validation_mode': 'invented'}),
            throwsA(isA<DatabaseException>()));
        await expectLater(db.update('ai_models', {'origin': 'invented'}),
            throwsA(isA<DatabaseException>()));
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await db.close();
      }
    } finally {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      await dir.delete(recursive: true);
    }
  });
}
