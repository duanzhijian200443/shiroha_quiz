import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/ordinary_training_bank_policy.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/exact_question_materializer.dart';
import 'package:shiroha_quiz/data/repositories/training_question_selection.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _typed = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _uncategorized = UncategorizedCategoryKey();
const _mapper = QuestionV2PersistenceMapper();

TrainingContent _content(
        {List<String> banks = const ['A'],
        List<int> weights = const [100],
        int limit = 3,
        CategoryKey category = _uncategorized,
        bool invalidated = false}) =>
    TrainingContent(
        contentId: 'content',
        categoryKey: category,
        name: 'Training',
        questionLimit: limit,
        sortOrder: 0,
        revision: 1,
        members: [
          for (var i = 0; i < banks.length; i++)
            TrainingContentMember(
                bankName: banks[i],
                weightPercent: weights[i],
                position: i,
                bindingStatus: invalidated
                    ? TrainingBindingStatus.invalidated
                    : TrainingBindingStatus.valid),
        ]);

List<String> _ids(TrainingQuestionSelectionResult result) {
  expect(result, isA<TrainingQuestionSelectionSuccess>());
  return (result as TrainingQuestionSelectionSuccess)
      .questions
      .map((q) => q.storageId)
      .toList();
}

/// Offsets supplied first, then Fisher-Yates chooses the last slot (no swaps).
final class _Offsets implements Random {
  _Offsets(this.offsets);
  final List<int> offsets;
  final List<int> bounds = [];
  var cursor = 0;
  @override
  int nextInt(int max) {
    bounds.add(max);
    return cursor < offsets.length ? offsets[cursor++] % max : max - 1;
  }

  @override
  bool nextBool() => throw UnsupportedError('unused');
  @override
  double nextDouble() => throw UnsupportedError('unused');
}

typedef _Rows = List<Map<String, Object?>>;

final class _ReadTrace implements Database {
  _ReadTrace(this.db);
  final Database db;
  final queries = <({String sql, List<Object?> args, int rows})>[];
  _Rows Function(String, _Rows)? transform;
  int transactions = 0;
  int writes = 0;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      db.transaction((txn) {
        transactions++;
        return action(_TracedTransaction(txn, this));
      }, exclusive: exclusive);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    writes++;
    throw StateError('Unexpected operation');
  }
}

final class _TracedTransaction implements Transaction {
  _TracedTransaction(this.txn, this.trace);
  final Transaction txn;
  final _ReadTrace trace;
  @override
  Future<_Rows> rawQuery(String sql, [List<Object?>? arguments]) async {
    final rows = await txn.rawQuery(sql, arguments);
    trace.queries.add((sql: sql, args: arguments ?? [], rows: rows.length));
    return trace.transform?.call(sql, rows) ?? rows;
  }

  @override
  Future<_Rows> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      txn.query(table,
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
  dynamic noSuchMethod(Invocation invocation) {
    trace.writes++;
    throw StateError('Unexpected write or nested transaction');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory temp;
  late _ReadTrace trace;
  late TrainingQuestionSelection selection;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('p3a_selection_');
    db = await DatabaseHelper.instance
        .openPathForTesting(p.join(temp.path, 'selection.db'));
    trace = _ReadTrace(db);
    selection = TrainingQuestionSelection(database: () async => trace);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });

  Future<void> question(String id,
      {String bank = 'A',
      int? state = 0,
      int? due = 0,
      bool typed = false}) async {
    if (typed) {
      final frozen = _mapper.freezeForWrite(
          storageId: id,
          bankName: bank,
          createdAt: 1,
          draft: QuestionDraftV2(
              questionId: 'draft',
              kind: QuestionKind.shortAnswer,
              stem: RichContent(nodes: [TextNode('synthetic')]),
              answer: ContentAnswer(
                  content:
                      RichContent(nodes: [TextNode('synthetic answer')]))));
      await db.insert('questions', frozen.questionRow);
      await db.insert('question_v2_payloads', frozen.payloadRow);
    } else {
      await db.insert('questions', {
        'id': id,
        'bank_name': bank,
        'type': 1,
        'content': 'synthetic',
        'options': '["A"]',
        'standard_answer': 'A',
        'created_at': 1
      });
    }
    if (state != null) {
      await db.insert('review_states',
          {'question_id': id, 'state': state, 'next_review_time': due});
    }
  }

  Future<void> pool(int count, {String bank = 'A', int state = 0}) async {
    final batch = db.batch();
    for (var i = 0; i < count; i++) {
      final id = '$bank-${i.toString().padLeft(5, '0')}';
      batch.insert('questions', {
        'id': id,
        'bank_name': bank,
        'type': 1,
        'content': 'synthetic',
        'options': '["A"]',
        'standard_answer': 'A',
        'created_at': i
      });
      batch.insert('review_states',
          {'question_id': id, 'state': state, 'next_review_time': i % 3});
    }
    await batch.commit(noResult: true);
  }

  Future<void> folder(String bank, String name) => db.insert(
      'bank_folders', {'bank_name': bank, 'folder_name': name}).then((_) {});
  Future<String> snapshot() async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name");
    return jsonEncode({
      for (final row in tables)
        row['name'] as String:
            (await db.rawQuery('SELECT * FROM "${row['name']}"'))
                .map(jsonEncode)
                .toList()
              ..sort()
    });
  }

  Iterable<({String sql, List<Object?> args, int rows})> windows() =>
      trace.queries
          .where((q) => q.sql == TrainingQuestionSelection.newWindowSql);

  for (final fixture in [
    (offset: 0, take: 3, ids: [0, 1, 2], windows: 1),
    (offset: 4, take: 3, ids: [4, 5, 6], windows: 1),
    (offset: 7, take: 3, ids: [7, 8, 9], windows: 1),
    (offset: 9, take: 3, ids: [9, 0, 1], windows: 2),
    (offset: 5, take: 10, ids: [5, 6, 7, 8, 9, 0, 1, 2, 3, 4], windows: 2),
  ]) {
    test('ordered window offset ${fixture.offset}, take ${fixture.take}',
        () async {
      await pool(10);
      final ids = _ids(await selection.selectNew(_content(limit: fixture.take),
          random: _Offsets([fixture.offset])));
      expect(ids,
          [for (final i in fixture.ids) 'A-${i.toString().padLeft(5, '0')}']);
      expect(windows(), hasLength(fixture.windows));
      expect(ids.toSet(), hasLength(ids.length));
      expect(trace.transactions, 1);
      expect(trace.writes, 0);
    });
  }

  test(
      'NEW is state zero, including attempts/logs; reset re-admits; missing state excluded',
      () async {
    await question('new');
    await question('reviewed', state: 1);
    await question('mastered', state: 3);
    await question('missing', state: null);
    await db.insert('answer_attempts', {
      'attempt_id': 'attempt',
      'question_id': 'new',
      'session_kind': 'normal',
      'modality': 'text',
      'answer_payload_json': '{"text":"synthetic"}',
      'answered_at': 1
    });
    await db.insert('review_logs', {
      'id': 'log',
      'question_id': 'new',
      'grade': 1,
      'review_time': 1,
      'duration_ms': 0
    });
    final before = await snapshot();
    expect(_ids(await selection.selectNew(_content(), random: _Offsets([0]))),
        ['new']);
    expect(await snapshot(), before);
    await db.update('review_states', {'state': 0},
        where: 'question_id = ?', whereArgs: ['reviewed']);
    expect(_ids(await selection.selectNew(_content(), random: _Offsets([0]))),
        ['new', 'reviewed']);
    expect(
        await db.query('review_states',
            where: 'question_id = ?', whereArgs: ['missing']),
        isEmpty);
  });

  test(
      'shortage refills positive banks; zero bank never counted/windowed/fallback',
      () async {
    await pool(1);
    await pool(20, bank: 'B');
    await pool(100, bank: 'Zero');
    final result = await selection.selectNew(
        _content(banks: ['A', 'B', 'Zero'], weights: [80, 20, 0], limit: 10),
        random: _Offsets([0, 0]));
    final questions = (result as TrainingQuestionSelectionSuccess).questions;
    expect(questions.where((q) => q.bankName == 'A'), hasLength(1));
    expect(questions.where((q) => q.bankName == 'B'), hasLength(9));
    expect(
        trace.queries
            .where((q) => q.sql == TrainingQuestionSelection.newCountSql)
            .map((q) => q.args.single),
        ['A', 'B']);
    expect(windows().map((q) => q.args.first), ['A', 'B']);
    await db.update('review_states', {'state': 1},
        where: "question_id LIKE 'A-%' OR question_id LIKE 'B-%'");
    expect(
        await selection.selectNew(
            _content(banks: ['A', 'B', 'Zero'], weights: [80, 20, 0]),
            random: Random(1)),
        isA<TrainingQuestionSelectionEmpty>());
  });

  test('seeded RNG controls offsets and final shuffle across bank blocks',
      () async {
    await pool(50);
    await pool(50, bank: 'B');
    final content = _content(banks: ['B', 'A'], weights: [50, 50], limit: 20);
    final first = _ids(await selection.selectNew(content, random: Random(17)));
    expect(_ids(await selection.selectNew(content, random: Random(17))), first);
    expect(_ids(await selection.selectNew(content, random: Random(18))),
        isNot(first));
    expect(first.take(10).map((id) => id[0]).toSet(), {'A', 'B'});
    expect(first.toSet(), hasLength(20));
    final result = await selection.selectNew(content, random: Random(17));
    expect(() => (result as TrainingQuestionSelectionSuccess).questions.clear(),
        throwsUnsupportedError);
  });

  test(
      'invalidated, missing, ineligible or moved members fail closed without writes',
      () async {
    await pool(3);
    await question('reserved', bank: globalWrongBookBankName);
    final before = await snapshot();
    for (final content in [
      _content(invalidated: true),
      _content(banks: ['missing']),
      _content(banks: [globalWrongBookBankName]),
      _content(category: FolderCategoryKey('Math'))
    ]) {
      expect(await selection.selectNew(content, random: Random(1)),
          isA<TrainingQuestionSelectionUnavailable>());
    }
    expect(await snapshot(), before);
  });

  test('legacy, typed and mixed materialization preserve shuffled exact order',
      () async {
    await question(_typed, typed: true);
    await question('legacy');
    final result = await selection.selectNew(_content(), random: _Offsets([1]));
    expect(_ids(result), ['legacy', _typed]);
    final rows = (result as TrainingQuestionSelectionSuccess).questions;
    expect(rows.first, isA<LegacyPersistedQuestion>());
    expect(rows.last, isA<TypedPersistedQuestion>());
    await db.delete('questions', where: 'id = ?', whereArgs: ['legacy']);
    expect(_ids(await selection.selectNew(_content(), random: Random(2))),
        [_typed]);
  });

  for (final failure in [
    'missing',
    'reviewMissing',
    'state',
    'bank',
    'folder',
    'partial',
    'partialBoth'
  ]) {
    test('selected $failure drift fails the whole NEW batch without retry',
        () async {
      await pool(3);
      trace.transform = (sql, rows) {
        if (!sql.contains('SELECT q.*')) return rows;
        final modified = [
          for (final row in rows) Map<String, Object?>.from(row)
        ];
        if (failure == 'missing') return modified.skip(1).toList();
        switch (failure) {
          case 'reviewMissing':
            modified.first['selected_review_id'] = null;
          case 'state':
            modified.first['selected_state'] = 1;
          case 'bank':
            modified.first['bank_name'] = 'other';
          case 'folder':
            modified.first['selected_folder'] = 'other';
          case 'partial':
            modified.first['selected_payload_id'] = modified.first['id'];
            modified.first[
                QuestionV2PersistenceMapper.payloadSchemaVersionAlias] = 2;
          case 'partialBoth':
            modified.first['selected_payload_id'] = modified.first['id'];
        }
        return modified;
      };
      expect(await selection.selectNew(_content(), random: _Offsets([0])),
          isA<TrainingQuestionSelectionUnavailable>());
      expect(windows(), hasLength(1));
      expect(trace.queries.where((q) => q.sql.contains('SELECT q.*')),
          hasLength(1));
    });
  }

  for (final bad in ['corrupt', 'unsafe', 'schema']) {
    test('$bad typed sidecar is whole failure for NEW and Category review',
        () async {
      await question(_typed, typed: true);
      await question('legacy');
      final payload = jsonDecode((await db.query('question_v2_payloads'))
          .single['payload_json'] as String) as Map<String, dynamic>;
      if (bad == 'unsafe') {
        payload['stem'] = {
          'schemaVersion': 1,
          'nodes': [
            {
              'type': 'future_diagram',
              'providerResponse': {'status': 'synthetic'}
            }
          ]
        };
      }
      if (bad == 'schema') payload['schemaVersion'] = 999;
      await db.update('question_v2_payloads',
          {'payload_json': bad == 'corrupt' ? '{' : jsonEncode(payload)});
      if (bad == 'unsafe') {
        final sidecar = (await db.query('question_v2_payloads')).single;
        final row =
            (await db.query('questions', where: 'id = ?', whereArgs: [_typed]))
                .single;
        expect(
            () => _mapper.decodeJoinedRow({
                  ...row,
                  QuestionV2PersistenceMapper.payloadSchemaVersionAlias:
                      sidecar['payload_schema_version'],
                  QuestionV2PersistenceMapper.payloadJsonAlias:
                      sidecar['payload_json'],
                }),
            throwsA(isA<QuestionV2PayloadException>().having((e) => e.failure,
                'safe failure', QuestionV2PayloadFailure.unsafePayload)));
      }
      expect(await selection.selectNew(_content(), random: _Offsets([0])),
          isA<TrainingQuestionSelectionUnavailable>());
      await db.update('review_states', {'state': 1});
      expect(
          await selection.selectCategoryReview(_uncategorized,
              nowUnixSeconds: 10),
          isA<TrainingQuestionSelectionUnavailable>());
    });
  }

  test(
      'Home exact helper rejects >100, missing IDs, duplicates before payload read',
      () async {
    await question('present');
    for (final ids in [
      List.generate(101, (i) => 'q$i'),
      ['present', 'present'],
      ['present', 'missing']
    ]) {
      await expectLater(
          db.transaction((txn) => materializeExactQuestions(txn, ids,
              maxIds: 100, requireReviewState: true)),
          throwsFormatException);
    }
  });

  test(
      'Category review includes all eligible banks independently of contents/zero weight',
      () async {
    await question('a', state: 1, due: 5);
    await question('b', bank: 'Zero', state: 2, due: 5);
    await question(_typed, bank: 'NoContent', state: 3, due: 2, typed: true);
    await question('not-due', bank: 'Zero', state: 1, due: 11);
    await question('new', bank: 'A', state: 0);
    await question('no-state', state: null);
    await question('wrong', bank: globalWrongBookBankName, state: 1);
    await question('exam', bank: hiddenExamBankName, state: 1);
    await question('other', bank: 'Other', state: 1);
    for (final bank in [
      'A',
      'Zero',
      'NoContent',
      globalWrongBookBankName,
      hiddenExamBankName
    ]) {
      await folder(bank, '数学📘');
    }
    await folder('Other', 'Other');
    await db.insert('training_contents', {
      'content_id': 'config',
      'category_key': '["folder","数学📘"]',
      'name': 'config',
      'question_limit': 1,
      'sort_order': 0,
      'revision': 1
    });
    for (final bank in ['A', 'Zero']) {
      await db.insert('training_content_members', {
        'content_id': 'config',
        'bank_name': bank,
        'weight_percent': bank == 'A' ? 100 : 0,
        'position': bank == 'A' ? 0 : 1,
        'binding_status': 'invalidated',
        'invalidation_reason': 'bankMissing'
      });
    }
    final before = await snapshot();
    final category = FolderCategoryKey('数学📘');
    expect(
        _ids(
            await selection.selectCategoryReview(category, nowUnixSeconds: 10)),
        [_typed, 'a', 'b']);
    expect(await snapshot(), before);
    await db.delete('training_contents');
    expect(
        _ids(
            await selection.selectCategoryReview(category, nowUnixSeconds: 10)),
        [_typed, 'a', 'b']);
    expect(
        await selection.selectCategoryReview(FolderCategoryKey('数学📘 '),
            nowUnixSeconds: 10),
        isA<TrainingQuestionSelectionEmpty>());
  });

  test('Category due order/id ties cap at 40 and Uncategorized only unmapped',
      () async {
    await pool(100, state: 3);
    await question('mapped', bank: 'Mapped', state: 1);
    await folder('Mapped', 'Folder');
    final expected = (await db.rawQuery(
            'SELECT q.id FROM questions q JOIN review_states r ON q.id = r.question_id WHERE q.bank_name = ? ORDER BY r.next_review_time, q.id LIMIT 40',
            ['A']))
        .map((r) => r['id'])
        .toList();
    final ids = _ids(await selection.selectCategoryReview(_uncategorized,
        nowUnixSeconds: 2));
    expect(ids, expected);
    expect(ids.toSet(), hasLength(40));
    expect(trace.queries.singleWhere((q) => q.sql.contains('SELECT q.*')).rows,
        40);
    expect(trace.writes, 0);
  });

  for (final field in [
    'selected_review_id',
    'selected_state',
    'selected_due',
    'bank_name',
    'selected_folder'
  ]) {
    test(
        'Category materialization rejects required row/predicate drift: $field',
        () async {
      await question('due', state: 1);
      trace.transform = (sql, rows) => !sql.contains('SELECT q.*')
          ? rows
          : [
              for (final row in rows)
                {
                  ...row,
                  field: switch (field) {
                    'selected_state' => 0,
                    'selected_due' => 100,
                    'bank_name' => 'other',
                    'selected_folder' => 'other',
                    _ => null,
                  }
                },
            ];
      expect(
          await selection.selectCategoryReview(_uncategorized,
              nowUnixSeconds: 10),
          isA<TrainingQuestionSelectionUnavailable>());
    });
  }

  for (final existingBankIndex in [false, true]) {
    test(
        'large synthetic bank is bounded; existing bank index = $existingBankIndex',
        () async {
      await pool(10000);
      await pool(100, bank: 'Zero');
      if (existingBankIndex) {
        // Simulate the existing index authority after the historical catalog has
        // been used; never invoke its self-healing query during P3a selection.
        await db.execute(
            'CREATE INDEX idx_questions_bank_name ON questions(bank_name)');
      }
      final content =
          _content(banks: ['A', 'Zero'], weights: [100, 0], limit: 100);
      final result =
          await selection.selectNew(content, random: _Offsets([9999]));
      expect(_ids(result), hasLength(100));
      expect(windows(), hasLength(2));
      expect(windows().map((q) => q.rows), [1, 99]);
      final full =
          trace.queries.where((q) => q.sql.contains('SELECT q.*')).single;
      expect(full.rows, 100);
      expect(full.args, hasLength(100));
      expect(
          trace.queries.every((q) => !q.sql.toUpperCase().contains('RANDOM()')),
          isTrue);
      final indexNames = (await db
              .rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'"))
          .map((r) => r['name'])
          .toSet();
      expect(indexNames, contains('idx_review_states_question_id'));
      expect(indexNames.contains('idx_questions_bank_name'), existingBankIndex);
      for (final q in trace.queries.where((q) =>
          q.sql == TrainingQuestionSelection.newCountSql ||
          q.sql == TrainingQuestionSelection.newWindowSql ||
          q.sql.contains('SELECT q.*'))) {
        final plan = await db.rawQuery('EXPLAIN QUERY PLAN ${q.sql}', q.args);
        final details = plan.map((r) => r['detail'] as String).join('\n');
        // Plans contain schema/index labels only, never synthetic content/IDs.
        expect(details, anyOf(contains('SEARCH q'), contains('SCAN q')));
        if (!q.sql.contains('SELECT q.*')) {
          expect(details, contains('SEARCH r USING INDEX'));
          expect(q.sql, isNot(contains('payload')));
          if (existingBankIndex) {
            expect(details, contains('idx_questions_bank_name'));
          }
        } else {
          expect(details,
              contains('SEARCH q USING INDEX sqlite_autoindex_questions'));
          expect(details, contains('SEARCH p USING INDEX'));
        }
        // ignore: avoid_print
        print('P3a query plan: $details');
      }
      expect(await db.getVersion(), DatabaseHelper.databaseVersion);
      expect(trace.transactions, 1);
      expect(trace.writes, 0);
    });
  }

  test('large Category bank set merges bounded due prefixes in global order',
      () async {
    final batch = db.batch();
    for (var i = 0; i < 410; i++) {
      final id = 'q${i.toString().padLeft(3, '0')}';
      batch.insert('questions', {
        'id': id,
        'bank_name': 'bank${i.toString().padLeft(3, '0')}',
        'type': 1,
        'content': 'synthetic',
        'options': '["A"]',
        'standard_answer': 'A',
        'created_at': 1
      });
      batch.insert('review_states',
          {'question_id': id, 'state': 1, 'next_review_time': 410 - i});
    }
    await batch.commit(noResult: true);
    expect(
        _ids(await selection.selectCategoryReview(_uncategorized,
            nowUnixSeconds: 500)),
        [for (var i = 409; i >= 370; i--) 'q${i.toString().padLeft(3, '0')}']);
    final dueQueries =
        trace.queries.where((q) => q.sql.contains('WITH eligible_banks'));
    expect(dueQueries, hasLength(2));
    expect(
        dueQueries.every((q) => q.args.length <= 401 && q.rows <= 40), isTrue);
    expect(trace.queries.singleWhere((q) => q.sql.contains('SELECT q.*')).rows,
        40);
    for (final q in dueQueries) {
      final plan = await db.rawQuery('EXPLAIN QUERY PLAN ${q.sql}', q.args);
      final details = plan.map((row) => row['detail'] as String).join('\n');
      // SQLite chooses bank-first for the 400-bank chunk and state-first for
      // the 10-bank chunk. Both join through an existing identity index; the
      // contract bounds returned rows, not metadata scans or join-loop order.
      expect(
          details,
          anyOf(contains('SEARCH r USING INDEX'),
              contains('SEARCH q USING INDEX sqlite_autoindex_questions')));
      expect(q.sql, isNot(contains('payload')));
      // ignore: avoid_print
      print('P3a Category review plan: $details');
    }
  });

  test('corrupt seventeenth sidecar fails the entire forty-item review batch',
      () async {
    for (var i = 0; i < 41; i++) {
      await question(i == 16 ? _typed : 'due${i.toString().padLeft(2, '0')}',
          state: 1, due: i, typed: i == 16);
    }
    final good = await selection.selectCategoryReview(_uncategorized,
        nowUnixSeconds: 100);
    expect(_ids(good), hasLength(40));
    expect(_ids(good)[16], _typed);
    await db.update('question_v2_payloads', {'payload_json': '{'});
    expect(
        await selection.selectCategoryReview(_uncategorized,
            nowUnixSeconds: 100),
        isA<TrainingQuestionSelectionUnavailable>());
  });

  test(
      'cross-chunk due ties preserve SQLite storage-ID order for Unicode legacy IDs',
      () async {
    final batch = db.batch();
    for (var i = 0; i < 401; i++) {
      final id =
          switch (i) { 0 => '\uE000', 400 => '\u{10000}', _ => 'unused$i' };
      batch.insert('questions', {
        'id': id,
        'bank_name': 'bank${i.toString().padLeft(3, '0')}',
        'type': 1,
        'content': 'synthetic',
        'options': '["A"]',
        'standard_answer': 'A',
        'created_at': 1
      });
      batch.insert('review_states', {
        'question_id': id,
        'state': 1,
        'next_review_time': i == 0 || i == 400 ? 0 : 100
      });
    }
    await batch.commit(noResult: true);
    final sqlOrder = (await db.rawQuery(
            'SELECT q.id FROM questions q JOIN review_states r ON r.question_id = q.id WHERE r.state > 0 AND r.next_review_time <= 0 ORDER BY r.next_review_time ASC, q.id ASC LIMIT 40'))
        .map((r) => r['id'])
        .toList();
    expect(sqlOrder, ['\uE000', '\u{10000}']);
    expect(
        _ids(await selection.selectCategoryReview(_uncategorized,
            nowUnixSeconds: 0)),
        sqlOrder);
  });

  test('unselected or zero-weight corrupt sidecars are never materialized',
      () async {
    await pool(3);
    await question(_typed, bank: 'Zero', typed: true);
    await db.update('question_v2_payloads', {'payload_json': '{'});
    final result = await selection.selectNew(
        _content(banks: ['A', 'Zero'], weights: [100, 0], limit: 1),
        random: _Offsets([0]));
    expect(_ids(result), ['A-00000']);
    expect(trace.queries.singleWhere((q) => q.sql.contains('SELECT q.*')).args,
        ['A-00000']);
  });

  test(
      'synthetic duplicate ID window fails without partial/replacement results',
      () async {
    await pool(3);
    trace.transform = (sql, rows) =>
        sql == TrainingQuestionSelection.newWindowSql
            ? [rows.first, rows.first, rows.last]
            : rows;
    expect(await selection.selectNew(_content(), random: _Offsets([0])),
        isA<TrainingQuestionSelectionUnavailable>());
    expect(windows(), hasLength(1));
    expect(trace.queries.where((q) => q.sql.contains('SELECT q.*')), isEmpty);
  });

  test('database/open failure is a safe unavailable without details', () async {
    final broken = TrainingQuestionSelection(
        database: () async => throw StateError('synthetic'));
    expect(await broken.selectNew(_content(), random: Random(1)),
        isA<TrainingQuestionSelectionUnavailable>());
    await db.close();
    expect(
        await selection.selectCategoryReview(_uncategorized,
            nowUnixSeconds: 10),
        isA<TrainingQuestionSelectionUnavailable>());
  });
}
