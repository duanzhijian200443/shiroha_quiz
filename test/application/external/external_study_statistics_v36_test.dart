import 'package:flutter_test/flutter_test.dart';
// The SDK's global factory setter requires this internal interface. Test only.
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/external_access_v35_schema.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/core/database/external_study_statistics_v36_schema.dart';
import 'package:shiroha_quiz/core/database/question_v2_schema_exception.dart';
import 'external_authorization_data_test.dart' show authFailure;
import 'local_authorization_test_support.dart';

final class _FailAfterCopy implements DatabaseExecutor {
  _FailAfterCopy(this.db);
  final DatabaseExecutor db;
  final fault = StateError('Synthetic migration fault at DROP');
  bool reachedDrop = false;
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql == 'DROP TABLE external_grant_egress_legacy_v35') {
      reachedDrop = true;
      throw fault;
    }
    await db.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      db.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      db.rawQuery(sql, arguments);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailAfterUpgrade implements SqfliteDatabaseFactory {
  _FailAfterUpgrade(this.delegate, this.path, this.verifyUpgraded);
  final DatabaseFactory delegate;
  final String path;
  final Future<void> Function(Database) verifyUpgraded;
  final fault = StateError('Synthetic fault after real onUpgrade');
  int completedUpgrades = 0;

  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    expect(path, this.path);
    expect(options, isNotNull);
    final original = options!;
    expect(original.onUpgrade, isNotNull);
    return delegate.openDatabase(path,
        options: OpenDatabaseOptions(
          version: original.version,
          onConfigure: original.onConfigure,
          onCreate: original.onCreate,
          onUpgrade: (db, oldVersion, newVersion) async {
            expect(oldVersion, 35);
            expect(newVersion, 36);
            await original.onUpgrade!(db, oldVersion, newVersion);
            await verifyUpgraded(db);
            completedUpgrades++;
            throw fault;
          },
          onDowngrade: original.onDowngrade,
          onOpen: original.onOpen,
          readOnly: original.readOnly,
          singleInstance: original.singleInstance,
        ));
  }

  // The delegate owns all database handles; unexpected factory calls fail.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _authorizationTables = [
  ...externalAuthorizationTables,
  externalAccessPreferencesTable,
];

Future<Map<String, List<Map<String, Object?>>>> _authorizationRows(
        DatabaseExecutor db) async =>
    {
      for (final table in _authorizationTables)
        table: await db.query(table,
            orderBy: switch (table) {
              'external_grant_scopes' =>
                'profile_id,project_id,target_kind,target_id',
              'external_grant_egress' => 'profile_id,category',
              _ => 'profile_id',
            }),
    };

Future<Map<String, Object?>> _migrationSnapshot(DatabaseExecutor db) async => {
      'schema': await db.rawQuery(
          'SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name'),
      'rows': await _authorizationRows(db),
      'foreignKeys': {
        for (final table in _authorizationTables)
          table: await db.rawQuery('PRAGMA foreign_key_list($table)'),
      },
      'foreignKeyCheck': await db.rawQuery('PRAGMA foreign_key_check'),
      'userVersion': await db.rawQuery('PRAGMA user_version'),
    };

// Only called on the GeneratedHarness's disposable synthetic database.
Future<void> _legacyEgress(Database db,
    {String ddl = externalGrantEgressV35Ddl}) async {
  await db.transaction((txn) async {
    await txn.execute(
        'ALTER TABLE external_grant_egress RENAME TO external_grant_egress_current');
    await txn.execute(ddl);
    await txn.execute('''INSERT INTO external_grant_egress(profile_id,category)
        SELECT profile_id,category FROM external_grant_egress_current''');
    await txn.execute('DROP TABLE external_grant_egress_current');
  });
  await db.setVersion(35);
}

Future<void> _expectReadOnlySnapshot(
    String path, Map<String, Object?> before) async {
  final probe = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    expect(await probe.getVersion(), 35);
    expect(await _migrationSnapshot(probe), before);
  } finally {
    await probe.close();
  }
}

void main() {
  initializeGeneratedTests();
  late LocalAuthorizationHarness f;
  setUp(() async {
    f = LocalAuthorizationHarness();
    await f.open();
  });
  tearDown(() async => f.close());

  Future<ExternalProfileReference> seedAuthorization() async {
    final view = f.service.openView();
    try {
      final ref = await view.create('Legacy all content');
      await view.saveAllContent(ref, 0, directWrite: false);
      final scoped = await view.create('Legacy exact scope');
      await view.save(scoped, 0,
          permissions: [CapabilityPermission.read, CapabilityPermission.stage],
          targets: await view.targets(),
          categories: [
            ExternalContentCategory.questionContent,
            ExternalContentCategory.fileContent,
            ExternalContentCategory.proposalMetadata,
          ]);
      for (final rows in (await _authorizationRows(f.h.db)).values) {
        expect(rows, isNotEmpty);
      }
      return ref;
    } finally {
      view.close();
    }
  }

  test('v35 migration preserves grants/preferences across repeated open',
      () async {
    final ref = await seedAuthorization();
    final before = await _authorizationRows(f.h.db);
    await _legacyEgress(f.h.db);
    await validateExternalAuthorizationV35Schema(f.h.db);
    await validateExternalAuthorizationData(f.h.db);
    Map<String, Object?>? migrated;
    for (var attempt = 0; attempt < 2; attempt++) {
      await f.h.reopen();
      f.compose();
      expect(await f.h.db.getVersion(), 36);
      expect(await _authorizationRows(f.h.db), before);
      await validateExternalAuthorizationSchema(f.h.db);
      final record = await f.repository.read(ref.profileId);
      expect(record.grant!.policy.categories,
          isNot(contains(ExternalContentCategory.studyStatistics)));
      expect(record.grant!.policy.allContent, isTrue);
      expect(
          record.grant!.policy.generationMode, ExternalGenerationMode.review);
      expect(await f.h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      final snapshot = await _migrationSnapshot(f.h.db);
      if (migrated != null) expect(snapshot, migrated);
      migrated = snapshot;
    }
  });

  test(
      'statistics consent uses revision CAS and survives unrelated policy edit',
      () async {
    final view = f.service.openView();
    final ref = await view.create('Statistics');
    await view.saveAllContent(ref, 0, directWrite: false);
    final allowed = await view.saveStudyStatistics(ref, 1, allowed: true);
    expect(allowed.profile.grantRevision, 2);
    expect(allowed.grant!.policy.categories,
        contains(ExternalContentCategory.studyStatistics));
    await expectLater(view.saveStudyStatistics(ref, 1, allowed: false),
        authFailure(ExternalAuthFailure.staleRevision));
    final edited = await view.saveAllContent(ref, 2, directWrite: true);
    expect(edited.grant!.policy.categories,
        contains(ExternalContentCategory.studyStatistics));
    final denied = await view.saveStudyStatistics(ref, 3, allowed: false);
    expect(denied.profile.grantRevision, 4);
    expect(denied.grant!.policy.categories,
        isNot(contains(ExternalContentCategory.studyStatistics)));
    view.close();
  });

  test(
      'migration failure at DROP rolls back DDL and rows with original version',
      () async {
    await seedAuthorization();
    await _legacyEgress(f.h.db);
    final before = await _migrationSnapshot(f.h.db);
    late _FailAfterCopy failing;
    await expectLater(f.h.db.transaction((txn) {
      failing = _FailAfterCopy(txn);
      return migrateExternalStudyStatisticsToV36(failing);
    }), throwsA(isA<StateError>()));
    expect(failing.reachedDrop, isTrue);
    expect(await f.h.db.getVersion(), 35);
    expect(await _migrationSnapshot(f.h.db), before);
  });

  test('real DatabaseHelper open rolls back after completed v36 onUpgrade',
      () async {
    final ref = await seedAuthorization();
    await _legacyEgress(f.h.db);
    final before = await _migrationSnapshot(f.h.db);
    final path = f.h.db.path;
    await f.h.helper.close();
    final originalFactory = databaseFactory;
    final failing = _FailAfterUpgrade(originalFactory, path, (db) async {
      expect(await db.getVersion(), 35);
      expect(await db.rawQuery('PRAGMA foreign_keys'), [
        {'foreign_keys': 1},
      ]);
      await validateExternalAuthorizationSchema(db);
      await validateExternalAccessV35Schema(db);
      expect(await _authorizationRows(db), before['rows']);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
          await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE name LIKE 'external_grant_egress_%'"),
          isEmpty);
      // Probe the new CHECK, retained PK and FK in the SDK-owned transaction.
      await db.execute('SAVEPOINT v36_constraints_probe');
      try {
        final statistics = {
          'profile_id': ref.profileId,
          'category': 'studyStatistics',
        };
        await db.insert('external_grant_egress', statistics);
        expect(
            await db.query('external_grant_egress',
                where: 'profile_id=? AND category=?',
                whereArgs: [ref.profileId, 'studyStatistics']),
            [statistics]);
        for (final row in [
          statistics,
          {'profile_id': ref.profileId, 'category': 'unknown'},
          {'profile_id': 'missing', 'category': 'studyStatistics'},
        ]) {
          await expectLater(db.insert('external_grant_egress', row),
              throwsA(isA<DatabaseException>()));
        }
      } finally {
        await db.execute('ROLLBACK TO v36_constraints_probe');
        await db.execute('RELEASE v36_constraints_probe');
      }
      expect(await _authorizationRows(db), before['rows']);
    });
    try {
      databaseFactoryOrNull = failing;
      await expectLater(f.h.helper.database, throwsA(same(failing.fault)));
      expect(failing.completedUpgrades, 1);
    } finally {
      databaseFactoryOrNull = originalFactory;
      await f.h.helper.close();
    }
    expect(databaseFactory, same(originalFactory));
    await _expectReadOnlySnapshot(path, before);
  });

  for (final defect in [
    'egress extra index',
    'egress extra trigger',
    'scope extra index',
    'scope extra trigger',
    'egress CHECK removed',
    'scope CHECK removed',
    'unknown category',
    'statistics under legacy DDL',
    'statistics under current DDL labeled v35',
    'orphan egress',
    'all-content with exact scope',
    'grant timestamp before profile creation',
  ]) {
    test('v35 migration rejects $defect without changing the input', () async {
      final ref = await seedAuthorization();
      await _legacyEgress(f.h.db,
          ddl: switch (defect) {
            'egress CHECK removed' => externalGrantEgressV35Ddl.replaceFirst(
                " CHECK(category IN ('questionContent','fileContent','proposalMetadata'))",
                ''),
            'statistics under current DDL labeled v35' =>
              externalGrantEgressV36Ddl,
            _ => externalGrantEgressV35Ddl,
          });
      switch (defect) {
        case 'egress extra index':
          await f.h.db.execute(
              'CREATE INDEX synthetic_egress_index ON external_grant_egress(category)');
        case 'egress extra trigger':
          await f.h.db.execute('''CREATE TRIGGER synthetic_egress_trigger
              AFTER INSERT ON external_grant_egress BEGIN SELECT 1; END''');
        case 'scope extra index':
          await f.h.db.execute(
              'CREATE INDEX synthetic_scope_index ON external_grant_scopes(target_id)');
        case 'scope extra trigger':
          await f.h.db.execute('''CREATE TRIGGER synthetic_scope_trigger
              AFTER INSERT ON external_grant_scopes BEGIN SELECT 1; END''');
        case 'egress CHECK removed':
          break;
        case 'scope CHECK removed':
          final rows = await f.h.db.query('external_grant_scopes');
          await f.h.db.transaction((txn) async {
            await txn.execute('DROP TABLE external_grant_scopes');
            await txn.execute(
                externalAuthorizationSchemaObjects['external_grant_scopes']!
                    .replaceFirst(
                        ' CHECK(length(target_id) BETWEEN 1 AND 256)', ''));
            for (final row in rows) {
              await txn.insert('external_grant_scopes', row);
            }
          });
        case 'unknown category':
        case 'statistics under legacy DDL':
          await f.h.db.execute('PRAGMA ignore_check_constraints=ON');
          try {
            await f.h.db.insert('external_grant_egress', {
              'profile_id': ref.profileId,
              'category':
                  defect == 'unknown category' ? 'unknown' : 'studyStatistics',
            });
          } finally {
            await f.h.db.execute('PRAGMA ignore_check_constraints=OFF');
          }
        case 'statistics under current DDL labeled v35':
          await f.h.db.insert('external_grant_egress', {
            'profile_id': ref.profileId,
            'category': 'studyStatistics',
          });
        case 'orphan egress':
          await f.h.db.execute('PRAGMA foreign_keys=OFF');
          try {
            await f.h.db.insert('external_grant_egress', {
              'profile_id': '00000000-0000-4000-8000-000000000000',
              'category': 'questionContent',
            });
          } finally {
            await f.h.db.execute('PRAGMA foreign_keys=ON');
          }
          expect(
              await f.h.db.rawQuery('PRAGMA foreign_key_check'), hasLength(1));
        case 'all-content with exact scope':
          await f.h.db.insert('external_grant_scopes', {
            'profile_id': ref.profileId,
            'project_id': '',
            'target_kind': 'bank',
            'target_id': 'bank',
          });
        case 'grant timestamp before profile creation':
          await f.h.db.update('external_grants', {'updated_at': 0},
              where: 'profile_id=?', whereArgs: [ref.profileId]);
      }
      final before = await _migrationSnapshot(f.h.db);
      // Test the migration itself as well as the real open: later onUpgrade
      // validation must not mask missing validation before the rebuild.
      await expectLater(f.h.db.transaction(migrateExternalStudyStatisticsToV36),
          authFailure(ExternalAuthFailure.corruptState));
      expect(await _migrationSnapshot(f.h.db), before);
      final path = f.h.db.path;
      await f.h.helper.close();
      // Real open runs the original global FK gate before the v36 migration.
      await expectLater(
          f.h.helper.database,
          defect == 'orphan egress'
              ? throwsA(isA<QuestionV2SchemaException>().having(
                  (e) => e.failure,
                  'fixed failure',
                  QuestionV2SchemaFailure.foreignKeyViolation))
              : authFailure(ExternalAuthFailure.corruptState));
      await _expectReadOnlySnapshot(path, before);
    });
  }
}
