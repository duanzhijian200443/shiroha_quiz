import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/ordinary_training_bank_policy.dart';
import 'package:shiroha_quiz/core/database/training_content_binding_lifecycle.dart';
import 'package:shiroha_quiz/core/database/training_content_v29_schema.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';

const _key = '["uncategorized"]';

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    await db.execute('PRAGMA foreign_keys = ON');
    await db.execute(
        'CREATE TABLE questions (id TEXT PRIMARY KEY, bank_name TEXT)');
    await db.execute(
        'CREATE TABLE bank_folders (bank_name TEXT PRIMARY KEY, folder_name TEXT)');
    await createTrainingContentV29Schema(db);
  });
  tearDown(() async => db.close());

  Future<void> seed(List<String> banks) async {
    await db.insert(trainingContentsTable, {
      'content_id': 'content',
      'category_key': _key,
      'name': 'Synthetic',
      'question_limit': 40,
      'sort_order': 0,
      'revision': 4
    });
    for (var i = 0; i < banks.length; i++) {
      await db.insert(trainingContentMembersTable, {
        'content_id': 'content',
        'bank_name': banks[i],
        'weight_percent': i == 0 ? 100 : 0,
        'position': i,
        'binding_status': 'valid'
      });
    }
  }

  test(
      'temporary delete then replace same bank is valid at final state, including repeated scan',
      () async {
    await seed(['Bank']);
    await db.insert('questions', {'id': 'old', 'bank_name': 'Bank'});
    await db.transaction((txn) async {
      await txn.delete('questions');
      await txn.insert('questions', {'id': 'replacement', 'bank_name': 'Bank'});
      await invalidateTrainingBindingsAtFinalState(txn,
          affectedBankNames: ['Bank']);
    });
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn,
        affectedBankNames: ['Bank']));
    expect(
        (await db.query(trainingContentMembersTable)).single['binding_status'],
        'valid');
    expect((await db.query(trainingContentsTable)).single['revision'], 4);
  });

  test(
      'missing, ineligible and Category drift use fixed reasons, once per content, never reweight',
      () async {
    await seed(['Missing', globalWrongBookBankName, 'Moved']);
    await db.insert(
        'questions', {'id': 'reserved', 'bank_name': globalWrongBookBankName});
    await db.insert('questions', {'id': 'moved', 'bank_name': 'Moved'});
    await db
        .insert('bank_folders', {'bank_name': 'Moved', 'folder_name': 'Math'});
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn));
    final members =
        await db.query(trainingContentMembersTable, orderBy: 'position');
    expect(members.map((row) => row['invalidation_reason']),
        ['bankMissing', 'bankIneligible', 'categoryChanged']);
    expect(members.map((row) => row['weight_percent']), [100, 0, 0]);
    expect((await db.query(trainingContentsTable)).single['revision'], 5);
    await db.insert('questions', {'id': 'recreated', 'bank_name': 'Missing'});
    await db.delete('bank_folders');
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn));
    expect(await db.query(trainingContentMembersTable, orderBy: 'position'),
        members);
    expect((await db.query(trainingContentsTable)).single['revision'], 5);
  });

  test(
      'affected-bank filtering uses exact case/Unicode identity and leaves other bindings alone',
      () async {
    await seed(['Bank', 'bank', ' 📁 Bank ']);
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn,
        affectedBankNames: ['bank', 'bank']));
    final rows =
        await db.query(trainingContentMembersTable, orderBy: 'position');
    expect(rows.map((row) => row['binding_status']),
        ['valid', 'invalidated', 'valid']);
    expect((await db.query(trainingContentsTable)).single['revision'], 5);
  });

  test(
      'unmapped bank remains Uncategorized and exact same folder movement is a no-op',
      () async {
    await seed(['Bank']);
    await db.insert('questions', {'id': 'q', 'bank_name': 'Bank'});
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn));
    expect((await db.query(trainingContentsTable)).single['revision'], 4);
    const codec = CategoryKeyCodec();
    await db.update(trainingContentsTable,
        {'category_key': codec.encodeString(FolderCategoryKey(' Math '))});
    await db
        .insert('bank_folders', {'bank_name': 'Bank', 'folder_name': ' Math '});
    await db.transaction((txn) => invalidateTrainingBindingsAtFinalState(txn));
    expect((await db.query(trainingContentsTable)).single['revision'], 4);
  });

  test(
      'untrustworthy lifecycle state throws a fixed failure and rolls original deletion back',
      () async {
    await seed(['Bank']);
    await db.insert('questions', {'id': 'q', 'bank_name': 'Bank'});
    await db.update(trainingContentsTable, {'category_key': 'malformed'});
    await expectLater(db.transaction((txn) async {
      await txn.delete('questions');
      await invalidateTrainingBindingsAtFinalState(txn);
    }), throwsA(isA<TrainingBindingLifecycleException>()));
    expect(await db.query('questions'), hasLength(1));
    expect(
        (await db.query(trainingContentMembersTable)).single['binding_status'],
        'valid');
    expect(const TrainingBindingLifecycleException().toString(),
        'TrainingBindingLifecycleException(unavailable)');
  });
}
