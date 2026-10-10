import '../../data/repositories/generated_proposal_reader.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import 'sqflite_runtime.dart';
import 'generated_proposal_v32_schema.dart';

const generatedProposalSchemaVersion = 32;
const generatedProposalOriginSchemaVersion = 34;
const generatedProposalTables = generatedProposalTableNames;

const _retainedSchemaObjects = generatedProposalV32SchemaObjects;

final generatedProposalSchemaObjects = <String, String>{
  ..._retainedSchemaObjects,
  'generated_question_proposals':
      _retainedSchemaObjects['generated_question_proposals']!
          .replaceFirst('schema_version=1', 'schema_version IN (1,2)')
          .replaceFirst("origin_kind IN ('local','synthetic')",
              "origin_kind IN ('local','synthetic','external')")
          .replaceFirst('  UNIQUE(client_profile_id,submission_key),',
              '''  external_origin_json TEXT,
  CHECK((origin_kind IN ('local','synthetic') AND schema_version=1 AND external_origin_json IS NULL) OR
    (origin_kind='external' AND schema_version=2 AND length(client_profile_id)=36 AND external_origin_json IS NOT NULL AND typeof(external_origin_json)='text' AND length(CAST(external_origin_json AS BLOB)) BETWEEN 1 AND 32768)),
  UNIQUE(client_profile_id,submission_key),'''),
  'gq_original_header_immutable':
      _retainedSchemaObjects['gq_original_header_immutable']!.replaceFirst(
          'actual_count,original_target_json ON',
          'actual_count,original_target_json,external_origin_json ON'),
};

Future<void> createGeneratedProposalSchema(DatabaseExecutor db,
    {bool ifNotExists = false}) async {
  for (final sql in generatedProposalSchemaObjects.values) {
    await db.execute(ifNotExists
        ? sql
            .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
            .replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ')
            .replaceFirst('CREATE TRIGGER ', 'CREATE TRIGGER IF NOT EXISTS ')
        : sql);
  }
}

Future<void> migrateGeneratedProposalSchema(DatabaseExecutor db) async {
  // Pre-v32 upgrades create/validate historical physical objects, not v34 rules.
  // Exact empty current objects are retained for existing reset-version fixtures.
  final columns =
      await db.rawQuery('PRAGMA table_info(generated_question_proposals)');
  if (!columns.any((c) => c['name'] == 'external_origin_json')) {
    return migrateGeneratedProposalToV32(db);
  }
  await validateGeneratedProposalSchema(db);
  for (final table in generatedProposalTables) {
    if ((await db.query(table, limit: 1)).isNotEmpty) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }
}

/// Caller owns the upgrade transaction. FK enforcement stays ON, including at
/// commit. Child rows and their triggers are never dropped or rewritten.
Future<void> migrateGeneratedProposalOriginToV34(DatabaseExecutor db) async {
  final columns =
      await db.rawQuery('PRAGMA table_info(generated_question_proposals)');
  if (columns.any((c) => c['name'] == 'external_origin_json')) {
    await validateGeneratedProposalSchema(db);
    for (final table in generatedProposalTables) {
      if ((await db.query(table, limit: 1)).isNotEmpty) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    return;
  }
  await validateGeneratedProposalV32Schema(db);
  await validateGeneratedProposalData(db);
  if ((await db.rawQuery('PRAGMA foreign_keys')).single.values.single != 1 ||
      (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE name='generated_question_origin_v34_source'"))
          .isNotEmpty) {
    generatedFail(GeneratedFailure.corruptState);
  }
  final names = columns.map((c) => c['name'] as String).toList();
  final projection = names.join(',');
  await db.execute(
      'CREATE TABLE generated_question_origin_v34_source AS SELECT * FROM generated_question_proposals');
  await db.execute('PRAGMA defer_foreign_keys=ON');
  await db.execute('DROP TABLE generated_question_proposals');
  await db
      .execute(generatedProposalSchemaObjects['generated_question_proposals']!);
  for (final name in [
    'idx_generated_pending_owner',
    'gq_original_header_immutable',
    'gq_terminal_immutable'
  ]) {
    await db.execute(generatedProposalSchemaObjects[name]!);
  }
  // Reinsertion under the original parent name discharges deferred FK checks.
  await db.execute(
      'INSERT INTO generated_question_proposals ($projection) SELECT $projection FROM generated_question_origin_v34_source');
  for (final pair in [
    ('generated_question_origin_v34_source', 'generated_question_proposals'),
    ('generated_question_proposals', 'generated_question_origin_v34_source')
  ]) {
    if ((await db.rawQuery(
            'SELECT $projection FROM ${pair.$1} EXCEPT SELECT $projection FROM ${pair.$2} LIMIT 1'))
        .isNotEmpty) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }
  await db.execute('DROP TABLE generated_question_origin_v34_source');
  await validateGeneratedProposalSchema(db);
  await validateGeneratedProposalData(db);
  if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
    generatedFail(GeneratedFailure.corruptState);
  }
}

String _sql(String text) => text
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r';\s*$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([(),=;])\s*'), (match) => match[1]!)
    .trim();
Future<void> validateGeneratedProposalSchema(DatabaseExecutor db) async {
  try {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'generated_question_%'");
    if (tables.any((t) => !generatedProposalTables.contains(t['name']))) {
      generatedFail(GeneratedFailure.corruptState);
    }
    for (final object in generatedProposalSchemaObjects.entries) {
      final rows = await db
          .rawQuery('SELECT sql FROM sqlite_master WHERE name=?', [object.key]);
      if (rows.length != 1 ||
          rows.single['sql'] is! String ||
          _sql(rows.single['sql'] as String) != _sql(object.value)) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    final owned = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' OR (type='index' AND sql IS NOT NULL)");
    for (final table in generatedProposalTables) {
      final objects = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE tbl_name=? AND (type='trigger' OR (type='index' AND sql IS NOT NULL))",
          [table]);
      if (objects
          .any((o) => !generatedProposalSchemaObjects.containsKey(o['name']))) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    if (!owned.any((o) => o['name'] == 'idx_generated_pending_owner')) {
      generatedFail(GeneratedFailure.corruptState);
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check'))
        .any((row) => generatedProposalTables.contains(row['table']))) {
      generatedFail(GeneratedFailure.corruptState);
    }
  } catch (_) {
    generatedFail(GeneratedFailure.corruptState);
  }
}
