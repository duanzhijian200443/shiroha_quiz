import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/core/database/external_study_statistics_v36_schema.dart';
import 'external_authorization_data_test.dart' show authFailure;
import 'local_authorization_test_support.dart';

final class _FailAfterCopy implements DatabaseExecutor {
  _FailAfterCopy(this.db);
  final DatabaseExecutor db;
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql == 'DROP TABLE external_grant_egress_legacy_v35') {
      throw StateError('Synthetic migration fault');
    }
    await db.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      db.rawQuery(sql, arguments);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _legacyEgress(Database db) async {
  await db.transaction((txn) async {
    await txn.execute(
        'ALTER TABLE external_grant_egress RENAME TO external_grant_egress_current');
    await txn.execute(externalGrantEgressV35Ddl);
    await txn.execute('''INSERT INTO external_grant_egress(profile_id,category)
        SELECT profile_id,category FROM external_grant_egress_current''');
    await txn.execute('DROP TABLE external_grant_egress_current');
  });
  await db.setVersion(35);
}

void main() {
  initializeGeneratedTests();
  late LocalAuthorizationHarness f;
  setUp(() async {
    f = LocalAuthorizationHarness();
    await f.open();
  });
  tearDown(() async => f.close());

  test('v35 migration preserves grants and defaults statistics off', () async {
    final view = f.service.openView();
    final ref = await view.create('Legacy');
    await view.saveAllContent(ref, 0, directWrite: false);
    final before = {
      for (final table in externalAuthorizationTables)
        table: await f.h.db.query(table),
    };
    await _legacyEgress(f.h.db);
    view.close();
    await f.h.reopen();
    f.compose();
    expect(await f.h.db.getVersion(), 36);
    for (final table in externalAuthorizationTables) {
      expect(await f.h.db.query(table), before[table]);
    }
    final record = await f.repository.read(ref.profileId);
    expect(record.grant!.policy.categories,
        isNot(contains(ExternalContentCategory.studyStatistics)));
    expect(await f.h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
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

  test('migration failure rolls back DDL and rows with original version',
      () async {
    final view = f.service.openView();
    final ref = await view.create('Rollback');
    await view.saveAllContent(ref, 0, directWrite: false);
    view.close();
    await _legacyEgress(f.h.db);
    final rows = await f.h.db.query('external_grant_egress');
    final schema = await f.h.db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE name LIKE 'external_%' ORDER BY name");
    await expectLater(
        f.h.db.transaction(
            (txn) => migrateExternalStudyStatisticsToV36(_FailAfterCopy(txn))),
        throwsA(isA<StateError>()));
    expect(await f.h.db.getVersion(), 35);
    expect(await f.h.db.query('external_grant_egress'), rows);
    expect(
        await f.h.db.rawQuery(
            "SELECT name,sql FROM sqlite_master WHERE name LIKE 'external_%' ORDER BY name"),
        schema);
  });
}
