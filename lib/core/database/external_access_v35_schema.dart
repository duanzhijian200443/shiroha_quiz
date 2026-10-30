import '../../application/external/external_authorization.dart';
import 'sqflite_runtime.dart';

// Current database version; the public name is retained for existing callers.
const externalAccessSchemaVersion = 36;
const externalAccessPreferencesTable = 'external_access_preferences';
const externalAccessPreferencesDdl =
    '''CREATE TABLE external_access_preferences (
  profile_id TEXT PRIMARY KEY NOT NULL,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 2147483647),
  all_content INTEGER NOT NULL CHECK(typeof(all_content)='integer' AND all_content IN (0,1)),
  generation_mode TEXT NOT NULL CHECK(generation_mode IN ('confirm','review','direct')),
  FOREIGN KEY(profile_id,revision) REFERENCES external_client_profiles(profile_id,grant_revision) ON UPDATE CASCADE
);''';

Future<void> createExternalAccessV35Schema(DatabaseExecutor db) async {
  await db.execute(externalAccessPreferencesDdl);
}

Future<void> migrateExternalAccessToV35(DatabaseExecutor db) async {
  final existing = await db.rawQuery(
      'SELECT name FROM sqlite_master WHERE name=?',
      [externalAccessPreferencesTable]);
  if (existing.isEmpty) {
    await createExternalAccessV35Schema(db);
  } else {
    // Retain the repository's empty reset-version test compatibility only.
    await validateExternalAccessV35Schema(db);
    if ((await db.query(externalAccessPreferencesTable, limit: 1)).isNotEmpty) {
      externalAuthFail(ExternalAuthFailure.corruptState);
    }
  }
}

Future<void> validateExternalAccessV35Schema(DatabaseExecutor db) async {
  String normalize(String value) => value
      .replaceAll(RegExp(r';\s*$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s*([(),=;])\s*'), (m) => m[1]!)
      .trim();
  final rows = await db.rawQuery('SELECT sql FROM sqlite_master WHERE name=?',
      [externalAccessPreferencesTable]);
  if (rows.length != 1 ||
      rows.single['sql'] is! String ||
      normalize(rows.single['sql'] as String) !=
          normalize(externalAccessPreferencesDdl)) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
  final extras = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE tbl_name=? AND (type='trigger' OR (type='index' AND sql IS NOT NULL))",
      [externalAccessPreferencesTable]);
  if (extras.isNotEmpty) externalAuthFail(ExternalAuthFailure.corruptState);
  final invalid = await db.rawQuery('''
    SELECT p.profile_id FROM external_access_preferences p
    LEFT JOIN external_grants g ON p.profile_id=g.profile_id
    WHERE g.profile_id IS NULL OR p.revision!=g.revision
      OR typeof(p.all_content)!='integer' OR p.all_content NOT IN (0,1)
      OR p.generation_mode NOT IN ('confirm','review','direct')
      OR (p.generation_mode!='confirm' AND g.allow_stage!=1)
      OR (p.all_content=1 AND EXISTS (
        SELECT 1 FROM external_grant_scopes s WHERE s.profile_id=p.profile_id))
    LIMIT 1
  ''');
  if (invalid.isNotEmpty) externalAuthFail(ExternalAuthFailure.corruptState);
}
