// R7D permanent acceptance: V2-first QuestionList on a real v15 database.
//
// Evidence class: synthetic fixtures only. Every scenario writes and reads a
// file-backed database opened only through the frozen
// DatabaseHelper.openPathForTesting seam and closes/reopens it to prove
// persistence. The QuestionListScreen is pumped with a real repository
// bound to that database. Because widget tests run inside FakeAsync, every
// real database operation is executed inside tester.runAsync and interleaved
// with pumps that flush the fake microtask queue. There is no real
// application database, private PDF, OCR, Replay, Provider, network, or
// application call site; Provider calls are 0 by construction.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'r7d_synthetic_bank';
const _typedStorageId = '11111111-2222-4333-8444-555555555555';
const _legacyStorageId = '22222222-3333-4444-8555-666666666666';

/// File-backed DatabaseHelper seam: repository APIs run against a real
/// database opened through the frozen openPathForTesting seam.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }

  @override
  Future<void> deleteSingleQuestion(String questionId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM review_logs WHERE question_id = ?',
        <Object?>[questionId],
      );
      await txn.rawDelete(
        'DELETE FROM review_states WHERE question_id = ?',
        <Object?>[questionId],
      );
      await txn.rawDelete(
        'DELETE FROM questions WHERE id = ?',
        <Object?>[questionId],
      );
    });
  }
}

/// Real repository implementation with call counters proving the screen only
/// uses the V2-first union read.
class _CountingRepository extends QuestionRepository {
  _CountingRepository({required DatabaseHelper databaseHelper})
      : super(databaseHelper: databaseHelper);

  int persistedReadCalls = 0;
  final List<String> deletedIds = <String>[];

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    persistedReadCalls++;
    return super.getPersistedQuestionsByBank(bankName);
  }

  @override
  Future<void> deleteQuestion(String id) async {
    deletedIds.add(id);
    return super.deleteQuestion(id);
  }
}

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

Future<void> _insertTyped(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  int createdAt = 1700000002,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await _insertReviewState(db, storageId);
}

Future<void> _insertLegacy(
  Database db, {
  required String id,
  int createdAt = 1700000001,
  String content = 'Legacy stem text.',
  int type = 0,
  String options = '["A. legacy one","B. legacy two"]',
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': 'A|||Legacy explanation.',
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': createdAt,
    'bank_name': _bankName,
  });
  await _insertReviewState(db, id);
}

Future<void> _insertReviewState(Database db, String questionId) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': 0,
    'next_review_time': 0,
    'lapses': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': 0,
    'last_review_time': 0,
  });
}

QuestionDraftV2 _mixedTypedDraft() {
  return QuestionDraftV2(
    questionId: 'r7d_mixed_001',
    kind: QuestionKind.singleChoice,
    stem: RichContent(nodes: const <ContentNode>[
      TextNode('Typed stem text.'),
      BlockMathNode(r'\int_0^1 x\,dx'),
      TextNode(' After '),
      InlineMathNode(r'x^2'),
      TextNode(' math.'),
    ]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: 'A',
        content: _text('Typed option one'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: 'B',
        content: _text('Typed option two'),
      ),
    ],
    answer: ChoiceAnswer(optionIds: <String>['opt_a']),
    explanation: _text('Typed explanation.'),
  );
}

/// Runs one real-async database chunk: the FakeAsync widget-test zone cannot
/// drive file I/O, so every database touch must run inside the real zone.
Future<void> _dbChunk(WidgetTester tester, Future<void> Function() action) {
  return tester.runAsync(action);
}

/// Spins real event-loop time while pumping fake frames so a pending real
/// database read can complete and its continuation microtasks can flush.
Future<void> _spinForDatabase(WidgetTester tester, {int iterations = 80}) {
  return tester.runAsync(() async {
    for (var i = 0; i < iterations; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  QuestionRepository repository, {
  ValueChanged<int?>? onLoadFinished,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
          onLoadFinished: onLoadFinished,
        ),
      ),
    );
  });
  await _spinForDatabase(tester);
  await tester.pumpAndSettle();
}

/// Enlarges the test viewport so a lazy ListView builds both cards of the
/// mixed bank instead of leaving the second one unbuilt/offstage.
void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('r7d_acceptance_');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
        break;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets(
      '24.1: mixed bank survives close/reopen and renders both renderers',
      (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7d_mixed.db');
    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final firstDb = await first.database;
      await _insertTyped(
        firstDb,
        _mixedTypedDraft(),
        storageId: _typedStorageId,
      );
      await _insertLegacy(firstDb, id: _legacyStorageId);
      await first.close();
    });

    int? lastCount = -1;
    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(
      databaseHelper: helper,
    );
    await _pumpScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(lastCount, 2);
    expect(repository.persistedReadCalls, 1);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('Typed stem text.'), findsOneWidget);
    expect(find.text('Typed option one'), findsOneWidget);
    expect(find.text('Typed option two'), findsOneWidget);
    expect(find.text('Legacy stem text.'), findsOneWidget);
    expect(find.byType(RichContentRenderer), findsWidgets);
    expect(find.byType(StructuredContentRenderer), findsWidgets);
    expect(find.byType(Math), findsWidgets);
    expect(find.text('Typed explanation.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final typedCard = find.ancestor(
      of: find.text('结构化'),
      matching: find.byType(PersistedQuestionCard),
    );
    final typedEdit = tester.widget<TextButton>(
      find.descendant(
        of: typedCard,
        matching: find.widgetWithText(TextButton, '编辑题目'),
      ),
    );
    expect(typedEdit.onPressed, isNull);

    final legacyCard = find.ancestor(
      of: find.text('Legacy stem text.'),
      matching: find.byType(PersistedQuestionCard),
    );
    final legacyEdit = tester.widget<TextButton>(
      find.descendant(
        of: legacyCard,
        matching: find.widgetWithText(TextButton, '编辑题目'),
      ),
    );
    expect(legacyEdit.onPressed, isNotNull);

    await _dbChunk(tester, () async {
      final reopened = _FileDatabaseHelper(path);
      final reopenedDb = await reopened.database;
      final version = await reopenedDb.rawQuery('PRAGMA user_version');
      expect(version.single['user_version'], 20);
      expect(await reopenedDb.query('questions'), hasLength(2));
      expect(await reopenedDb.query('question_v2_payloads'), hasLength(1));
      await reopened.close();
    });
    await _dbChunk(tester, helper.close);
  });

  testWidgets('24.2: explicit typed empty stem never falls back to 无题干',
      (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7d_empty_stem.db');
    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final firstDb = await first.database;
      await _insertTyped(
        firstDb,
        QuestionDraftV2(
          questionId: 'r7d_empty_001',
          kind: QuestionKind.singleChoice,
          stem: RichContent(nodes: const <ContentNode>[]),
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: _text('Option for empty stem'),
            ),
          ],
          answer: ChoiceAnswer(optionIds: <String>['opt_a']),
        ),
        storageId: _typedStorageId,
      );
      await first.close();
    });

    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(databaseHelper: helper);
    await _pumpScreen(tester, repository);

    expect(find.byType(PersistedQuestionCard), findsOneWidget);
    expect(find.text('无题干'), findsNothing);
    expect(find.text('Option for empty stem'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });

  testWidgets('24.3: fillBlank typed options remain visible', (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7d_cross_kind.db');
    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final firstDb = await first.database;
      await _insertTyped(
        firstDb,
        QuestionDraftV2(
          questionId: 'r7d_fill_001',
          kind: QuestionKind.fillBlank,
          stem: _text('Fill in the blank stem.'),
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: _text('Fill option one'),
            ),
            QuestionOption(
              optionId: 'opt_b',
              label: 'B',
              content: _text('Fill option two'),
            ),
          ],
          answer: ContentAnswer(content: _text('computed result')),
        ),
        storageId: _typedStorageId,
      );
      await first.close();
    });

    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(databaseHelper: helper);
    await _pumpScreen(tester, repository);

    expect(find.text('Fill option one'), findsOneWidget);
    expect(find.text('Fill option two'), findsOneWidget);
    expect(find.text('computed result'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });

  testWidgets('24.4: typed delete cascades sidecar and review state',
      (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7d_delete_cascade.db');
    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final firstDb = await first.database;
      await _insertTyped(
        firstDb,
        _mixedTypedDraft(),
        storageId: _typedStorageId,
      );
      await _insertLegacy(firstDb, id: _legacyStorageId);
      await first.close();
    });

    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(databaseHelper: helper);
    await _pumpScreen(tester, repository);

    final typedCard = find.ancestor(
      of: find.text('结构化'),
      matching: find.byType(PersistedQuestionCard),
    );
    await tester.tap(
      find.descendant(
        of: typedCard,
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
    await tester.pump();
    await _spinForDatabase(tester);
    await tester.pumpAndSettle();

    expect(repository.deletedIds, <String>[_typedStorageId]);
    expect(repository.persistedReadCalls, 2);
    expect(find.byType(PersistedQuestionCard), findsOneWidget);
    expect(find.text('Legacy stem text.'), findsOneWidget);

    await _dbChunk(tester, () async {
      final reopened = _FileDatabaseHelper(path);
      final reopenedDb = await reopened.database;
      expect(await reopenedDb.query('questions'), hasLength(1));
      expect(
        (await reopenedDb.query('questions')).single['id'],
        _legacyStorageId,
      );
      expect(await reopenedDb.query('question_v2_payloads'), isEmpty);
      expect(await reopenedDb.query('review_states'), hasLength(1));
      expect(
        (await reopenedDb.query('review_states')).single['question_id'],
        _legacyStorageId,
      );
      await reopened.close();
    });
    await _dbChunk(tester, helper.close);
  });

  testWidgets(
      '24.5: corrupt sidecar fails the whole page with a fixed safe error',
      (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7d_corrupt_sidecar.db');
    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final firstDb = await first.database;
      await _insertTyped(
        firstDb,
        _mixedTypedDraft(),
        storageId: _typedStorageId,
      );
      await _insertLegacy(firstDb, id: _legacyStorageId);
      await firstDb.update(
        'question_v2_payloads',
        <String, Object?>{'payload_json': '{corrupt'},
        where: 'question_id = ?',
        whereArgs: <Object?>[_typedStorageId],
      );
      await first.close();
    });

    int? lastCount = -1;
    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(
      databaseHelper: helper,
    );
    await _pumpScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(find.text('题库中存在无法安全读取的题目，请重试或修复数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(lastCount, isNull);
    expect(find.byType(PersistedQuestionCard), findsNothing);
    expect(find.text('Legacy stem text.'), findsNothing);
    expect(find.text('Typed stem text.'), findsNothing);
    expect(find.textContaining('corrupt'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(repository.persistedReadCalls, 1);
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });
}
