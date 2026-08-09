// P5.2 widget acceptance: the typed manual answer repair UI on real v15
// databases through the frozen DatabaseHelper.openPathForTesting seam
// (r7d-style repository/file seam) plus tester.runAsync. Synthetic sqflite
// FFI only; no real database, OCR, Provider, Replay, network, private PDF,
// or external fixture is touched.
import 'dart:convert';
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
import 'package:shiroha_quiz/ui/models/practice_question_view.dart';
import 'package:shiroha_quiz/ui/pages/question_edit_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/pages/typed_answer_repair_screen.dart';
import 'package:shiroha_quiz/ui/pages/wrong_book_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'p5_ui_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'p5_ui_choice_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('Choice stem.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: '甲',
        content: _text('first'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: '乙',
        content: _text('second'),
      ),
      QuestionOption(
        optionId: 'opt_c',
        label: '丙',
        content: _text('third'),
      ),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _contentDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'p5_ui_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: _text('Content stem.'),
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _singleOptionChoiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'p5_ui_single_option_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 3,
    stem: _text('Single-option choice stem.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: '甲',
        content: _text('first'),
      ),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _twoOptionChoiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'p5_ui_two_option_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 4,
    stem: _text('Two-option choice stem.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'opt_a',
        label: '甲',
        content: _text('first'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: '乙',
        content: _text('second'),
      ),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

/// File-backed DatabaseHelper seam: repository APIs run against a real v15
/// database opened only through the frozen openPathForTesting seam.
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

Future<void> _insertTypedRow(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: 1700000001,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 3,
    'difficulty': 2.5,
    'stability': 9.5,
    'reps': 7,
    'lapses': 4,
    'last_review_time': 1700001001,
    'next_review_time': 1700002001,
    'last_lapse_time': 1700000501,
  });
}

Future<void> _insertLegacyRow(Database db, {required String id}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'Legacy stem text.',
    'options': '[]',
    'standard_answer': 'Legacy answer|||Legacy explanation.',
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': 1700000000,
    'bank_name': _bankName,
  });
}

Future<TypedPersistedQuestion> _reloadTyped(
  Database db,
  String storageId,
) async {
  final rows = await db.rawQuery(
    '''
    SELECT q.*,
           p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
           p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
    FROM questions q
    LEFT JOIN question_v2_payloads p ON q.id = p.question_id
    WHERE q.id = ?
    ''',
    <Object?>[storageId],
  );
  expect(rows, hasLength(1));
  final decoded = _mapper.decodeJoinedRow(rows.single);
  expect(decoded, isA<TypedPersistedQuestion>());
  return decoded as TypedPersistedQuestion;
}

Future<String> _standardAnswer(Database db, String storageId) async {
  final rows = await db.query(
    'questions',
    columns: <String>['standard_answer'],
    where: 'id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['standard_answer']! as String;
}

Future<String> _payloadJson(Database db, String storageId) async {
  final rows = await db.query(
    'question_v2_payloads',
    columns: <String>['payload_json'],
    where: 'question_id = ?',
    whereArgs: <Object?>[storageId],
  );
  return rows.single['payload_json']! as String;
}

Future<int> _userVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return rows.single['user_version'] as int;
}

/// Bounded pump loop for real-async widget flows (the frozen R8A pattern):
/// frames advance and real repository futures complete inside runAsync.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 200,
  String? reason,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    // Elapse fake time so route transitions and controllers progress while
    // the loop also yields to the real event loop for repository futures.
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $finder${reason == null ? '' : ': $reason'}');
}

/// Bounded pump loop until [finder] disappears (route pop plus reload).
Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 200,
  String? reason,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail(
    'Timed out waiting for $finder to disappear'
    '${reason == null ? '' : ': $reason'}',
  );
}

/// Scopes a finder to the repair screen so the covered list route can never
/// produce ambiguous matches during route transitions.
Finder _inRepair(Finder matching) => find.descendant(
      of: find.byType(TypedAnswerRepairScreen),
      matching: matching,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final openHelpers = <_FileDatabaseHelper>[];
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('p5_ui_acceptance_');
  });

  tearDown(() async {
    for (final helper in openHelpers) {
      await helper.close();
    }
    openHelpers.clear();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  _FileDatabaseHelper newFileHelper(String name) {
    final helper = _FileDatabaseHelper(p.join(tempDir.path, name));
    openHelpers.add(helper);
    return helper;
  }

  Future<Database> openDb(
    WidgetTester tester,
    _FileDatabaseHelper helper,
  ) async =>
      (await tester.runAsync(() => helper.database))!;

  Future<String> readPayloadJson(WidgetTester tester, Database db) async =>
      (await tester.runAsync(() => _payloadJson(db, _storageId)))!;

  Future<String> readStandardAnswer(WidgetTester tester, Database db) async =>
      (await tester.runAsync(() => _standardAnswer(db, _storageId)))!;

  Future<int> readUserVersion(WidgetTester tester, Database db) async =>
      (await tester.runAsync(() => _userVersion(db)))!;

  Future<void> openRepairFromPrompt(WidgetTester tester) async {
    await tester.tap(find.text('暂无答案，点击手动补充'));
    await _pumpUntilFound(
      tester,
      find.byType(TypedAnswerRepairScreen),
      reason: 'repair screen did not open from the empty prompt',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> openRepairFromButton(WidgetTester tester) async {
    await tester.tap(find.text('修正答案'));
    await _pumpUntilFound(
      tester,
      find.byType(TypedAnswerRepairScreen),
      reason: 'repair screen did not open from 修正答案',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> tapSave(WidgetTester tester) async {
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
  }

  testWidgets(
      'QuestionList: null typed answer opens repair, saves a choice, '
      'and reloads the new answer', (tester) async {
    final helper = newFileHelper('p5_ui_list.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.text('暂无答案，点击手动补充'),
      reason: 'list did not render the typed empty-answer prompt',
    );

    await openRepairFromPrompt(tester);

    // Read-only stem and options render; no AI button exists.
    expect(_inRepair(find.text('Choice stem.')), findsOneWidget);
    expect(_inRepair(find.text('first')), findsOneWidget);
    expect(_inRepair(find.text('second')), findsOneWidget);
    expect(_inRepair(find.text('third')), findsOneWidget);
    expect(_inRepair(find.text('AI 解答')), findsNothing);

    final secondOption = _inRepair(find.text('second'));
    await tester.ensureVisible(secondOption);
    await tester.tap(secondOption);
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.text('乙'),
      reason: 'list did not reload the repaired choice answer',
    );
    expect(find.text('修正答案'), findsOneWidget);
    expect(find.text('暂无答案，点击手动补充'), findsNothing);
    expect(tester.takeException(), isNull);

    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_b']));
    final db = await openDb(tester, helper);
    final payload =
        jsonDecode(await readPayloadJson(tester, db)) as Map<String, dynamic>;
    expect(
      (payload['answer'] as Map<String, dynamic>)['optionIds'],
      <String>['opt_b'],
    );
    expect(await readStandardAnswer(tester, db), '乙|||Explanation.');
    expect(await readUserVersion(tester, db), 19);
  });

  testWidgets('WrongBook: typed row follows the same repair flow and reloads',
      (tester) async {
    final helper = newFileHelper('p5_ui_wrong.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: WrongBookPage(questionRepository: repository),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.text('暂无答案，点击手动补充'),
      reason: 'wrong book did not render the typed empty-answer prompt',
    );

    await openRepairFromPrompt(tester);
    final thirdOption = _inRepair(find.text('third'));
    await tester.ensureVisible(thirdOption);
    await tester.tap(thirdOption);
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.text('丙'),
      reason: 'wrong book did not reload the repaired choice answer',
    );
    expect(find.text('修正答案'), findsOneWidget);
    expect(find.byType(TypedAnswerRepairScreen), findsNothing);
    expect(tester.takeException(), isNull);

    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_c']));
  });

  testWidgets(
      'choice identity: UI persists optionIds in draft order, never labels',
      (tester) async {
    final helper = newFileHelper('p5_ui_identity.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('暂无答案，点击手动补充'));
    await openRepairFromPrompt(tester);

    // Click order is third then first; the saved order must follow the
    // draft option order (opt_a, opt_b, opt_c).
    final thirdOption = _inRepair(find.text('third'));
    await tester.ensureVisible(thirdOption);
    await tester.tap(thirdOption);
    await tester.pump();
    final firstOption = _inRepair(find.text('first'));
    await tester.ensureVisible(firstOption);
    await tester.tap(firstOption);
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.text('甲, 丙'),
      reason: 'list did not render the multi-option answer labels',
    );
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(
      typed.draft.answer,
      ChoiceAnswer(optionIds: <String>['opt_a', 'opt_c']),
    );
    final db = await openDb(tester, helper);
    final payload =
        jsonDecode(await readPayloadJson(tester, db)) as Map<String, dynamic>;
    expect(
      (payload['answer'] as Map<String, dynamic>)['optionIds'],
      <String>['opt_a', 'opt_c'],
    );
    // The V1 projection stores labels only; option identities never leak
    // into the compatibility row.
    final standardAnswer = await readStandardAnswer(tester, db);
    expect(standardAnswer, '甲,丙|||Explanation.');
    expect(standardAnswer, isNot(contains('opt_a')));
    expect(standardAnswer, isNot(contains('opt_c')));
  });

  testWidgets(
      'math: \$x^2+1\$ input saves as a typed math node, not a text node',
      (tester) async {
    final helper = newFileHelper('p5_ui_math.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('暂无答案，点击手动补充'));
    await openRepairFromPrompt(tester);

    await tester.enterText(_inRepair(find.byType(TextField)), r'$x^2+1$');
    await tester.pump();
    // Live typed structural preview renders the inline math.
    expect(_inRepair(find.byType(Math)), findsOneWidget);
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.byType(Math),
      reason: 'list did not reload the typed math answer',
    );
    expect(tester.takeException(), isNull);

    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    final answer = typed.draft.answer as ContentAnswer;
    expect(answer.content.nodes, hasLength(1));
    final node = answer.content.nodes.single;
    expect(node, isA<InlineMathNode>());
    expect((node as InlineMathNode).latex, 'x^2+1');
    expect(answer.content.nodes.whereType<TextNode>(), isEmpty);

    final db = await openDb(tester, helper);
    final payload =
        jsonDecode(await readPayloadJson(tester, db)) as Map<String, dynamic>;
    final nodes = ((payload['answer'] as Map<String, dynamic>)['content']
        as Map<String, dynamic>)['nodes'] as List<dynamic>;
    expect(
      nodes,
      <Map<String, Object?>>[
        <String, Object?>{'type': 'inline_math', 'latex': 'x^2+1'},
      ],
    );
    expect(await readStandardAnswer(tester, db), r'\(x^2+1\)|||Explanation.');
  });

  testWidgets('clear: existing typed answer becomes null with no placeholder',
      (tester) async {
    final helper = newFileHelper('p5_ui_clear.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(answer: ContentAnswer(content: _text('old answer'))),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // The seeded text is the mapper legacy projection of the current answer.
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, 'old answer');

    await tester.enterText(_inRepair(find.byType(TextField)), '   ');
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.text('暂无答案，点击手动补充'),
      reason: 'list did not show the cleared-answer prompt',
    );
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(typed.draft.answer, isNull);
    final db = await openDb(tester, helper);
    final standardAnswer = await readStandardAnswer(tester, db);
    expect(standardAnswer, '|||Explanation.');
    expect(standardAnswer, isNot(contains('暂无答案')));
    expect(standardAnswer, isNot(contains('old answer')));
    final payload =
        jsonDecode(await readPayloadJson(tester, db)) as Map<String, dynamic>;
    expect(payload['answer'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'validation failure: unsupported input keeps the page open with zero writes',
      (tester) async {
    final helper = newFileHelper('p5_ui_validation.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('暂无答案，点击手动补充'));
    await openRepairFromPrompt(tester);

    await tester.enterText(
      _inRepair(find.byType(TextField)),
      '![img](https://example.com/x.png)',
    );
    await tester.pump();
    expect(
      find.text('答案包含不支持的内容，请修改后重试'),
      findsOneWidget,
    );
    expect(find.byType(TypedAnswerRepairScreen), findsOneWidget);

    final db = await openDb(tester, helper);
    final payloadBefore = await tester.runAsync(
      () => _payloadJson(db, _storageId),
    );
    await tapSave(tester);
    await tester.pump();

    // Page stays open and the fixed validation error remains.
    expect(find.byType(TypedAnswerRepairScreen), findsOneWidget);
    expect(
      find.text('答案包含不支持的内容，请修改后重试'),
      findsOneWidget,
    );
    final payloadAfter = await tester.runAsync(
      () => _payloadJson(db, _storageId),
    );
    expect(payloadAfter, payloadBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'stale: concurrent modification shows the fixed message with zero writes',
      (tester) async {
    final helper = newFileHelper('p5_ui_stale.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    final draftA = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!
        .draft;

    // Another path commits first: the screen's expected draft becomes stale.
    await tester.runAsync(
      () => repository.updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: draftA,
        newAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      ),
    );
    final db = await openDb(tester, helper);
    final payloadBefore = await tester.runAsync(
      () => _payloadJson(db, _storageId),
    );
    final standardBefore = await tester.runAsync(
      () => _standardAnswer(db, _storageId),
    );

    final thirdOption = _inRepair(find.text('third'));
    await tester.ensureVisible(thirdOption);
    await tester.tap(thirdOption);
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilFound(
      tester,
      find.text('题目已在编辑期间被修改，请返回列表刷新后重试'),
      reason: 'fixed stale message did not appear',
    );
    // Page stays open; the UI attempt wrote zero rows.
    expect(find.byType(TypedAnswerRepairScreen), findsOneWidget);
    expect(await tester.runAsync(() => _payloadJson(db, _storageId)),
        payloadBefore);
    expect(await tester.runAsync(() => _standardAnswer(db, _storageId)),
        standardBefore);
    final typed = (await tester.runAsync(
      () => _reloadTyped(db, _storageId),
    ))!;
    expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_b']));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'legacy: legacy rows still open QuestionEditScreen and edits persist',
      (tester) async {
    // The legacy editor saves through QuestionRepository.instance, so this
    // scenario runs on the frozen in-memory singleton under FLUTTER_TEST.
    final repository = QuestionRepository();
    final db = (await tester.runAsync(() async {
      await DatabaseHelper.resetRuntimeProfileForTesting();
      final opened = await DatabaseHelper.instance.database;
      await _insertLegacyRow(opened, id: 'p5_ui_legacy_001');
      return opened;
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Legacy stem text.'));

    await tester.tap(find.text('编辑题目'));
    await _pumpUntilFound(
      tester,
      find.byType(QuestionEditScreen),
      reason: 'legacy editor did not open',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    // The legacy editor renders read-only preview cards until a field gains
    // focus; tap the content preview first so the editable TextField exists.
    final contentPreview = find.descendant(
      of: find.byType(QuestionEditScreen),
      matching: find.text('Legacy stem text.'),
    );
    await tester.tap(contentPreview);
    await tester.pump();
    final contentField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller?.text == 'Legacy stem text.',
    );
    await tester.enterText(contentField, 'Updated legacy content.');
    final saveButton = find.descendant(
      of: find.byType(QuestionEditScreen),
      matching: find.widgetWithText(TextButton, '保存'),
    );
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);

    await _pumpUntilGone(
      tester,
      find.byType(QuestionEditScreen),
      reason: 'legacy editor did not close after save',
      maxFrames: 300,
    );
    await _pumpUntilFound(
      tester,
      find.text('Updated legacy content.'),
      reason: 'legacy edit did not persist and reload',
      maxFrames: 300,
    );
    final rows = (await tester.runAsync(
      () => db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['p5_ui_legacy_001'],
      ),
    ))!;
    expect(rows.single['content'], 'Updated legacy content.');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'practice consumer: a UI repair is read by a new practice projection',
      (tester) async {
    final helper = newFileHelper('p5_ui_practice.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);
    // The draft already answers opt_a; deselect it so the repaired answer is
    // exactly the newly chosen option.
    final firstOption = _inRepair(find.text('first'));
    await tester.ensureVisible(firstOption);
    await tester.tap(firstOption);
    await tester.pump();
    final thirdOption = _inRepair(find.text('third'));
    await tester.ensureVisible(thirdOption);
    await tester.tap(thirdOption);
    await tester.pump();
    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(tester, find.text('丙'));

    final reloaded = (await tester.runAsync(
      () => repository.getPersistedQuestionsByBank(_bankName),
    ))!;
    expect(reloaded, hasLength(1));
    final typed = reloaded.single as TypedPersistedQuestion;
    final practiceView = PracticeQuestionViewAdapter.fromPersisted(typed);
    expect(practiceView.isTyped, isTrue);
    expect(practiceView.answerOptionIds, <String>['opt_c']);
    expect(
      (practiceView.typedAnswer!.nodes.single as TextNode).text,
      '丙',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'no-op round-trip: literal math-looking text survives a save unchanged',
      (tester) async {
    final helper = newFileHelper('p5_ui_noop.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(
          answer: ContentAnswer(content: _text(r'$x$')),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // The typed editor boundary escapes the literal dollar so it survives
    // as a TextNode instead of being re-parsed as math.
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, r'\$x\$');
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    final answer = typed.draft.answer as ContentAnswer;
    expect(answer.content.nodes, hasLength(1));
    expect((answer.content.nodes.single as TextNode).text, r'$x$');
    expect(answer.content.nodes.whereType<InlineMathNode>(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'explicit typed empty answer stays ContentAnswer(empty), never null',
      (tester) async {
    final helper = newFileHelper('p5_ui_explicit_empty.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(
          answer: ContentAnswer(content: RichContent(nodes: <ContentNode>[])),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, isEmpty);
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    final answer = typed.draft.answer;
    expect(answer, isA<ContentAnswer>());
    expect((answer as ContentAnswer).content.nodes, isEmpty);
    expect(typed.draft.answer, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'raw fallback answer is read-only with a fixed notice and zero writes',
      (tester) async {
    final helper = newFileHelper('p5_ui_raw_fallback.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _contentDraft(
          answer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[
              const TextNode('safe prefix '),
              RawFallbackNode(<Object?, Object?>{
                'type': 'future_diagram',
                'payload': <Object?, Object?>{'shape': 'synthetic'},
              }),
            ]),
          ),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // Unsupported content is explicit and read-only; no text field appears
    // and the save button is disabled.
    expect(
      find.text('当前答案包含暂不支持编辑的内容，已保留原答案'),
      findsOneWidget,
    );
    expect(_inRepair(find.byType(TextField)), findsNothing);
    final saveFinder = _inRepair(find.widgetWithText(FilledButton, '保存'));
    final save = tester.widget<FilledButton>(saveFinder);
    expect(save.onPressed, isNull);

    final db = await openDb(tester, helper);
    final payloadBefore =
        await tester.runAsync(() => _payloadJson(db, _storageId));
    final standardBefore =
        await tester.runAsync(() => _standardAnswer(db, _storageId));
    await tester.tap(saveFinder, warnIfMissed: false);
    await tester.pump();

    expect(await tester.runAsync(() => _payloadJson(db, _storageId)),
        payloadBefore);
    expect(await tester.runAsync(() => _standardAnswer(db, _storageId)),
        standardBefore);
    expect(find.byType(TypedAnswerRepairScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'choice kind with ContentAnswer fallback opens the text editor and '
      'preserves the existing answer on no-op save', (tester) async {
    final helper = newFileHelper('p5_ui_choice_content.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(
          answer: ContentAnswer(content: _text('fallback answer')),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    expect(_inRepair(find.byType(CheckboxListTile)), findsNothing);
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, 'fallback answer');
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    final answer = typed.draft.answer as ContentAnswer;
    expect((answer.content.nodes.single as TextNode).text, 'fallback answer');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'insufficient choice options fall back to a text editor and stay '
      'repairable', (tester) async {
    final helper = newFileHelper('p5_ui_insufficient.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _singleOptionChoiceDraft(
          answer: ChoiceAnswer(optionIds: <String>['opt_a']),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // No unusable checkbox UI; the existing choice is shown as display text
    // and a no-op save keeps the original ChoiceAnswer.
    expect(_inRepair(find.byType(CheckboxListTile)), findsNothing);
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, '甲');
    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    var typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_a']));

    // A real edit is not blocked: the text is saved as a typed ContentAnswer.
    await openRepairFromButton(tester);
    await tester.enterText(_inRepair(find.byType(TextField)), 'x = 1');
    await tester.pump();
    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    final answer = typed.draft.answer as ContentAnswer;
    expect((answer.content.nodes.single as TextNode).text, 'x = 1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('choice answer can be explicitly cleared to null',
      (tester) async {
    final helper = newFileHelper('p5_ui_choice_clear.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(answer: ChoiceAnswer(optionIds: <String>['opt_a'])),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // Deselect the only selected option and save: the answer becomes null.
    final firstOption = _inRepair(find.text('first'));
    await tester.ensureVisible(firstOption);
    await tester.tap(firstOption);
    await tester.pump();
    await tapSave(tester);

    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    await _pumpUntilFound(
      tester,
      find.text('暂无答案，点击手动补充'),
      reason: 'list did not show the cleared choice answer prompt',
    );
    final typed = (await tester.runAsync(
      () async => _reloadTyped(await helper.database, _storageId),
    ))!;
    expect(typed.draft.answer, isNull);
    final db = await openDb(tester, helper);
    expect(await readStandardAnswer(tester, db), '|||Explanation.');
    final payload =
        jsonDecode(await readPayloadJson(tester, db)) as Map<String, dynamic>;
    expect(payload['answer'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'abnormal ChoiceAnswer with an unknown option id opens the text '
      'fallback; no-op preserves the payload and a real edit repairs',
      (tester) async {
    final helper = newFileHelper('p5_ui_unknown_id.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _twoOptionChoiceDraft(
          answer: ChoiceAnswer(optionIds: <String>['opt_c']),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    // No checkbox editor for an unrepresentable choice; the existing
    // identity is shown as text.
    expect(_inRepair(find.byType(CheckboxListTile)), findsNothing);
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, 'opt_c');
    final db = await openDb(tester, helper);
    final payloadBefore =
        await tester.runAsync(() => _payloadJson(db, _storageId));

    // A no-op save never crashes and never rewrites the sidecar payload.
    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    expect(await tester.runAsync(() => _payloadJson(db, _storageId)),
        payloadBefore);
    var typed = (await tester.runAsync(
      () async => _reloadTyped(db, _storageId),
    ))!;
    expect(typed.draft.answer, ChoiceAnswer(optionIds: <String>['opt_c']));

    // A real edit is still repairable through the text fallback.
    await openRepairFromButton(tester);
    await tester.enterText(_inRepair(find.byType(TextField)), 'manual fix');
    await tester.pump();
    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    typed = (await tester.runAsync(
      () async => _reloadTyped(db, _storageId),
    ))!;
    final answer = typed.draft.answer as ContentAnswer;
    expect((answer.content.nodes.single as TextNode).text, 'manual fix');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'abnormal ChoiceAnswer with duplicate ids opens the text fallback and '
      'no-op preserves the duplicated answer', (tester) async {
    final helper = newFileHelper('p5_ui_duplicate_ids.db');
    final repository = QuestionRepository(databaseHelper: helper);
    await tester.runAsync(() async {
      await _insertTypedRow(
        await helper.database,
        _choiceDraft(
          answer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
        ),
        storageId: _storageId,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('修正答案'));
    await openRepairFromButton(tester);

    expect(_inRepair(find.byType(CheckboxListTile)), findsNothing);
    final field = tester.widget<TextField>(_inRepair(find.byType(TextField)));
    expect(field.controller!.text, '甲, 甲');
    final db = await openDb(tester, helper);
    final payloadBefore =
        await tester.runAsync(() => _payloadJson(db, _storageId));

    await tapSave(tester);
    await _pumpUntilGone(tester, find.byType(TypedAnswerRepairScreen));
    expect(await tester.runAsync(() => _payloadJson(db, _storageId)),
        payloadBefore);
    final typed = (await tester.runAsync(
      () async => _reloadTyped(db, _storageId),
    ))!;
    expect(
      typed.draft.answer,
      ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
    );
    expect(tester.takeException(), isNull);
  });
}
