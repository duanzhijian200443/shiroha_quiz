import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'generated_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
      'fresh current schema is exactly v33 with package2 and strict shared schema/data validators',
      () async {
    expect(DatabaseHelper.databaseVersion, 33);
    expect(await h.db.getVersion(), 33);
    expect(BackupValues.currentSchemaVersion, 33);
    expect(BackupValues.currentPackageVersion, 2);
    await validateGeneratedProposalSchema(h.db);
    await validateGeneratedProposalData(h.db);
    await DatabaseHelper.validateStagedBackupSchema(h.db);
    expect(await h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await h.reopen();
    await validateGeneratedProposalSchema(h.db);
  });
  test(
      'real accepted v31 -> v33 upgrade retains old rows and old schema objects',
      () async {
    final path = DatabaseHelper.openedDatabasePathForTesting;
    final before = await h.db.query('bank_folders');
    for (final table in generatedProposalTables.reversed) {
      await h.db.execute('DROP TABLE $table');
    }
    final schema = await h.db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name");
    await h.db.setVersion(31);
    await h.helper.close();
    final probe = await databaseFactory.openDatabase(path!);
    expect(await probe.getVersion(), 31);
    await probe.close();
    h.db = await h.helper.database;
    expect(await h.db.getVersion(), 33);
    expect(await h.db.query('bank_folders'), before);
    final after = await h.db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name");
    for (final row in schema) {
      expect(after.where((a) => a['name'] == row['name']).single, row);
    }
    await validateGeneratedProposalSchema(h.db);
    await validateGeneratedProposalData(h.db);
  });
  test(
      'published originals/terminal rows and relational identity have database guards',
      () async {
    var p = await h.stage();
    await expectLater(
        h.db.update(
            'generated_question_proposal_items', {'original_json': '{}'},
            where: 'proposal_id=?', whereArgs: [p.proposalId]),
        throwsA(isA<DatabaseException>()));
    final item = (await h.db.query('generated_question_proposal_items')).single;
    await expectLater(h.db.insert('generated_question_proposal_items', item),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        h.db.insert('generated_question_review_state', {
          'proposal_id': 'missing',
          'item_id': p.items.single.itemId,
          'working_json': '{}',
          'decision': 'unreviewed'
        }),
        throwsA(isA<DatabaseException>()));
    p = await h.decide(p);
    await h.service.approve(h.approval(p), h.local);
    await expectLater(
        h.db.update('generated_question_review_state', {'decision': 'rejected'},
            where: 'proposal_id=?', whereArgs: [p.proposalId]),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        h.db.update('generated_question_proposals',
            {'lifecycle_status': 'pending_review', 'terminal_revision': null},
            where: 'proposal_id=?', whereArgs: [p.proposalId]),
        throwsA(isA<DatabaseException>()));
  });
  for (final change in ['column', 'index', 'trigger']) {
    test('strict schema rejects changed $change while runtime is absent',
        () async {
      switch (change) {
        case 'column':
          await h.db.execute(
              'ALTER TABLE generated_question_proposals ADD COLUMN unknown TEXT');
        case 'index':
          await h.db.execute('DROP INDEX idx_generated_pending_owner');
        case 'trigger':
          await h.db.execute('DROP TRIGGER gq_original_header_immutable');
      }
      await expectLater(validateGeneratedProposalSchema(h.db),
          failure(GeneratedFailure.corruptState));
      await expectLater(DatabaseHelper.validateStagedBackupSchema(h.db),
          failure(GeneratedFailure.corruptState));
    });
  }
  test(
      'corrupt persisted working copy fails read and normal reopen, no legacy fallback',
      () async {
    final p = await h.stage();
    await h.db.update('generated_question_review_state',
        {'working_json': '{"unexpected":true}'},
        where: 'proposal_id=?', whereArgs: [p.proposalId]);
    await expectLater(h.repository.read(p.proposalId, h.local),
        failure(GeneratedFailure.corruptState));
    await h.helper.close();
    await expectLater(
        h.helper.database, failure(GeneratedFailure.corruptState));
  });
  test(
      'durable codecs reject noninteger versions/counts and unknown enum without raw exception text',
      () async {
    final p = await h.stage();
    for (final field in ['schemaVersion', 'actualCount']) {
      final json = p.toJson();
      json[field] = 1.0;
      expect(() => GeneratedQuestionProposal.fromJson(json),
          throwsA(isA<GeneratedQuestionException>()),
          reason: field);
    }
    final json = p.toJson();
    json['lifecycleStatus'] = 'synthetic_private_payload';
    expect(() => GeneratedQuestionProposal.fromJson(json),
        throwsA(isA<GeneratedQuestionException>()));
    final good = await h.decide(p);
    final receipt = await h.service.approve(h.approval(good), h.local);
    final bad = receipt.toJson();
    bad['schemaVersion'] = 1.0;
    expect(() => GeneratedReceipt.fromJson(bad),
        throwsA(isA<GeneratedQuestionException>()));
  });
  test(
      'durable codec exact-key roundtrip preserves all original/working/receipt identities',
      () async {
    final p = await h.stage();
    final encoded = p.toJson();
    expect(
        GeneratedQuestionProposal.fromJson(jsonDecode(jsonEncode(encoded)))
            .toJson(),
        encoded);
    encoded['unknown'] = true;
    expect(() => GeneratedQuestionProposal.fromJson(encoded),
        throwsA(isA<GeneratedQuestionException>()));
  });
  test(
      'original retained hashes and all 12 unrelated retained owners stay exact',
      () {
    final entries = jsonDecode(
        File('test/application/modules/fixtures/retained_source_contracts.json')
            .readAsStringSync()) as List;
    expect(entries, hasLength(14));
    expect(
        entries.singleWhere((e) =>
            e['path'] == 'lib/core/database/database_helper.dart')['sha256'],
        '24704ab5cc1e88eacf87b661cfa7661e518c7ca9f17e3e26f88d2f32c0adec4f');
    expect(
        entries.singleWhere((e) =>
            e['path'] ==
            'lib/data/repositories/backup_snapshot_repository.dart')['sha256'],
        '28a87652c6569fbadddc985a6a0267d30dffb08998ef59f8085071201742f2ae');
  });

  test('older-version migration accepts only exact empty additive objects',
      () async {
    await h.db.transaction((txn) => migrateGeneratedProposalSchema(txn));
    await h.stage();
    await expectLater(
        h.db.transaction((txn) => migrateGeneratedProposalSchema(txn)),
        failure(GeneratedFailure.corruptState));
    expect(await h.count('generated_question_proposals'), 1);
    await h.db.execute(
        'ALTER TABLE generated_question_proposals ADD COLUMN unexpected TEXT');
    await expectLater(
        h.db.transaction((txn) => migrateGeneratedProposalSchema(txn)),
        failure(GeneratedFailure.corruptState));
    expect(await h.count('generated_question_proposals'), 1);
  });
}
