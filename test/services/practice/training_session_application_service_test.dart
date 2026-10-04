import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_session_contracts.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/ordinary_training_bank_policy.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/training_configuration_repository.dart';
import 'package:shiroha_quiz/data/repositories/training_question_selection.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/services/practice/training_session_application_service.dart';

const _category = UncategorizedCategoryKey();
const _typed = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _mapper = QuestionV2PersistenceMapper();

typedef _Rows = List<Map<String, Object?>>;

/// Real SQLite reads only through one owned transaction. Failure injection acts
/// at the selected-row boundary, never through a production writer or decoder.
final class _ReadDatabase implements Database {
  _ReadDatabase(this.db);
  final Database db;
  final reads = <String>[];
  final windows = <List<Object?>>[];
  _Rows Function(String, _Rows)? transform;
  Future<void> Function()? beforeTransaction;
  int transactions = 0;
  bool active = false;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    await beforeTransaction?.call();
    transactions++;
    try {
      return await db.transaction((tx) {
        active = true;
        return action(_ReadTransaction(tx, this));
      }, exclusive: exclusive);
    } finally {
      active = false;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Read outside owned transaction');
}

final class _ReadTransaction implements Transaction {
  _ReadTransaction(this.tx, this.owner);
  final Transaction tx;
  final _ReadDatabase owner;
  @override
  Future<_Rows> rawQuery(String sql, [List<Object?>? arguments]) async {
    expect(owner.active, isTrue);
    owner.reads.add(sql);
    if (sql == TrainingQuestionSelection.newWindowSql) {
      owner.windows.add(arguments!);
    }
    final rows = await tx.rawQuery(sql, arguments);
    return owner.transform?.call(sql, rows) ?? rows;
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
      int? offset}) async {
    expect(owner.active, isTrue);
    owner.reads.add(table);
    final rows = await tx.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    return owner.transform?.call(table, rows) ?? rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Write or nested transaction during admission');
}

/// Observes the commit seam while delegating to the real prepared queue.
final class _Engine implements ReviewEngineService {
  _Engine(this.trace);
  final _ReadDatabase trace;
  final real = ReviewEngineService();
  int replacements = 0;
  @override
  void initPreparedStudySession(List<PersistedQuestion> questions) {
    expect(trace.active, isFalse);
    replacements++;
    real.initPreparedStudySession(questions);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected engine operation');
}

TrainingContentTarget _target(TrainingContent content) => TrainingContentTarget(
    contentId: content.contentId, expectedRevision: content.revision);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory temp;
  late TrainingConfigurationRepository config;
  late _ReadDatabase trace;
  late _Engine engine;
  late TrainingQuestionSelection selection;
  late DefaultTrainingSessionApplicationService service;
  late List<PersistedQuestion> sentinel;
  int randomCalls = 0;
  int clockCalls = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('p3b_launch_');
    db = await DatabaseHelper.instance
        .openPathForTesting(p.join(temp.path, 'launch.db'));
    config = TrainingConfigurationRepository(database: () async => db);
    trace = _ReadDatabase(db);
    selection = TrainingQuestionSelection(database: () async => trace);
    engine = _Engine(trace);
    randomCalls = clockCalls = 0;
    service = DefaultTrainingSessionApplicationService(
        selection: selection,
        reviewEngine: engine,
        randomFactory: () {
          randomCalls++;
          return Random(17);
        },
        clock: () {
          clockCalls++;
          return DateTime.fromMillisecondsSinceEpoch(
              (100 + clockCalls - 1) * 1000);
        });
    sentinel = [
      for (final id in ['oldA', 'oldB'])
        _mapper.decodeJoinedRow({
          'id': id,
          'bank_name': 'sentinel',
          'type': 1,
          'content': 'synthetic',
          'options': '["A"]',
          'standard_answer': 'A',
          'created_at': 1,
        })
    ];
    engine.real.initPreparedStudySession(sentinel);
  });
  tearDown(() async {
    engine.real.resetTransientStateForRestore();
    if (db.isOpen) await db.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  });

  Future<void> question(String id,
      {String bank = 'A',
      int? state = 0,
      int due = 0,
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
                  content: RichContent(nodes: [TextNode('answer')]))));
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
        'created_at': 1,
      });
    }
    if (state != null) {
      await db.insert('review_states',
          {'question_id': id, 'state': state, 'next_review_time': due});
    }
  }

  TrainingContentEdit edit(
          {List<String> banks = const ['A'],
          List<int> weights = const [100],
          int limit = 3}) =>
      TrainingContentEdit(
          name: 'Training',
          questionLimit: limit,
          sortOrder: 0,
          members: [
            for (var i = 0; i < banks.length; i++)
              TrainingContentMember(
                  bankName: banks[i], weightPercent: weights[i], position: i)
          ]);

  Future<TrainingContent> create(
          {List<String> banks = const ['A'],
          List<int> weights = const [100],
          int limit = 3}) async =>
      (await config.create(CreateTrainingContentRequest(
                  categoryKey: _category,
                  edit: edit(banks: banks, weights: weights, limit: limit)))
              as HomeTrainingSuccess<TrainingContent>)
          .value;

  List<PersistedQuestion> drain() {
    final result = <PersistedQuestion>[];
    for (var q = engine.real.popNextQuestion();
        q != null;
        q = engine.real.popNextQuestion()) {
      result.add(q);
    }
    return result;
  }

  void unchangedQueue() {
    expect(engine.replacements, 0);
    final actual = drain();
    expect(actual, sentinel);
    expect(identical(actual.first, sentinel.first), isTrue);
  }

  Future<String> snapshot() async => jsonEncode({
        'schema': await db.rawQuery(
            'SELECT type, name, sql FROM sqlite_master ORDER BY type, name'),
        for (final row in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
          row['name'] as String:
              await db.rawQuery('SELECT * FROM "${row['name']}"'),
      });

  test('single-bank mixed batch replaces once in exact P3a order, no writes',
      () async {
    await question('legacy');
    await question(_typed, typed: true);
    final content = await create();
    final expected = await selection.selectNewTarget(_target(content),
        random: Random(17)) as TrainingQuestionSelectionSuccess;
    trace.transactions = 0;
    trace.reads.clear();
    final before = await snapshot();
    final result = await service.startNew(_target(content));
    expect(result, isA<TrainingSessionReady>());
    expect((result as TrainingSessionReady).questionCount, 2);
    final queue = drain();
    expect(queue.map((q) => q.storageId),
        expected.questions.map((q) => q.storageId));
    expect(queue.whereType<TypedPersistedQuestion>(), hasLength(1));
    expect(queue.whereType<LegacyPersistedQuestion>(), hasLength(1));
    expect(engine.replacements, 1);
    expect(trace.transactions, 1);
    expect(randomCalls, 1);
    expect(clockCalls, 0);
    expect(trace.reads.first, 'training_contents');
    expect(trace.reads, contains('training_content_members'));
    expect(trace.reads.where((s) => s.contains('SELECT q.*')), hasLength(1));
    expect(await snapshot(), before);
    expect(await db.query('review_states', columns: ['state']),
        everyElement({'state': 0}));
  });

  test('multi-bank weighted shortage uses live counts, zero never refills',
      () async {
    await question('A-0');
    for (var i = 0; i < 6; i++) {
      await question('B-$i', bank: 'B');
    }
    await question('zero', bank: 'Zero');
    final content =
        await create(banks: ['A', 'B', 'Zero'], weights: [80, 20, 0], limit: 5);
    // Caller captured a target before a real grade changed the live NEW pool.
    await db.update('review_states', {'state': 1},
        where: 'question_id = ?', whereArgs: ['B-0']);
    final result = await service.startNew(_target(content));
    expect((result as TrainingSessionReady).questionCount, 5);
    final queue = drain();
    expect(queue.where((q) => q.bankName == 'A'), hasLength(1));
    expect(queue.where((q) => q.bankName == 'B'), hasLength(4));
    expect(queue.any((q) => q.bankName == 'Zero' || q.storageId == 'B-0'),
        isFalse);
    expect(trace.windows.map((w) => w.first).toSet(), {'A', 'B'});
    expect(trace.transactions, 1);
    expect(engine.replacements, 1);
  });

  test(
      'revision updated immediately before admission is stale, no old snapshot',
      () async {
    await question('q');
    final captured = await create();
    // A genuine config writer commits after click/target capture but before the
    // selection snapshot starts. The service must not read/getById beforehand.
    trace.beforeTransaction = () async {
      final updated = await config.update(UpdateTrainingContentRequest(
          target: _target(captured), edit: edit(limit: 1)));
      expect(updated, isA<HomeTrainingSuccess<TrainingContent>>());
    };
    expect(await service.startNew(_target(captured)),
        isA<TrainingSessionStaleConfiguration>());
    expect(trace.transactions, 1);
    expect(trace.reads, ['training_contents']);
    expect(trace.windows, isEmpty);
    unchangedQueue();
  });

  test('deleted target is stale and never redirects to another valid content',
      () async {
    await question('q');
    final deleted = await create();
    await create();
    await config.delete(_target(deleted));
    expect(await service.startNew(_target(deleted)),
        isA<TrainingSessionStaleConfiguration>());
    unchangedQueue();
  });

  test('valid empty NEW pool leaves sentinel and missing ReviewState unhealed',
      () async {
    await question('graded', state: 1);
    await question('without-state', state: null);
    final content = await create();
    final before = await snapshot();
    expect(
        await service.startNew(_target(content)), isA<TrainingSessionEmpty>());
    expect(trace.transactions, 1);
    expect(trace.windows, isEmpty);
    expect(await snapshot(), before);
    unchangedQueue();
  });

  for (final failure in [
    'invalidated',
    'missing-bank',
    'category',
    'ineligible',
    'malformed-category',
    'malformed-members'
  ]) {
    test('matching revision with $failure is unavailable, queue untouched',
        () async {
      await question('q');
      final content = await create();
      switch (failure) {
        case 'invalidated':
          await db.update('training_content_members', {
            'binding_status': 'invalidated',
            'invalidation_reason': 'bankMissing'
          });
        case 'missing-bank':
          await db.delete('questions');
        case 'category':
          await db.insert(
              'bank_folders', {'bank_name': 'A', 'folder_name': 'Other'});
        case 'ineligible':
          await db.update('questions', {'bank_name': globalWrongBookBankName});
          await db.update('training_content_members',
              {'bank_name': globalWrongBookBankName});
        case 'malformed-category':
          await db.update('training_contents', {'category_key': 'invalid'});
        case 'malformed-members':
          await db.update('training_content_members', {'weight_percent': 99});
      }
      final before = await snapshot();
      expect(await service.startNew(_target(content)),
          isA<TrainingSessionUnavailable>());
      expect(await snapshot(), before);
      unchangedQueue();
    });
  }

  for (final failure in [
    'question',
    'review-state',
    'state',
    'bank',
    'folder',
    'partial-sidecar',
    'read-failure'
  ]) {
    test('selected $failure failure leaves exact sentinel, no retry', () async {
      await question('q');
      final content = await create();
      trace.transform = (sql, rows) {
        if (!sql.contains('SELECT q.*')) return rows;
        if (failure == 'read-failure') {
          throw StateError('synthetic read failure');
        }
        if (failure == 'question') return [];
        return [
          for (final row in rows)
            {
              ...row,
              ...switch (failure) {
                'review-state' => {'selected_review_id': null},
                'state' => {'selected_state': 1},
                'bank' => {'bank_name': 'Other'},
                'folder' => {'selected_folder': 'Other'},
                'partial-sidecar' => {'selected_payload_id': 'q'},
                _ => <String, Object?>{},
              }
            }
        ];
      };
      final before = await snapshot();
      expect(await service.startNew(_target(content)),
          isA<TrainingSessionUnavailable>());
      expect(trace.transactions, 1);
      expect(trace.windows, hasLength(1));
      expect(trace.reads.where((s) => s.contains('SELECT q.*')), hasLength(1));
      expect(await snapshot(), before);
      unchangedQueue();
    });
  }

  for (final categoryReview in [false, true]) {
    for (final kind in ['corrupt', 'unsafe', 'partial']) {
      test('typed $kind leaves sentinel, review=$categoryReview', () async {
        await question('legacy', state: categoryReview ? 1 : 0);
        await question(_typed, typed: true, state: categoryReview ? 3 : 0);
        final content = await create();
        final payload = jsonDecode((await db.query('question_v2_payloads'))
            .single['payload_json'] as String) as Map<String, dynamic>;
        if (kind == 'unsafe') {
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
        if (kind == 'partial') {
          // Fresh schema rejects null sidecars. Inject an incomplete selected
          // join at the read boundary, preserving the sidecar presence sentinel.
          trace.transform = (sql, rows) => sql.contains('SELECT q.*')
              ? [
                  for (final row in rows)
                    {
                      ...row,
                      if (row['id'] == _typed)
                        QuestionV2PersistenceMapper.payloadJsonAlias: null,
                    }
                ]
              : rows;
        } else {
          await db.update('question_v2_payloads',
              {'payload_json': kind == 'corrupt' ? '{' : jsonEncode(payload)});
        }
        final before = await snapshot();
        expect(
            categoryReview
                ? await service.startCategoryReview(_category)
                : await service.startNew(_target(content)),
            isA<TrainingSessionUnavailable>());
        expect(await snapshot(), before);
        unchangedQueue();
      });
    }
  }

  for (final failure in ['question', 'review-state', 'due']) {
    test('Category selected $failure whole failure leaves sentinel', () async {
      await question('q', state: 3, due: 100);
      trace.transform = (sql, rows) {
        if (!sql.contains('SELECT q.*')) return rows;
        if (failure == 'question') return [];
        return [
          for (final row in rows)
            {
              ...row,
              if (failure == 'review-state') 'selected_review_id': null,
              if (failure == 'due') 'selected_due': 101
            }
        ];
      };
      expect(await service.startCategoryReview(_category),
          isA<TrainingSessionUnavailable>());
      expect(clockCalls, 1);
      expect(trace.transactions, 1);
      unchangedQueue();
    });
  }

  for (final mode in ['usable', 'invalidated', 'deleted', 'none']) {
    test(
        'Category review independent of $mode content, captured time/order/cap',
        () async {
      for (var i = 0; i < 45; i++) {
        await question('due-${i.toString().padLeft(2, '0')}',
            bank: i.isEven ? 'A' : 'Zero', state: i % 3 + 1, due: 100);
      }
      await question('first', bank: 'Outside', state: 3, due: 99);
      await question('future', bank: 'Outside', state: 1, due: 101);
      await question('new', bank: 'Outside');
      await question('reserved', bank: hiddenExamBankName, state: 1);
      await question('wrong', bank: globalWrongBookBankName, state: 2);
      await question('other', bank: 'Other', state: 1);
      await db.insert(
          'bank_folders', {'bank_name': 'Other', 'folder_name': 'Other'});
      if (mode != 'none') {
        final content =
            await create(banks: ['A', 'Zero'], weights: [100, 0], limit: 1);
        if (mode == 'invalidated') {
          await db.update('training_content_members', {
            'binding_status': 'invalidated',
            'invalidation_reason': 'bankMissing'
          });
        } else if (mode == 'deleted') {
          await config.delete(_target(content));
        }
      }
      final before = await snapshot();
      final result = await service.startCategoryReview(_category);
      expect((result as TrainingSessionReady).questionCount, 40);
      expect(drain().map((q) => q.storageId), [
        'first',
        for (var i = 0; i < 39; i++) 'due-${i.toString().padLeft(2, '0')}'
      ]);
      expect(clockCalls, 1);
      expect(randomCalls, 0);
      expect(trace.transactions, 1);
      expect(engine.replacements, 1);
      expect(
          trace.reads.any((s) =>
              s.contains('training_content') || s.contains('app_settings')),
          isFalse);
      expect(await snapshot(), before);
    });
  }

  test(
      'Category empty leaves queue, and injected clock/RNG/open failures are safe',
      () async {
    expect(await service.startCategoryReview(_category),
        isA<TrainingSessionEmpty>());
    unchangedQueue();
    engine.real.initPreparedStudySession(sentinel);
    final broken = DefaultTrainingSessionApplicationService(
        selection: TrainingQuestionSelection(
            database: () async => throw StateError('synthetic open failure')),
        reviewEngine: engine);
    expect(
        await broken.startNew(
            TrainingContentTarget(contentId: 'missing', expectedRevision: 1)),
        isA<TrainingSessionUnavailable>());
    expect(await broken.startCategoryReview(_category),
        isA<TrainingSessionUnavailable>());
    unchangedQueue();
    for (final kind in ['clock', 'random']) {
      engine.real.initPreparedStudySession(sentinel);
      final throwing = DefaultTrainingSessionApplicationService(
          selection: selection,
          reviewEngine: engine,
          clock: () => throw StateError('synthetic clock failure'),
          randomFactory: () => throw StateError('synthetic random failure'));
      expect(
          kind == 'clock'
              ? await throwing.startCategoryReview(_category)
              : await throwing.startNew(TrainingContentTarget(
                  contentId: 'missing', expectedRevision: 1)),
          isA<TrainingSessionUnavailable>());
      unchangedQueue();
    }
  });
}
