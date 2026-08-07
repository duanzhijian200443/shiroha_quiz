// R8F permanent acceptance: legacy retirement contracts across QuestionList,
// Practice, and WrongBook.
//
// Evidence class: fully synthetic and offline. Every scenario seeds a real
// SQLite v15 database (sqflite FFI, production schema callbacks). File-backed
// scenarios use the frozen DatabaseHelper.openPathForTesting seam and
// close/reopen the file to prove persistence; widget scenarios pump the real
// production pages. The non-injectable Practice session read is additionally
// proven on a real file database through the exact production repository
// method, while PracticePage rendering runs against the production singleton
// path (the same read contract, in-memory under FLUTTER_TEST). There is no
// real application database, private PDF, OCR, Replay, Provider, or network;
// Provider calls are 0 by construction.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/review_engine_service.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/pages/practice_page.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/pages/wrong_book_page.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'r8f_synthetic_bank';
const _typedStorageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a01';
const _typedStorageIdB = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a02';
const _typedStorageIdC = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a03';
const _legacyStorageId = 'legacy_1';

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
}

/// Same file-backed seam, but every legacy raw-map read records a call and
/// throws. Scenario E asserts the counters stay at zero, proving the
/// consumers never route through the retired DatabaseHelper question reads.
class _LegacyReadSpyDatabaseHelper extends _FileDatabaseHelper {
  _LegacyReadSpyDatabaseHelper(super.path);

  int legacyQuestionReadCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getQuestionsByBank(String bankName) async {
    legacyQuestionReadCalls++;
    throw StateError('retired legacy read must not be used');
  }

  @override
  Future<List<Map<String, dynamic>>> searchQuestions(
    String bankName,
    String keyword,
  ) async {
    legacyQuestionReadCalls++;
    throw StateError('retired legacy read must not be used');
  }
}

/// Real repository with call counters proving the screens use only the
/// typed-aware union reads.
class _CountingQuestionRepository extends QuestionRepository {
  _CountingQuestionRepository({required DatabaseHelper databaseHelper})
      : super(databaseHelper: databaseHelper);

  int persistedReadCalls = 0;
  int wrongReadCalls = 0;

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    persistedReadCalls++;
    return super.getPersistedQuestionsByBank(bankName);
  }

  @override
  Future<List<PersistedQuestion>> getPersistedWrongQuestions() async {
    wrongReadCalls++;
    return super.getPersistedWrongQuestions();
  }
}

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({
  required String questionId,
  String stem = 'Typed stem marker.',
  QuestionAnswer? answer,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.singleChoice,
    stem: _text(stem),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: 'A',
        content: _text('first'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: 'B',
        content: _text('second'),
      ),
    ],
    answer: answer ?? ChoiceAnswer(optionIds: <String>['opt_a']),
    explanation: explanation,
  );
}

Future<void> _insertTyped(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  String bank = _bankName,
  int createdAt = 1,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: bank,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> _insertLegacy(
  Database db, {
  required String id,
  String bank = _bankName,
  int type = 0,
  String content = 'Legacy stem.',
  String options = '["A. first", "B. second"]',
  String answer = 'A',
  String? explanation,
  int createdAt = 1,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': '$answer|||${explanation ?? ''}',
    'created_at': createdAt,
    'bank_name': bank,
    'explanation': explanation,
    'raw_explanation': null,
  });
}

Future<void> _insertReviewState(
  Database db,
  String questionId, {
  int state = 0,
  int nextReviewTime = 0,
  int lapses = 0,
  int lastLapseTime = 0,
  double difficulty = 5.0,
  double stability = 0.0,
}) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': state,
    'difficulty': difficulty,
    'stability': stability,
    'last_review_time': 0,
    'next_review_time': nextReviewTime,
    'reps': 0,
    'lapses': lapses,
    'last_lapse_time': lastLapseTime,
  });
}

/// Plants a deliberately wrong V1 compatibility projection under a typed
/// row. If any consumer ever fell back to the compatibility row, the decoy
/// text would surface and fail the test.
Future<void> _plantDecoy(Database db, String storageId) async {
  await db.update(
    'questions',
    <String, Object?>{
      'content': 'V1_DECOY_STEM',
      'options': '["V1_DECOY_OPTION"]',
      'standard_answer': 'Z|||V1_DECOY_ANSWER',
    },
    where: 'id = ?',
    whereArgs: <Object?>[storageId],
  );
}

Future<void> _assertV15(Database db) async {
  final version = await db.rawQuery('PRAGMA user_version');
  expect(version.single['user_version'], 15);
}

/// Runs one real-async database chunk: the FakeAsync widget-test zone cannot
/// drive file I/O, so every database touch must run inside the real zone.
Future<void> _dbChunk(WidgetTester tester, Future<void> Function() action) {
  return tester.runAsync(action);
}

/// Spins real event-loop time while pumping fake frames so pending real
/// database reads complete and their continuation microtasks flush.
Future<void> _spinForDatabase(WidgetTester tester, {int iterations = 80}) {
  return tester.runAsync(() async {
    for (var i = 0; i < iterations; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
}

Future<void> _pumpScreen(WidgetTester tester, Widget home) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(home: home));
  });
  await _spinForDatabase(tester);
  await tester.pumpAndSettle();
}

/// Enlarges the test viewport so a lazy ListView builds every card instead of
/// leaving later ones unbuilt/offstage.
void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpPracticeUntilLoaded(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(home: PracticePage(bankName: _bankName)),
  );
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  fail('PracticePage did not finish loading.');
}

Future<void> _settlePractice(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('r8f_acceptance_');
  });

  setUp(() => DatabaseHelper.deleteDatabaseFile());

  tearDown(() async {
    await DatabaseHelper.deleteDatabaseFile();
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
      'A: practice mixed bank uses the sidecar, ignores the decoy, and '
      'renders legacy through the legacy path', (tester) async {
    // File phase: the exact production session read, bound to a real SQLite
    // v15 file database, returns the union with sidecar authority and the
    // historical legacy row. The file is closed and reopened to prove the
    // seeded rows are persisted, not held in memory.
    final path = p.join(tempDir.path, 'case_a.db');
    final seedHelper = _FileDatabaseHelper(path);
    await _dbChunk(tester, () async {
      final db = await seedHelper.database;
      await _insertTyped(
        db,
        _choiceDraft(
          questionId: 'typed_a_question',
          explanation: _text('Typed explanation marker.'),
        ),
        storageId: _typedStorageIdA,
      );
      await _insertLegacy(db, id: _legacyStorageId);
      await _insertReviewState(
        db,
        _typedStorageIdA,
        state: 2,
        nextReviewTime: 50,
      );
      await _insertReviewState(
        db,
        _legacyStorageId,
        state: 2,
        nextReviewTime: 100,
      );
      await _plantDecoy(db, _typedStorageIdA);
      await _assertV15(db);
    });
    await _dbChunk(tester, seedHelper.close);

    final readHelper = _FileDatabaseHelper(path);
    final rows = await tester.runAsync(
      () => ReviewRepository(databaseHelper: readHelper)
          .getPersistedStudySessionQuestions(_bankName, 9999999999),
    );
    expect(rows, isNotNull);
    expect(rows, hasLength(2));
    expect(rows!.first, isA<TypedPersistedQuestion>());
    final typedRow = rows.first as TypedPersistedQuestion;
    expect(
      (typedRow.draft.stem.nodes.single as TextNode).text,
      'Typed stem marker.',
    );
    expect(
      (typedRow.draft.options.first.content.nodes.single as TextNode).text,
      'first',
    );
    expect(rows.last, isA<LegacyPersistedQuestion>());
    expect(
      (rows.last as LegacyPersistedQuestion).question.content,
      'Legacy stem.',
    );
    await _dbChunk(tester, readHelper.close);

    // Widget phase: the production PracticePage path over the same seeded
    // content renders the sidecar, never the decoy, and routes the legacy
    // row through the legacy renderer.
    await _dbChunk(tester, () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        _choiceDraft(
          questionId: 'typed_a_question',
          explanation: _text('Typed explanation marker.'),
        ),
        storageId: _typedStorageIdA,
      );
      await _insertLegacy(db, id: _legacyStorageId);
      await _insertReviewState(
        db,
        _typedStorageIdA,
        state: 2,
        nextReviewTime: 50,
      );
      await _insertReviewState(
        db,
        _legacyStorageId,
        state: 2,
        nextReviewTime: 100,
      );
      await _plantDecoy(db, _typedStorageIdA);
      await _assertV15(db);
    });

    await _pumpPracticeUntilLoaded(tester);

    // First question is the typed row: sidecar content only, RichContent
    // path active, decoy and legacy renderer absent.
    expect(find.text('Typed stem marker.'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
    expect(find.textContaining('V1_DECOY'), findsNothing);
    expect(find.byType(RichContentRenderer), findsWidgets);
    expect(find.byType(StructuredContentRenderer), findsNothing);

    await tester.tap(find.text('first'));
    await tester.tap(find.text('查看答案'));
    await _settlePractice(tester);
    expect(find.text('Typed explanation marker.'), findsOneWidget);
    expect(find.textContaining('V1_DECOY'), findsNothing);

    // Advance to the second question: the legacy row renders through the
    // legacy path with its own V1 content.
    await tester.tap(find.text('极易'));
    await _settlePractice(tester);
    expect(find.text('Legacy stem.'), findsOneWidget);
    expect(find.byType(StructuredContentRenderer), findsWidgets);
    expect(find.byType(RichContentRenderer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'B: wrong book shows only lapsed rows with sidecar authority, '
      'metrics, and last_lapse_time DESC order', (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'case_b.db');
    final helper = _FileDatabaseHelper(path);
    final repository = _CountingQuestionRepository(databaseHelper: helper);
    await _dbChunk(tester, () async {
      final db = await helper.database;
      await _insertTyped(
        db,
        _choiceDraft(
          questionId: 'typed_b_question',
          stem: 'Typed sidecar stem.',
        ),
        storageId: _typedStorageIdB,
      );
      await _insertLegacy(
        db,
        id: _legacyStorageId,
        content: 'Legacy lapsed content.',
      );
      await _insertLegacy(
        db,
        id: 'legacy_control',
        content: 'Non-lapsed control marker.',
      );
      await _insertReviewState(
        db,
        _typedStorageIdB,
        lapses: 2,
        lastLapseTime: 300,
        difficulty: 6.5,
        stability: 3.2,
      );
      await _insertReviewState(
        db,
        _legacyStorageId,
        lapses: 1,
        lastLapseTime: 100,
      );
      await _insertReviewState(db, 'legacy_control', lapses: 0);
      await _plantDecoy(db, _typedStorageIdB);
      await _assertV15(db);
    });

    await _pumpScreen(
      tester,
      WrongBookPage(questionRepository: repository),
    );

    expect(repository.wrongReadCalls, 1);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('Typed sidecar stem.'), findsOneWidget);
    expect(find.text('Legacy lapsed content.'), findsOneWidget);
    expect(find.text('Non-lapsed control marker.'), findsNothing);
    expect(find.textContaining('V1_DECOY'), findsNothing);
    expect(find.text('错误次数：2'), findsOneWidget);
    expect(find.text('难度系数：6.50'), findsOneWidget);
    expect(find.text('稳定性：3.20'), findsOneWidget);
    expect(find.text('错误次数：1'), findsOneWidget);

    final typedY = tester.getTopLeft(find.text('Typed sidecar stem.')).dy;
    final legacyY = tester.getTopLeft(find.text('Legacy lapsed content.')).dy;
    expect(typedY, lessThan(legacyY));
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });

  testWidgets(
      'C: typed explicit empty answer/explanation never falls back to V1 '
      'on the practice production path', (tester) async {
    await _dbChunk(tester, () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        QuestionDraftV2(
          questionId: 'typed_c_question',
          kind: QuestionKind.shortAnswer,
          stem: RichContent(nodes: const <ContentNode>[]),
        ),
        storageId: _typedStorageIdC,
      );
      await _insertReviewState(db, _typedStorageIdC);
      // V1 decoy: the compatibility row claims a placeholder stem and a
      // wrong answer/explanation.
      await db.update(
        'questions',
        <String, Object?>{
          'content': '无题干',
          'standard_answer': 'Z|||V1 decoy answer',
        },
        where: 'id = ?',
        whereArgs: <Object?>[_typedStorageIdC],
      );
      await _assertV15(db);
    });

    await _pumpPracticeUntilLoaded(tester);
    expect(find.text('无题干'), findsNothing);
    expect(find.textContaining('V1 decoy'), findsNothing);

    await tester.tap(find.text('跳过 AI，直接看答案自评'));
    await _settlePractice(tester);

    expect(find.text('无'), findsOneWidget);
    expect(find.text('无解析'), findsOneWidget);
    expect(find.textContaining('V1 decoy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
      'D: legacy content mutations are blocked for typed rows and still '
      'work for legacy rows', () async {
    final db = await DatabaseHelper.instance.database;
    await _insertTyped(
      db,
      _choiceDraft(
        questionId: 'typed_d_question',
        explanation: _text('Typed explanation marker.'),
      ),
      storageId: _typedStorageIdA,
    );
    await _insertLegacy(db, id: _legacyStorageId);
    await _insertReviewState(db, _typedStorageIdA);
    await _insertReviewState(db, _legacyStorageId);
    await _assertV15(db);

    final sidecarBefore = (await db.query(
      'question_v2_payloads',
      where: 'question_id = ?',
      whereArgs: <Object?>[_typedStorageIdA],
    ))
        .single;
    final compatBefore = (await db.query(
      'questions',
      where: 'id = ?',
      whereArgs: <Object?>[_typedStorageIdA],
    ))
        .single;

    // Representative legacy content mutations aimed at a typed storage id
    // must be blocked/skipped with zero side effects.
    await expectLater(
      DatabaseHelper.instance.updateQuestion(<String, dynamic>{
        'id': _typedStorageIdA,
        'content': 'HACKED',
        'options': '[]',
        'standard_answer': 'H|||H',
      }),
      throwsA(isA<QuestionV2LegacyMutationBlockedException>()),
    );
    await expectLater(
      QuestionRepository.instance.savePreviewQuestion(<String, dynamic>{
        'id': 'preview_$_typedStorageIdA',
        'type': 0,
        'content': 'HACKED',
        'options': '[]',
        'standard_answer': 'H',
        'bank_name': _bankName,
      }),
      throwsA(isA<QuestionV2LegacyMutationBlockedException>()),
    );

    final sidecarAfter = (await db.query(
      'question_v2_payloads',
      where: 'question_id = ?',
      whereArgs: <Object?>[_typedStorageIdA],
    ))
        .single;
    final compatAfter = (await db.query(
      'questions',
      where: 'id = ?',
      whereArgs: <Object?>[_typedStorageIdA],
    ))
        .single;
    expect(sidecarAfter['payload_json'], sidecarBefore['payload_json']);
    expect(compatAfter['content'], compatBefore['content']);
    expect(compatAfter['standard_answer'], compatBefore['standard_answer']);

    final rows = await QuestionRepository.instance
        .getPersistedQuestionsByBank(_bankName);
    final typed = rows.whereType<TypedPersistedQuestion>().single;
    expect(
      (typed.draft.stem.nodes.single as TextNode).text,
      'Typed stem marker.',
    );
    expect(typed.draft.explanation, isNotNull);

    // A legacy row mutation still works through the same API.
    await DatabaseHelper.instance.updateQuestion(<String, dynamic>{
      'id': _legacyStorageId,
      'type': 0,
      'content': 'Legacy edited.',
      'options': '["A. first", "B. second"]',
      'standard_answer': 'A|||Legacy explanation.',
      'created_at': 1,
      'bank_name': _bankName,
    });
    final legacyRows = await QuestionRepository.instance
        .getPersistedQuestionsByBank(_bankName);
    final legacy = legacyRows.whereType<LegacyPersistedQuestion>().single;
    expect(legacy.question.content, 'Legacy edited.');
    await DatabaseHelper.deleteDatabaseFile();
  });

  testWidgets('E: consumers read only through typed-aware repository APIs',
      (tester) async {
    // Architecture boundary probe: the three pages and the practice session
    // scheduler never reference the retired raw-map APIs, DatabaseHelper, or
    // raw SQL. The retired names are gone from the repositories, so a
    // reference anywhere in these consumers would be a compile/runtime
    // contract violation.
    final consumerFiles = <String>[
      'lib/ui/pages/practice_page.dart',
      'lib/ui/pages/wrong_book_page.dart',
      'lib/ui/pages/question_list_screen.dart',
      'lib/core/review_engine_service.dart',
    ];
    final retiredPatterns = <RegExp>[
      RegExp(r'\bgetQuestionsByBank\b'),
      RegExp(r'\bsearchQuestions\b'),
      RegExp(r'\bgetDetailedWrongQuestions\b'),
      RegExp(r'\bgetStudySessionQuestions\b'),
      RegExp(r'\bgetWrongBookEntries\b'),
      RegExp(r'\bDatabaseHelper\b'),
      RegExp(r'\brawQuery\s*\('),
      RegExp(r'package:sqflite'),
    ];
    final violations = <String>[];
    for (final file in consumerFiles) {
      final lines = File(file).readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        for (final pattern in retiredPatterns) {
          if (pattern.hasMatch(lines[index])) {
            violations.add('$file:${index + 1}: ${lines[index].trim()}');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'Retired read surface referenced by a consumer:\n'
          '${violations.join('\n')}',
    );

    // QuestionList: counting repository over a real file DB; the injected
    // DatabaseHelper spy proves no legacy raw-map read is ever attempted.
    _setTallViewport(tester);
    final listPath = p.join(tempDir.path, 'case_e_list.db');
    final listSpy = _LegacyReadSpyDatabaseHelper(listPath);
    final listRepository = _CountingQuestionRepository(databaseHelper: listSpy);
    int? listCount = -1;
    await _dbChunk(tester, () async {
      final db = await listSpy.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'typed_e_list_question'),
        storageId: _typedStorageIdA,
      );
      await _insertLegacy(db, id: _legacyStorageId);
      await _insertReviewState(db, _typedStorageIdA);
      await _insertReviewState(db, _legacyStorageId);
      await _assertV15(db);
    });
    await _pumpScreen(
      tester,
      QuestionListScreen(
        bankName: _bankName,
        questionRepository: listRepository,
        onLoadFinished: (count) => listCount = count,
      ),
    );
    expect(listCount, 2);
    expect(listRepository.persistedReadCalls, 1);
    expect(listSpy.legacyQuestionReadCalls, 0);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('Typed stem marker.'), findsOneWidget);
    expect(find.text('Legacy stem.'), findsOneWidget);

    // WrongBook: the same spy pattern on the wrong-book read.
    final wrongPath = p.join(tempDir.path, 'case_e_wrong.db');
    final wrongSpy = _LegacyReadSpyDatabaseHelper(wrongPath);
    final wrongRepository =
        _CountingQuestionRepository(databaseHelper: wrongSpy);
    await _dbChunk(tester, () async {
      final db = await wrongSpy.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'typed_e_wrong_question'),
        storageId: _typedStorageIdB,
      );
      await _insertLegacy(
        db,
        id: _legacyStorageId,
        content: 'Legacy lapsed content.',
      );
      await _insertReviewState(db, _typedStorageIdB, lapses: 1);
      await _insertReviewState(db, _legacyStorageId, lapses: 1);
      await _assertV15(db);
    });
    await _pumpScreen(
      tester,
      WrongBookPage(questionRepository: wrongRepository),
    );
    expect(wrongRepository.wrongReadCalls, 1);
    expect(wrongSpy.legacyQuestionReadCalls, 0);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));

    // Practice: the production session scheduler reads the union through
    // ReviewRepository.getPersistedStudySessionQuestions on the file-backed
    // singleton database.
    await _dbChunk(tester, () async {
      final db = await DatabaseHelper.instance.database;
      await _insertTyped(
        db,
        _choiceDraft(questionId: 'typed_e_practice_question'),
        storageId: _typedStorageIdC,
      );
      await _insertLegacy(db, id: _legacyStorageId);
      await _insertReviewState(db, _typedStorageIdC);
      await _insertReviewState(db, _legacyStorageId);
      await _assertV15(db);
    });
    await _dbChunk(
      tester,
      () => ReviewEngineService()
          .initStudySession(_bankName, type: null, limit: 40),
    );
    final seen = <String, PersistedQuestion>{};
    while (true) {
      final next = ReviewEngineService().popNextQuestion();
      if (next == null) break;
      seen[next.storageId] = next;
    }
    expect(
      seen.keys.toSet(),
      containsAll(<String>{_typedStorageIdC, _legacyStorageId}),
    );
    expect(seen[_typedStorageIdC], isA<TypedPersistedQuestion>());
    expect(seen[_legacyStorageId], isA<LegacyPersistedQuestion>());
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, listSpy.close);
    await _dbChunk(tester, wrongSpy.close);
  });

  testWidgets('F: historical legacy rows remain usable in all three consumers',
      (tester) async {
    // Practice: a legacy-only bank still loads through the production
    // session path and renders with the legacy renderer.
    await _dbChunk(tester, () async {
      final db = await DatabaseHelper.instance.database;
      await _insertLegacy(
        db,
        id: _legacyStorageId,
        content: 'Legacy practice stem.',
        explanation: 'Legacy practice explanation.',
      );
      await _insertReviewState(db, _legacyStorageId);
      await _assertV15(db);
    });
    await _pumpPracticeUntilLoaded(tester);
    expect(find.text('Legacy practice stem.'), findsOneWidget);
    expect(find.byType(StructuredContentRenderer), findsWidgets);
    expect(find.byType(RichContentRenderer), findsNothing);
    await tester.tap(find.text('first'));
    await tester.tap(find.text('查看答案'));
    await _settlePractice(tester);
    expect(find.text('正确答案: A'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // QuestionList + WrongBook share one file-backed legacy bank; both
    // consumers keep working, including the legacy editor entry.
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'case_f_list.db');
    final helper = _FileDatabaseHelper(path);
    await _dbChunk(tester, () async {
      final db = await helper.database;
      await _insertLegacy(
        db,
        id: _legacyStorageId,
        content: 'Historical legacy row A.',
      );
      await _insertLegacy(
        db,
        id: 'legacy_row_b',
        content: 'Historical legacy row B.',
      );
      await _insertReviewState(db, _legacyStorageId, lapses: 3);
      await _insertReviewState(db, 'legacy_row_b', lapses: 0);
      await _assertV15(db);
    });

    final listRepository = _CountingQuestionRepository(
      databaseHelper: helper,
    );
    await _pumpScreen(
      tester,
      QuestionListScreen(
        bankName: _bankName,
        questionRepository: listRepository,
      ),
    );
    expect(find.text('Historical legacy row A.'), findsOneWidget);
    expect(find.text('Historical legacy row B.'), findsOneWidget);
    expect(find.byType(StructuredContentRenderer), findsWidgets);
    final listEdit = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '编辑题目').first,
    );
    expect(listEdit.onPressed, isNotNull);

    final wrongRepository = _CountingQuestionRepository(
      databaseHelper: helper,
    );
    await _pumpScreen(
      tester,
      WrongBookPage(questionRepository: wrongRepository),
    );
    expect(find.text('Historical legacy row A.'), findsOneWidget);
    expect(find.text('Historical legacy row B.'), findsNothing);
    final wrongEdit = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '编辑题目').first,
    );
    expect(wrongEdit.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });
}
