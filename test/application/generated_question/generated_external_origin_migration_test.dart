import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_v32_schema.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'external_origin_test_support.dart';

final class _InsertFailure implements DatabaseExecutor {
  _InsertFailure(this.base);
  final DatabaseExecutor base;
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    if (sql.startsWith('INSERT INTO generated_question_proposals (')) {
      throw StateError('injected_migration_failure');
    }
    return base.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      base.rawQuery(sql, arguments);
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
      base.query(table,
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  Future<Map<String, List<Map<String, Object?>>>> rows() async => {
        for (final table in generatedProposalTables)
          table: await h.db.query(table,
              orderBy: table.contains('items') ||
                      table == 'generated_question_review_state'
                  ? 'proposal_id,item_id'
                  : 'proposal_id')
      };
  Future<List<GeneratedQuestionProposal>> seedLegacy() async {
    final pending = await h
        .stage(key: 'pending', items: [candidate(stem: 'Pending legacy')]);
    final rejected = await h.decide(
        await h.stage(
            key: 'rejected', items: [candidate(stem: 'Rejected legacy')]),
        accepted: false);
    final terminal = await h.service.reject(
        RejectGeneratedProposalCommand.fromJson({
          'proposalId': rejected.proposalId,
          'expectedReviewRevision': rejected.reviewRevision
        }),
        h.local);
    var committed = await h.decide(await h
        .stage(key: 'committed', items: [candidate(stem: 'Committed legacy')]));
    await h.service.approve(h.approval(committed), h.local);
    committed = await h.repository.read(committed.proposalId, h.local);
    await installLegacyGeneratedHeaderFixture(h.db);
    return [pending, terminal, committed];
  }

  for (final version in [32, 33]) {
    test(
        'real v$version -> v34 preserves all lifecycle data, child FKs/indexes/triggers and v33 auth',
        () async {
      final proposals = await seedLegacy();
      if (version == 32) {
        for (final table in externalAuthorizationTables.reversed) {
          await h.db.execute('DROP TABLE $table');
        }
      } else {
        final repo =
            SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
        await repo.create(
            ExternalClientProfile(
                clientProfileId: externalFixtureProfile,
                displayName: 'Synthetic',
                adapter: 'bridge',
                protocol: 'tcp-v1',
                createdAtUtcMs: 0,
                grantRevision: 0),
            () {});
      }
      await h.db.setVersion(version);
      expect(await h.db.getVersion(), version);
      await validateGeneratedProposalV32Schema(h.db);
      final before = await rows();
      final questions = await h.db.query('questions');
      final sidecars = await h.db.query('question_v2_payloads');
      final oldSchema = await h.db.rawQuery(
          "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name");
      await h.reopen();
      expect(await h.db.getVersion(), 34);
      final after = await rows();
      for (final row in after['generated_question_proposals']!) {
        expect(row['external_origin_json'], isNull);
      }
      final stripped = {
        for (final entry in after.entries)
          entry.key: [
            for (final row in entry.value)
              {...row}..remove('external_origin_json')
          ]
      };
      expect(stripped, before);
      expect(await h.db.query('questions'), questions);
      expect(await h.db.query('question_v2_payloads'), sidecars);
      final newSchema = await h.db.rawQuery(
          "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name");
      for (final row in oldSchema.where((r) => ![
            'generated_question_proposals',
            'gq_original_header_immutable'
          ].contains(r['name']))) {
        expect(newSchema.where((r) => r['name'] == row['name']).single, row);
      }
      for (final p in proposals) {
        expect((await h.repository.read(p.proposalId, h.local)).toJson(),
            p.toJson());
      }
      expect(await h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(
          (await h.db.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
      expect(
          (await h.db.rawQuery('PRAGMA defer_foreign_keys'))
              .single
              .values
              .single,
          0);
      expect(
          await h.db.rawQuery(
              "SELECT name FROM sqlite_master WHERE name='generated_question_origin_v34_source'"),
          isEmpty);
      await validateGeneratedProposalSchema(h.db);
      await validateGeneratedProposalData(h.db);
      await validateExternalAuthorizationSchema(h.db);
      await validateExternalAuthorizationData(h.db);
      if (version == 33) {
        expect(
            (await h.db.query('external_client_profiles')).single['profile_id'],
            externalFixtureProfile);
      }
    });
  }
  test(
      'injected reinsertion failure after DROP/CREATE rolls back every DDL/row/guard and version',
      () async {
    await seedLegacy();
    await h.db.setVersion(33);
    final before = await rows();
    final schema =
        await h.db.rawQuery('SELECT name,sql FROM sqlite_master ORDER BY name');
    await expectLater(
        h.db.transaction(
            (txn) => migrateGeneratedProposalOriginToV34(_InsertFailure(txn))),
        throwsA(isA<StateError>()));
    expect(await h.db.getVersion(), 33);
    expect(await rows(), before);
    expect(
        await h.db.rawQuery('SELECT name,sql FROM sqlite_master ORDER BY name'),
        schema);
    expect(await h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await validateGeneratedProposalV32Schema(h.db);
    await h.reopen();
    expect(await h.db.getVersion(), 34);
  });
  for (final defect in [
    'missing-trigger',
    'extra-column',
    'extra-table',
    'bad-origin'
  ]) {
    test('v33 $defect fails upgrade and preserves original version/data',
        () async {
      await seedLegacy();
      await h.db.setVersion(33);
      switch (defect) {
        case 'missing-trigger':
          await h.db.execute('DROP TRIGGER gq_original_header_immutable');
        case 'extra-column':
          await h.db.execute(
              'ALTER TABLE generated_question_proposals ADD COLUMN unknown TEXT');
        case 'extra-table':
          await h.db
              .execute('CREATE TABLE generated_question_unowned (x TEXT)');
        case 'bad-origin':
          await h.db.execute('DROP TRIGGER gq_original_header_immutable');
          await h.db.execute('PRAGMA ignore_check_constraints=ON');
          await h.db.update(
              'generated_question_proposals', {'origin_kind': 'external'},
              where: "lifecycle_status='pending_review'");
          await h.db.execute('PRAGMA ignore_check_constraints=OFF');
          await h.db.execute(generatedProposalV32SchemaObjects[
              'gq_original_header_immutable']!);
      }
      final before = await rows();
      final oldSchema = await h.db
          .rawQuery('SELECT name,sql FROM sqlite_master ORDER BY name');
      final path = DatabaseHelper.openedDatabasePathForTesting!;
      await h.helper.close();
      await expectLater(
          h.helper.database, failure(GeneratedFailure.corruptState));
      final probe = await databaseFactory.openDatabase(path);
      try {
        expect(await probe.getVersion(), 33);
        expect(
            await probe.query('generated_question_proposals',
                orderBy: 'proposal_id'),
            before['generated_question_proposals']);
        expect(
            await probe
                .rawQuery('SELECT name,sql FROM sqlite_master ORDER BY name'),
            oldSchema);
      } finally {
        await probe.close();
      }
    });
  }
}
