import 'sqflite_runtime.dart';

const int contentAssetReclamationSchemaVersion = 27;
const String contentAssetReclamationTable =
    'content_asset_reclamation_observations';

const String contentAssetReclamationTableDdl = '''
CREATE TABLE content_asset_reclamation_observations (
  source_id TEXT NOT NULL CHECK(length(source_id) BETWEEN 1 AND 128),
  local_asset_id TEXT NOT NULL CHECK(length(local_asset_id) BETWEEN 1 AND 128),
  first_unreachable_at INTEGER NOT NULL CHECK(first_unreachable_at >= 0),
  last_verified_unreachable_at INTEGER NOT NULL
    CHECK(last_verified_unreachable_at >= first_unreachable_at),
  PRIMARY KEY(source_id, local_asset_id)
);
''';

Future<void> createContentAssetReclamationV27Schema(
  DatabaseExecutor db,
) async {
  await db.execute(contentAssetReclamationTableDdl.replaceFirst(
    'CREATE TABLE ',
    'CREATE TABLE IF NOT EXISTS ',
  ));
}

Future<void> migrateContentAssetReclamationToV27(
  DatabaseExecutor db,
) async {
  await createContentAssetReclamationV27Schema(db);
  await validateContentAssetReclamationV27Schema(db);
  // This state was never authoritative. A database with a lowered
  // user_version must restart grace rather than trust pre-migration rows.
  await db.delete(contentAssetReclamationTable);
}

Future<void> validateContentAssetReclamationV27Schema(
  DatabaseExecutor db,
) async {
  final rows = await db.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '$contentAssetReclamationTable'",
  );
  if (rows.length != 1 ||
      _canonicalizeSql(rows.single['sql'] as String? ?? '') !=
          _canonicalizeSql(contentAssetReclamationTableDdl)) {
    throw const ContentAssetReclamationSchemaException();
  }
  final columns = await db.rawQuery(
    'PRAGMA table_info($contentAssetReclamationTable)',
  );
  const expected = <(String, String, int, int)>[
    ('source_id', 'TEXT', 1, 1),
    ('local_asset_id', 'TEXT', 1, 2),
    ('first_unreachable_at', 'INTEGER', 1, 0),
    ('last_verified_unreachable_at', 'INTEGER', 1, 0),
  ];
  if (columns.length != expected.length) {
    throw const ContentAssetReclamationSchemaException();
  }
  for (var index = 0; index < expected.length; index++) {
    final column = columns[index];
    final (name, type, notNull, primaryKey) = expected[index];
    if (column['name'] != name ||
        column['type'] != type ||
        column['notnull'] != notNull ||
        column['pk'] != primaryKey) {
      throw const ContentAssetReclamationSchemaException();
    }
  }
  if ((await db.rawQuery(
    'PRAGMA foreign_key_list($contentAssetReclamationTable)',
  ))
      .isNotEmpty) {
    throw const ContentAssetReclamationSchemaException();
  }
}

String _canonicalizeSql(String sql) => sql
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),=])\s*'), r'$1')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim()
    .toLowerCase();

final class ContentAssetReclamationSchemaException implements Exception {
  const ContentAssetReclamationSchemaException();

  @override
  String toString() => 'ContentAssetReclamationSchemaException';
}
