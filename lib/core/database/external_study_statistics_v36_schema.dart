import '../../application/external/external_authorization.dart';
import 'sqflite_runtime.dart';

const externalStudyStatisticsSchemaVersion = 36;
const externalGrantEgressV36Ddl = '''CREATE TABLE external_grant_egress (
  profile_id TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('questionContent','fileContent','proposalMetadata','studyStatistics')),
  PRIMARY KEY(profile_id,category),
  FOREIGN KEY(profile_id) REFERENCES external_grants(profile_id)
);''';

// The old constraint is a migration input, not a current authorization policy.
const externalGrantEgressV35Ddl = '''CREATE TABLE external_grant_egress (
  profile_id TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('questionContent','fileContent','proposalMetadata')),
  PRIMARY KEY(profile_id,category),
  FOREIGN KEY(profile_id) REFERENCES external_grants(profile_id)
);''';

String _normalize(String sql) => sql
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r';\s*$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([(),=;])\s*'), (m) => m[1]!)
    .trim();

/// Called inside the owning database-open transaction. No grant is inserted.
Future<void> migrateExternalStudyStatisticsToV36(DatabaseExecutor db) async {
  final tables = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='external_grant_egress'");
  if (tables.length != 1 || tables.single['sql'] is! String) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
  final sql = _normalize(tables.single['sql'] as String);
  final legacy = sql == _normalize(externalGrantEgressV35Ddl);
  if (!legacy && sql != _normalize(externalGrantEgressV36Ddl)) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
  final extras = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE tbl_name='external_grant_egress' AND (type='trigger' OR (type='index' AND sql IS NOT NULL))");
  final invalid = await db.rawQuery(
      "SELECT 1 FROM external_grant_egress WHERE category NOT IN ('questionContent','fileContent','proposalMetadata') LIMIT 1");
  if (extras.isNotEmpty || invalid.isNotEmpty) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
  // Earlier migrations and empty reset-version fixtures may already have the
  // current DDL. They still cannot smuggle an enabled statistics category.
  if (!legacy) return;
  await db.execute(
      'ALTER TABLE external_grant_egress RENAME TO external_grant_egress_legacy_v35');
  await db.execute(externalGrantEgressV36Ddl);
  await db.execute('''INSERT INTO external_grant_egress(profile_id,category)
      SELECT profile_id,category FROM external_grant_egress_legacy_v35''');
  await db.execute('DROP TABLE external_grant_egress_legacy_v35');
}
