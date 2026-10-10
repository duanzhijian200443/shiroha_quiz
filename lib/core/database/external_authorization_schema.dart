import '../../application/capabilities/capability.dart';
import '../../application/external/external_authorization.dart';
import 'sqflite_runtime.dart';

const externalAuthorizationSchemaVersion = 33;
const externalAuthorizationTables = [
  'external_client_profiles',
  'external_grants',
  'external_grant_scopes',
  'external_grant_egress'
];
const externalAuthorizationSchemaObjects = <String, String>{
  'external_client_profiles': '''CREATE TABLE external_client_profiles (
  profile_id TEXT PRIMARY KEY NOT NULL CHECK(length(profile_id)=36 AND profile_id NOT GLOB '*[^0-9a-f-]*'),
  display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
  adapter TEXT NOT NULL CHECK(length(adapter) BETWEEN 1 AND 32),
  protocol TEXT NOT NULL CHECK(length(protocol) BETWEEN 1 AND 32),
  created_at INTEGER NOT NULL CHECK(typeof(created_at)='integer' AND created_at BETWEEN 0 AND 9007199254740991),
  revoked_at INTEGER CHECK(revoked_at IS NULL OR (typeof(revoked_at)='integer' AND revoked_at BETWEEN created_at AND 9007199254740991)),
  grant_revision INTEGER NOT NULL CHECK(typeof(grant_revision)='integer' AND grant_revision BETWEEN 0 AND 2147483647),
  UNIQUE(profile_id,grant_revision)
);''',
  'external_grants': '''CREATE TABLE external_grants (
  profile_id TEXT PRIMARY KEY NOT NULL,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 2147483647),
  allow_read INTEGER NOT NULL CHECK(typeof(allow_read)='integer' AND allow_read IN (0,1)),
  allow_stage INTEGER NOT NULL CHECK(typeof(allow_stage)='integer' AND allow_stage IN (0,1)),
  updated_at INTEGER NOT NULL CHECK(typeof(updated_at)='integer' AND updated_at BETWEEN 0 AND 9007199254740991),
  revoked_at INTEGER CHECK(revoked_at IS NULL OR (typeof(revoked_at)='integer' AND revoked_at=updated_at)),
  CHECK(allow_read=1 OR allow_stage=1),
  FOREIGN KEY(profile_id,revision) REFERENCES external_client_profiles(profile_id,grant_revision) ON UPDATE CASCADE
);''',
  'external_grant_scopes': '''CREATE TABLE external_grant_scopes (
  profile_id TEXT NOT NULL,
  project_id TEXT NOT NULL CHECK(length(project_id)<=128),
  target_kind TEXT NOT NULL CHECK(target_kind IN ('bank','file')),
  target_id TEXT NOT NULL CHECK(length(target_id) BETWEEN 1 AND 256),
  PRIMARY KEY(profile_id,project_id,target_kind,target_id),
  FOREIGN KEY(profile_id) REFERENCES external_grants(profile_id)
);''',
  'external_grant_egress': '''CREATE TABLE external_grant_egress (
  profile_id TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('questionContent','fileContent','proposalMetadata')),
  PRIMARY KEY(profile_id,category),
  FOREIGN KEY(profile_id) REFERENCES external_grants(profile_id)
);''',
  'external_profile_identity_immutable':
      "CREATE TRIGGER external_profile_identity_immutable BEFORE UPDATE OF profile_id,display_name,adapter,protocol,created_at ON external_client_profiles BEGIN SELECT RAISE(ABORT,'external_identity_immutable'); END;",
  'external_profile_revision_guard':
      "CREATE TRIGGER external_profile_revision_guard BEFORE UPDATE ON external_client_profiles WHEN OLD.revoked_at IS NOT NULL OR NEW.grant_revision!=OLD.grant_revision+1 BEGIN SELECT RAISE(ABORT,'external_revision'); END;",
};

Future<void> createExternalAuthorizationSchema(DatabaseExecutor db,
    {bool ifNotExists = false}) async {
  for (final sql in externalAuthorizationSchemaObjects.values) {
    await db.execute(ifNotExists
        ? sql
            .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
            .replaceFirst('CREATE TRIGGER ', 'CREATE TRIGGER IF NOT EXISTS ')
        : sql);
  }
}

Future<void> migrateExternalAuthorizationSchema(DatabaseExecutor db) async {
  await createExternalAuthorizationSchema(db, ifNotExists: true);
  await validateExternalAuthorizationSchema(db);
  for (final table in externalAuthorizationTables) {
    if ((await db.query(table, limit: 1)).isNotEmpty) {
      externalAuthFail(ExternalAuthFailure.corruptState);
    }
  }
}

String _sql(String value) => value
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r';\s*$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([(),=;])\s*'), (m) => m[1]!)
    .trim();
Future<void> validateExternalAuthorizationSchema(DatabaseExecutor db) async {
  try {
    for (final entry in externalAuthorizationSchemaObjects.entries) {
      final rows = await db
          .rawQuery('SELECT sql FROM sqlite_master WHERE name=?', [entry.key]);
      if (rows.length != 1 ||
          rows.single['sql'] is! String ||
          _sql(rows.single['sql'] as String) != _sql(entry.value)) {
        externalAuthFail(ExternalAuthFailure.corruptState);
      }
    }
    for (final table in externalAuthorizationTables) {
      final objects = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE tbl_name=? AND (type='trigger' OR (type='index' AND sql IS NOT NULL))",
          [table]);
      if (objects.any(
          (o) => !externalAuthorizationSchemaObjects.containsKey(o['name']))) {
        externalAuthFail(ExternalAuthFailure.corruptState);
      }
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check'))
        .any((r) => externalAuthorizationTables.contains(r['table']))) {
      externalAuthFail(ExternalAuthFailure.corruptState);
    }
  } catch (_) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
}

Future<ExternalAuthorizationRecord> readExternalAuthorization(
    DatabaseExecutor db, String id) async {
  if (!ExternalAuthLimits.validId(id)) {
    externalAuthFail(ExternalAuthFailure.unauthorized);
  }
  final profiles = await db.query('external_client_profiles',
      where: 'profile_id=?', whereArgs: [id]);
  if (profiles.isEmpty) externalAuthFail(ExternalAuthFailure.unauthorized);
  try {
    final p = profiles.single;
    final profile = ExternalClientProfile(
        clientProfileId: p['profile_id'] as String,
        displayName: p['display_name'] as String,
        adapter: p['adapter'] as String,
        protocol: p['protocol'] as String,
        createdAtUtcMs: p['created_at'] as int,
        grantRevision: p['grant_revision'] as int,
        revokedAtUtcMs: p['revoked_at'] as int?);
    final grants = await db
        .query('external_grants', where: 'profile_id=?', whereArgs: [id]);
    if (grants.isEmpty) {
      if (profile.grantRevision != 0 &&
          !(profile.grantRevision == 1 && profile.revokedAtUtcMs != null)) {
        externalAuthFail(ExternalAuthFailure.corruptState);
      }
      return ExternalAuthorizationRecord(profile, null);
    }
    final g = grants.single;
    final scopes = await db.query('external_grant_scopes',
        where: 'profile_id=?',
        whereArgs: [id],
        orderBy: 'project_id,target_kind,target_id',
        limit: ExternalAuthLimits.maxScopes + 1);
    final egress = await db.query('external_grant_egress',
        where: 'profile_id=?', whereArgs: [id], limit: 4);
    if (g['revision'] != profile.grantRevision ||
        g['updated_at'] is! int ||
        (g['updated_at'] as int) < profile.createdAtUtcMs ||
        ![0, 1].contains(g['allow_read']) ||
        ![0, 1].contains(g['allow_stage']) ||
        g['revision'] is! int ||
        (g['revision'] as int) < 1 ||
        (g['revoked_at'] != null && g['revoked_at'] != g['updated_at']) ||
        (profile.revokedAtUtcMs != null &&
            g['revoked_at'] != profile.revokedAtUtcMs) ||
        egress.length > ExternalContentCategory.values.length) {
      externalAuthFail(ExternalAuthFailure.corruptState);
    }
    ExternalAuthLimits.time(g['updated_at'] as int);
    final policy = ExternalGrantPolicy(
        permissions: [
          if (g['allow_read'] == 1) CapabilityPermission.read,
          if (g['allow_stage'] == 1) CapabilityPermission.stage
        ],
        scopes: scopes.map((s) => ExternalGrantScope(
            kind: ExternalTargetKind.values.byName(s['target_kind'] as String),
            targetId: s['target_id'] as String,
            projectId:
                s['project_id'] == '' ? null : s['project_id'] as String)),
        categories: egress.map((e) =>
            ExternalContentCategory.values.byName(e['category'] as String)));
    return ExternalAuthorizationRecord(
        profile,
        ExternalGrant(
            profileId: id,
            revision: g['revision'] as int,
            updatedAtUtcMs: g['updated_at'] as int,
            revokedAtUtcMs: g['revoked_at'] as int?,
            policy: policy));
  } catch (_) {
    externalAuthFail(ExternalAuthFailure.corruptState);
  }
}

Future<void> validateExternalAuthorizationData(DatabaseExecutor db) async {
  final profiles =
      await db.query('external_client_profiles', columns: ['profile_id']);
  for (final profile in profiles) {
    await readExternalAuthorization(db, profile['profile_id'] as String);
  }
}
