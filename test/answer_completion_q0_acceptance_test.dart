import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/answer_completion_query.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/imported_question_set_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const setId = '11111111-1111-4111-8111-111111111111';
const bank = 'synthetic-bank';
String questionId(int i) =>
    '22222222-2222-4222-8222-${i.toString().padLeft(12, '0')}';
QuestionDraftV2 draft(int i, {QuestionAnswer? answer}) => QuestionDraftV2(
    questionId: questionId(i),
    kind: QuestionKind.shortAnswer,
    questionNumber: i + 1,
    stem: RichContent(nodes: [TextNode('Synthetic $i')]),
    answer: answer);
QuestionAnswer answer(String value) =>
    ContentAnswer(content: RichContent(nodes: [TextNode(value)]));

Future<void> seedQuestion(DatabaseExecutor db, int i,
    {QuestionAnswer? value, bool legacy = false}) async {
  final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
      storageId: questionId(i),
      bankName: bank,
      createdAt: i,
      draft: draft(i, answer: value));
  await db.insert('questions', frozen.questionRow);
  if (!legacy) await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> seedSet(DatabaseExecutor db, List<int> ids,
    {String? source}) async {
  await db.insert('imported_question_sets', {
    'set_id': setId,
    'bank_name': bank,
    'display_name': 'synthetic.pdf',
    'created_at': 1,
    'source_file_id': source
  });
  for (var i = 0; i < ids.length; i++) {
    await db.insert('imported_question_set_items', {
      'set_id': setId,
      'question_storage_id': questionId(ids[i]),
      'position': i
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async => DatabaseHelper.resetRuntimeProfileForTesting());
  tearDown(() async => DatabaseHelper.resetRuntimeProfileForTesting());
  Future<AnswerCompletionSnapshot> read() async =>
      await ImportedQuestionSetRepository().readBank(bank)
          as AnswerCompletionSnapshot;

  test(
      'all missing, 21 answered + 1 missing, explicit empty and exact completed',
      () async {
    final db = await DatabaseHelper.instance.database;
    for (var i = 0; i < 22; i++) {
      await seedQuestion(db, i);
    }
    await seedSet(db, List.generate(22, (i) => 21 - i));
    var set = (await read()).sets.single;
    expect(
        [set.total, set.missing, set.answered, set.ineligible], [22, 22, 0, 0]);
    expect(set.members.map((m) => m.storageId),
        List.generate(22, (i) => questionId(21 - i)));
    await db.transaction((txn) async {
      for (var i = 0; i < 21; i++) {
        final update = const QuestionV2PersistenceMapper().freezeAnswerUpdate(
            storageId: questionId(i),
            replacementDraft: draft(i, answer: answer('')));
        await txn.update('question_v2_payloads', update.payloadRow,
            where: 'question_id = ?', whereArgs: [questionId(i)]);
      }
    });
    set = (await read()).sets.single;
    expect(
        [set.total, set.missing, set.answered, set.ineligible], [22, 1, 21, 0]);
    expect(set.completed, isFalse);
    final update = const QuestionV2PersistenceMapper().freezeAnswerUpdate(
        storageId: questionId(21),
        replacementDraft: draft(21, answer: answer('')));
    await db.update('question_v2_payloads', update.payloadRow,
        where: 'question_id = ?', whereArgs: [questionId(21)]);
    set = (await read()).sets.single;
    expect(set.completed, isTrue);
    expect(set.category, AnswerCompletionCategory.completed);
    expect(() => set.members.clear(), throwsUnsupportedError);
  });

  test('legacy-only, mixed and corrupt stay visible and never shrink',
      () async {
    final db = await DatabaseHelper.instance.database;
    await seedQuestion(db, 0, legacy: true);
    await seedSet(db, [0]);
    var set = (await read()).sets.single;
    expect(
        [set.total, set.missing, set.answered, set.ineligible], [1, 0, 0, 1]);
    expect(set.completed, isFalse);
    await seedQuestion(db, 1);
    await db.insert('imported_question_set_items',
        {'set_id': setId, 'question_storage_id': questionId(1), 'position': 1});
    set = (await read()).sets.single;
    expect(
        [set.total, set.missing, set.answered, set.ineligible], [2, 1, 0, 1]);
    expect(set.canSupplement, isFalse);
    await db.update('question_v2_payloads', {'payload_json': '{invalid'},
        where: 'question_id = ?', whereArgs: [questionId(1)]);
    set = (await read()).sets.single;
    expect(set.members.last.eligibility, AnswerCompletionEligibility.corrupt);
    expect(
        [set.total, set.missing, set.answered, set.ineligible], [2, 0, 0, 2]);
    expect(set.category, AnswerCompletionCategory.unsupported);
  });

  test(
      'ungrouped only valid typed missing; answered leaves without synthetic set',
      () async {
    final db = await DatabaseHelper.instance.database;
    await seedQuestion(db, 0);
    await seedQuestion(db, 1, legacy: true);
    await seedQuestion(db, 2, value: answer(''));
    await seedQuestion(db, 3);
    await seedSet(db, [3]);
    expect((await read()).ungrouped.map((m) => m.storageId), [questionId(0)]);
    final update = const QuestionV2PersistenceMapper().freezeAnswerUpdate(
        storageId: questionId(0),
        replacementDraft: draft(0, answer: answer('filled')));
    await db.update('question_v2_payloads', update.payloadRow,
        where: 'question_id = ?', whereArgs: [questionId(0)]);
    final result = await read();
    expect(result.ungrouped, isEmpty);
    expect(result.sets, hasLength(1));
  });

  test('null provenance differs from deleted; source deletion preserves set',
      () async {
    final db = await DatabaseHelper.instance.database;
    await seedQuestion(db, 0);
    await seedSet(db, [0]);
    expect(
        (await read()).sets.single.provenance, AnswerCompletionProvenance.none);
    await db.update('imported_question_sets', {'source_file_id': 'source'});
    expect((await read()).sets.single.provenance,
        AnswerCompletionProvenance.unavailable);
    await db.insert('library_files', {
      'file_id': 'source',
      'display_name': 'synthetic.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'synthetic/file',
      'created_at': 1
    });
    expect((await read()).sets.single.provenance,
        AnswerCompletionProvenance.available);
    await db
        .delete('library_files', where: 'file_id = ?', whereArgs: ['source']);
    final set = (await read()).sets.single;
    expect(set.provenance, AnswerCompletionProvenance.unavailable);
    expect(set.total, 1);
  });

  test('empty durable anomaly is not completed; query failure has no snapshot',
      () async {
    final db = await DatabaseHelper.instance.database;
    await seedSet(db, []);
    final set = (await read()).sets.single;
    expect(set.total, 0);
    expect(set.completed, isFalse);
    expect(set.canSupplement, isFalse);
    await db.execute('DROP TABLE question_v2_payloads');
    expect(await ImportedQuestionSetRepository().readBank(bank),
        isA<AnswerCompletionQueryUnavailable>());
  });

  for (final operation in ['answer', 'delete', 'move']) {
    test(
        'concurrent $operation is complete before/after, all reads share transaction',
        () async {
      final db = await DatabaseHelper.instance.database;
      await seedQuestion(db, 0);
      await seedQuestion(db, 1);
      await seedSet(db, [0, 1]);
      late Future<void> mutation;
      final instrumented = _ObservedDatabase(db, () {
        mutation = db.transaction((txn) async {
          for (var i = 0; i < 2; i++) {
            if (operation == 'answer') {
              final update = const QuestionV2PersistenceMapper()
                  .freezeAnswerUpdate(
                      storageId: questionId(i),
                      replacementDraft: draft(i, answer: answer('filled')));
              await txn.update('question_v2_payloads', update.payloadRow,
                  where: 'question_id = ?', whereArgs: [questionId(i)]);
            } else if (operation == 'delete') {
              await txn.delete('questions',
                  where: 'id = ?', whereArgs: [questionId(i)]);
            } else {
              await txn.update('questions', {'bank_name': 'other'},
                  where: 'id = ?', whereArgs: [questionId(i)]);
            }
          }
        });
      });
      final result = await ImportedQuestionSetRepository(
              database: () async => instrumented).readBank(bank)
          as AnswerCompletionSnapshot;
      expect(instrumented.transactions, 1);
      expect(instrumented.reads, 3);
      expect([
        result.sets.single.total,
        result.sets.single.missing,
        result.sets.single.answered
      ], [
        2,
        2,
        0
      ]);
      await mutation;
      final after = await read();
      if (operation == 'answer') {
        expect([
          after.sets.single.total,
          after.sets.single.missing,
          after.sets.single.answered
        ], [
          2,
          0,
          2
        ]);
      } else {
        expect(after.sets, isEmpty);
        expect(after.ungrouped, isEmpty);
      }
    });
  }
}

/// Test-only interleaving: queue a real writer after the first read statement.
/// The production transaction must prevent later reads from mixing its state.
class _ObservedDatabase extends Fake implements Database {
  _ObservedDatabase(this.delegate, this.afterFirstRead);
  final Database delegate;
  final void Function() afterFirstRead;
  int transactions = 0;
  int reads = 0;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) {
    transactions++;
    return delegate.transaction(
        (txn) => action(_ObservedTransaction(txn, this)),
        exclusive: exclusive);
  }
}

class _ObservedTransaction extends Fake implements Transaction {
  _ObservedTransaction(this.delegate, this.owner);
  final Transaction delegate;
  final _ObservedDatabase owner;
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    final result = await delegate.rawQuery(sql, arguments);
    if (++owner.reads == 1) owner.afterFirstRead();
    return result;
  }
}
