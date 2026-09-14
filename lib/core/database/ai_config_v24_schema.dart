library;

import 'sqflite_runtime.dart';

const int aiConfigSchemaVersion = 24;

const String aiProvidersTableDdl = '''
CREATE TABLE ai_providers (
  provider_id TEXT PRIMARY KEY NOT NULL,
  provider_kind TEXT NOT NULL CHECK(provider_kind IN ('deepseek', 'zhipu', 'gemini', 'openai_compatible')),
  display_name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('ready', 'legacy_incomplete')),
  revision INTEGER NOT NULL CHECK(revision >= 0),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
  last_connection_status TEXT NOT NULL CHECK(last_connection_status IN ('never', 'succeeded', 'failed')),
  last_connection_at INTEGER,
  last_sync_status TEXT NOT NULL CHECK(last_sync_status IN ('never', 'succeeded', 'failed')),
  last_sync_at INTEGER,
  CHECK(state = 'legacy_incomplete' OR length(base_url) > 0)
);
''';

const String aiModelsTableDdl = '''
CREATE TABLE ai_models (
  model_ref TEXT PRIMARY KEY NOT NULL,
  provider_id TEXT NOT NULL,
  canonical_model_id TEXT NOT NULL CHECK(length(canonical_model_id) BETWEEN 1 AND 200 AND canonical_model_id = trim(canonical_model_id)),
  display_name TEXT NOT NULL,
  availability TEXT NOT NULL CHECK(availability IN ('available', 'unavailable')),
  first_seen_at INTEGER NOT NULL CHECK(first_seen_at >= 0),
  last_seen_at INTEGER NOT NULL CHECK(last_seen_at >= 0),
  UNIQUE(provider_id, canonical_model_id),
  FOREIGN KEY(provider_id) REFERENCES ai_providers(provider_id) ON DELETE CASCADE
);
''';

const String aiModelCapabilityClaimsTableDdl = '''
CREATE TABLE ai_model_capability_claims (
  model_ref TEXT NOT NULL,
  capability TEXT NOT NULL CHECK(capability IN ('textInput', 'imageInput', 'textOutput', 'reasoning', 'toolCalling', 'ocr', 'embedding')),
  source TEXT NOT NULL CHECK(source IN ('providerOfficial', 'shirohaRegistry', 'userDeclaration', 'capabilityProbe')),
  support TEXT NOT NULL CHECK(support IN ('supported', 'unsupported')),
  asserted_at INTEGER NOT NULL CHECK(asserted_at >= 0),
  PRIMARY KEY(model_ref, capability, source),
  FOREIGN KEY(model_ref) REFERENCES ai_models(model_ref) ON DELETE CASCADE
);
''';

const String aiCapabilityBindingsTableDdl = '''
CREATE TABLE ai_capability_bindings (
  slot TEXT PRIMARY KEY NOT NULL CHECK(slot IN ('textModel', 'imageUnderstanding', 'documentRecognition')),
  model_ref TEXT NOT NULL,
  temperature REAL NOT NULL CHECK(temperature >= 0.0 AND temperature <= 2.0),
  reasoning_effort TEXT NOT NULL,
  validation_mode TEXT NOT NULL CHECK(validation_mode IN ('verified', 'legacyPreserved')),
  revision INTEGER NOT NULL CHECK(revision >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
  FOREIGN KEY(model_ref) REFERENCES ai_models(model_ref) ON DELETE RESTRICT
);
''';

const String aiModelsProviderIndexDdl = '''
CREATE INDEX idx_ai_models_provider ON ai_models(provider_id);
''';

Future<void> createAiConfigV24Schema(DatabaseExecutor db) async {
  for (final ddl in <String>[
    aiProvidersTableDdl,
    aiModelsTableDdl,
    aiModelCapabilityClaimsTableDdl,
    aiCapabilityBindingsTableDdl,
    aiModelsProviderIndexDdl,
  ]) {
    await db.execute(
      ddl
          .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
          .replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS '),
    );
  }
}

/// Additive v23 -> v24 migration. The secure store is intentionally not
/// touched: migrated provider/model identities remain equal to the old engine
/// id, so `engine.<id>` continues to resolve the same credential.
Future<void> migrateLegacyAiEnginesToV24(DatabaseExecutor db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ai_engines'",
  );
  if (tables.isEmpty) return;

  final rows = await db.query('ai_engines', orderBy: 'id ASC');
  for (final row in rows) {
    final id = _requiredLegacyId(row['id']);
    final name = row['name']?.toString() ?? '';
    final baseUrl = row['base_url']?.toString() ?? '';
    final modelId = row['model_name']?.toString() ?? '';
    final validModelId = _isValidCanonicalModelId(modelId);
    final complete = baseUrl.trim().isNotEmpty && validModelId;
    await db.insert(
      'ai_providers',
      <String, Object?>{
        'provider_id': id,
        'provider_kind': _legacyProviderKind(baseUrl),
        'display_name': name,
        'base_url': baseUrl,
        'state': complete ? 'ready' : 'legacy_incomplete',
        'revision': 0,
        'created_at': 0,
        'updated_at': 0,
        'last_connection_status': 'never',
        'last_connection_at': null,
        'last_sync_status': 'never',
        'last_sync_at': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (!validModelId) continue;
    await db.insert(
      'ai_models',
      <String, Object?>{
        'model_ref': id,
        'provider_id': id,
        'canonical_model_id': modelId,
        'display_name': modelId,
        'availability': 'available',
        'first_seen_at': 0,
        'last_seen_at': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  for (final slot in const <String>[
    'textModel',
    'imageUnderstanding',
    'documentRecognition',
  ]) {
    final selected = await _legacyActiveRow(db, slot);
    if (selected == null) continue;
    final modelRef = selected['id']?.toString() ?? '';
    final modelExists = await db.query(
      'ai_models',
      columns: const <String>['model_ref'],
      where: 'model_ref = ?',
      whereArgs: <Object?>[modelRef],
      limit: 1,
    );
    if (modelExists.isEmpty) continue;
    final temperature = switch (selected['temperature']) {
      final num value when value.isFinite => value.toDouble().clamp(0.0, 2.0),
      _ => slot == 'documentRecognition' ? 0.0 : 0.7,
    };
    await db.insert(
      'ai_capability_bindings',
      <String, Object?>{
        'slot': slot,
        'model_ref': modelRef,
        'temperature': temperature,
        'reasoning_effort': selected['reasoning_effort']?.toString() ?? '',
        'validation_mode': 'legacyPreserved',
        'revision': 0,
        'updated_at': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}

Future<Map<String, Object?>?> _legacyActiveRow(
  DatabaseExecutor db,
  String slot,
) async {
  final legacyType = switch (slot) {
    'textModel' => 'text',
    'imageUnderstanding' => 'vision',
    'documentRecognition' => 'ocr',
    _ => throw StateError('invalid capability slot'),
  };
  final settingsExist = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'app_settings'",
  );
  if (settingsExist.isEmpty) {
    return _legacyFallbackActiveRow(db, slot, legacyType);
  }
  final settingRows = await db.query(
    'app_settings',
    columns: const <String>['value'],
    where: 'key = ?',
    whereArgs: <Object?>['active_${legacyType}_engine_id'],
    limit: 1,
  );
  if (settingRows.isNotEmpty) {
    final activeId = settingRows.single['value']?.toString();
    if (activeId != null) {
      final explicit = await db.query(
        'ai_engines',
        where: 'id = ?',
        whereArgs: <Object?>[activeId],
        limit: 1,
      );
      if (explicit.isNotEmpty) {
        return _compatibleWithSlot(explicit.single, slot)
            ? explicit.single
            : null;
      }
    }
  }
  return _legacyFallbackActiveRow(db, slot, legacyType);
}

Future<Map<String, Object?>?> _legacyFallbackActiveRow(
  DatabaseExecutor db,
  String slot,
  String legacyType,
) async {
  final matching = await db.query(
    'ai_engines',
    where: 'engine_type = ? AND is_active = 1',
    whereArgs: <Object?>[legacyType],
    limit: 1,
  );
  if (matching.isNotEmpty) return matching.single;
  final global = await db.query(
    'ai_engines',
    where: 'is_active = 1',
    limit: 1,
  );
  if (global.isEmpty || !_compatibleWithSlot(global.single, slot)) return null;
  return global.single;
}

bool _compatibleWithSlot(Map<String, Object?> row, String slot) {
  final type = row['engine_type']?.toString();
  return slot == 'documentRecognition' ? type == 'ocr' : type != 'ocr';
}

String _requiredLegacyId(Object? value) {
  final id = value?.toString() ?? '';
  if (id.isEmpty ||
      id.runes.length > 128 ||
      id.contains('/') ||
      id.runes.any((rune) => rune < 0x20)) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.invalidLegacyId);
  }
  return id;
}

String _legacyProviderKind(String baseUrl) {
  final normalized = baseUrl.toLowerCase();
  if (normalized.contains('generativelanguage.googleapis.com')) return 'gemini';
  if (normalized.contains('bigmodel.cn') || normalized.contains('z.ai')) {
    return 'zhipu';
  }
  if (normalized.contains('deepseek.com')) return 'deepseek';
  return 'openai_compatible';
}

Future<void> validateAiConfigV24Schema(DatabaseExecutor db) async {
  const expectedColumns = <String, List<String>>{
    'ai_providers': <String>[
      'provider_id',
      'provider_kind',
      'display_name',
      'base_url',
      'state',
      'revision',
      'created_at',
      'updated_at',
      'last_connection_status',
      'last_connection_at',
      'last_sync_status',
      'last_sync_at',
    ],
    'ai_models': <String>[
      'model_ref',
      'provider_id',
      'canonical_model_id',
      'display_name',
      'availability',
      'first_seen_at',
      'last_seen_at',
    ],
    'ai_model_capability_claims': <String>[
      'model_ref',
      'capability',
      'source',
      'support',
      'asserted_at',
    ],
    'ai_capability_bindings': <String>[
      'slot',
      'model_ref',
      'temperature',
      'reasoning_effort',
      'validation_mode',
      'revision',
      'updated_at',
    ],
  };
  for (final entry in expectedColumns.entries) {
    final columns = await db.rawQuery('PRAGMA table_info(${entry.key})');
    final actual = columns.map((row) => row['name']).toList(growable: false);
    if (actual.length != entry.value.length ||
        List.generate(actual.length, (index) => index)
            .any((index) => actual[index] != entry.value[index])) {
      throw const AiConfigSchemaException(
          AiConfigSchemaFailure.malformedSchema);
    }
  }
  final modelIds = await db.query(
    'ai_models',
    columns: const <String>['canonical_model_id'],
  );
  if (modelIds.any(
    (row) => !_isValidCanonicalModelId(
      row['canonical_model_id']?.toString() ?? '',
    ),
  )) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.malformedSchema);
  }
  if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
    throw const AiConfigSchemaException(AiConfigSchemaFailure.malformedSchema);
  }
}

bool _isValidCanonicalModelId(String value) =>
    value.isNotEmpty &&
    value.runes.length <= 200 &&
    value.trim() == value &&
    !value.runes.any(
      (rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f),
    );

enum AiConfigSchemaFailure { malformedSchema, invalidLegacyId }

final class AiConfigSchemaException implements Exception {
  const AiConfigSchemaException(this.failure);
  final AiConfigSchemaFailure failure;

  @override
  String toString() => 'AiConfigSchemaException(${failure.name})';
}
