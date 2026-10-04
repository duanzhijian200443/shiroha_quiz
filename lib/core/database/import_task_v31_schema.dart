import 'sqflite_runtime.dart';

const importTaskSchemaVersion = 31;
const importTaskEventColumns = ['attempt_started_at', 'parsed_at', 'failed_at'];

/// Additive only. Historical event times remain unknown, including legacy
/// pending-review/error rows that already have completed_at.
Future<void> migrateImportTaskToV31(DatabaseExecutor db) async {
  final columns = await db.rawQuery('PRAGMA table_info(import_tasks)');
  if (columns.isEmpty) throw const ImportTaskSchemaException();
  final names = columns.map((row) => row['name']).toSet();
  for (final name in importTaskEventColumns) {
    if (!names.contains(name)) {
      await db.execute('ALTER TABLE import_tasks ADD COLUMN $name INTEGER');
    }
  }
  await validateImportTaskV31Schema(db);
}

Future<void> validateImportTaskV31Schema(DatabaseExecutor db) async {
  final rows = await db.rawQuery('PRAGMA table_info(import_tasks)');
  const types = {
    'id': 'TEXT',
    'title': 'TEXT',
    'status': 'INTEGER',
    'progress_text': 'TEXT',
    'percent': 'REAL',
    'error_msg': 'TEXT',
    'parsed_data': 'TEXT',
    'bank_name': 'TEXT',
    'folder_name': 'TEXT',
    'created_at': 'INTEGER',
    'completed_at': 'INTEGER',
    'source_type': 'TEXT',
    'pending_chunks': 'TEXT',
    'failed_chunks': 'TEXT',
    'warnings': 'TEXT',
    'diagnostics': 'TEXT',
    'attempt_started_at': 'INTEGER',
    'parsed_at': 'INTEGER',
    'failed_at': 'INTEGER',
  };
  final columns = {for (final row in rows) row['name']: row};
  for (final entry in types.entries) {
    final row = columns[entry.key];
    if (row == null ||
        (row['type'] as String).toUpperCase() != entry.value ||
        (entry.key == 'id' && row['pk'] != 1) ||
        (importTaskEventColumns.contains(entry.key) &&
            (row['notnull'] != 0 || row['dflt_value'] != null))) {
      throw const ImportTaskSchemaException();
    }
  }
}

final class ImportTaskSchemaException implements Exception {
  const ImportTaskSchemaException();
  @override
  String toString() => 'ImportTaskSchemaException';
}
