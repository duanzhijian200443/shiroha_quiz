import 'package:uuid/uuid.dart';

import 'ai_config_v24_schema.dart';
import 'sqflite_runtime.dart';

/// Called inside DatabaseHelper's open transaction. Idempotent: a v24-shaped
/// ai config schema is upgraded to v25, and an already-v25 shape (for example
/// an onCreate-built database whose user_version was reset for a migration
/// test) is accepted unchanged. Final state is still validated strictly.
Future<void> migrateAiConfigToV25(DatabaseExecutor db) async {
  await _ensureOriginColumn(db);
  await _ensureUserSelectedUnknownBindingCheck(db);
  for (final provider in await db.query('ai_providers')) {
    await installCuratedModels(db, provider);
  }
  await validateAiConfigV25Schema(db);
}

Future<void> _ensureOriginColumn(DatabaseExecutor db) async {
  final columns = await db.rawQuery('PRAGMA table_info(ai_models)');
  if (columns.isEmpty) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.malformedSchema);
  }
  if (columns.any((row) => row['name'] == 'origin')) return;
  await db.execute("ALTER TABLE ai_models ADD COLUMN origin TEXT NOT NULL "
      "DEFAULT 'legacyImported' CHECK(origin IN "
      "('providerCatalog', 'curated', 'userDefined', 'legacyImported'))");
}

Future<void> _ensureUserSelectedUnknownBindingCheck(
  DatabaseExecutor db,
) async {
  final tables = await db.rawQuery(
    "SELECT sql FROM sqlite_master "
    "WHERE type = 'table' AND name = 'ai_capability_bindings'",
  );
  if (tables.isEmpty || tables.single['sql'] == null) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.malformedSchema);
  }
  if ((tables.single['sql']! as String).contains('userSelectedUnknown')) {
    return;
  }
  await db.execute(aiCapabilityBindingsTableDdl
      .replaceFirst('ai_capability_bindings (', 'ai_capability_bindings_v25 (')
      .replaceFirst("'verified', 'legacyPreserved'",
          "'verified', 'legacyPreserved', 'userSelectedUnknown'"));
  await db.execute(
      'INSERT INTO ai_capability_bindings_v25 SELECT * FROM ai_capability_bindings');
  await db.execute('DROP TABLE ai_capability_bindings');
  await db.execute(
      'ALTER TABLE ai_capability_bindings_v25 RENAME TO ai_capability_bindings');
}

/// Explicit special-model catalog, independent of the capability queue.
/// The zhipu/glm-ocr entry is owned by the production layout_parsing contract.
/// Materialize on migration/provider creation, never infer origin on reads.
Future<void> installCuratedModels(
  DatabaseExecutor db,
  Map<String, Object?> provider,
) async {
  if (provider['provider_kind'] != 'zhipu') return;
  final providerId = provider['provider_id']! as String;
  final existing = await db.query('ai_models',
      where: 'provider_id = ? AND canonical_model_id = ?',
      whereArgs: [providerId, 'glm-ocr']);
  if (existing.isNotEmpty) {
    await db.update(
        'ai_models', {'origin': 'curated', 'availability': 'available'},
        where: 'model_ref = ?', whereArgs: [existing.single['model_ref']]);
    return;
  }
  await db.insert('ai_models', {
    'model_ref': const Uuid()
        .v5(Namespace.url.value, 'shiroha:curated:$providerId/glm-ocr'),
    'provider_id': providerId,
    'canonical_model_id': 'glm-ocr',
    'display_name': 'glm-ocr',
    'availability': 'available',
    'first_seen_at': 0,
    'last_seen_at': 0,
    'origin': 'curated',
  });
}

Future<void> validateAiConfigV25Schema(DatabaseExecutor db) async {
  await validateAiConfigV24Schema(db, withOrigin: true);
  final invalid = await db.rawQuery(
      "SELECT model_ref FROM ai_models WHERE origin IS NULL OR origin NOT IN ('providerCatalog', 'curated', 'userDefined', 'legacyImported')");
  if (invalid.isNotEmpty) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.malformedSchema);
  }
}
