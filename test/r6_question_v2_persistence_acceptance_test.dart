// R6D synthetic acceptance: repository main path, unsafe-write gate, corrupt
// read precedence, v15 migration matrix, close/reopen, and transaction
// rollback evidence.
//
// All databases in this file are synthetic: sqflite FFI in-memory singleton
// handles for the repository APIs and temp-file handles opened only through
// the frozen DatabaseHelper.openPathForTesting seam. No real application
// database, private document, OCR, Replay, Provider, network path, Base64
// image, or external fixture is touched. Test data is constructed entirely
// inside this file and no other test file is imported.
//
// Seam limitation: under FLUTTER_TEST the DatabaseHelper singleton is always
// in-memory, so the repository save/read/delete main path runs on a fresh
// synthetic v15 database, and close/reopen persistence uses the frozen
// openPathForTesting file seam with the frozen production mapper as writer
// and decoder (the R6C-accepted pattern). Manual rows are used only for the
// explicitly authorized corrupt/sidecar and file-persistence scenarios, never
// to fake the successful repository save path or a transaction rollback.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/question_v2_schema_exception.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'r6d_synthetic_bank';
const _storageIdA = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _storageIdB = 'b4f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

final _canonicalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}$',
);

/// Literal math/image/path/URL syntax that must survive only as ordinary
/// TextNode text and never be reinterpreted as structural nodes.
const String _literalText = r'Literal \(x+1\) \[y=2\] ![image](not-an-asset) '
    r'C:\not-a-real-path-inside-text https://example.invalid/inside-text ';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

List<SourceRef> _sourceRefs() {
  return <SourceRef>[
    SourceRef.document(
      sourceId: 'r6d_src_alpha',
      displayLabel: 'synthetic-a.pdf',
    ),
    SourceRef.at(
      sourceId: 'r6d_src_beta',
      point: SourcePoint.page(pageNumber: 1),
    ),
  ];
}

/// Two source documents share the same local asset id while ownership stays
/// qualified by (sourceId, localAssetId). No bytes, path, OCR, or provider
/// body is ever part of the fixture.
List<SourcedAssetRef> _assetRefs() {
  return <SourcedAssetRef>[
    SourcedAssetRef(
      sourceId: 'r6d_src_alpha',
      asset: AssetRef(
        assetId: 'shared_asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
      ),
    ),
    SourcedAssetRef(
      sourceId: 'r6d_src_beta',
      asset: AssetRef(
        assetId: 'shared_asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
      ),
    ),
  ];
}

List<ImportIssue> _issues() {
  return <ImportIssue>[
    ImportIssue(
      code: 'low_confidence',
      severity: ImportIssueSeverity.warning,
      field: ImportIssueField.answer,
    ),
    ImportIssue(
      code: 'source_scan_partial',
      severity: ImportIssueSeverity.info,
      field: ImportIssueField.source,
    ),
  ];
}

/// Choice draft: math nodes, ordered options, ChoiceAnswer, null explanation.
QuestionDraftV2 _draftA() {
  return QuestionDraftV2(
    questionId: 'r6d_shared_question',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: RichContent(nodes: const <ContentNode>[
      TextNode('Stem A: '),
      InlineMathNode('x+1'),
      TextNode(' and '),
      BlockMathNode('y=2'),
    ]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'A',
        label: '甲',
        content: RichContent(nodes: const <ContentNode>[
          TextNode('first '),
          InlineMathNode('a+b'),
        ]),
      ),
      QuestionOption(
        optionId: 'B',
        label: '乙',
        content: _text('second'),
      ),
    ],
    answer: ChoiceAnswer(optionIds: <String>['A', 'B']),
    explanation: null,
    sourceRefs: _sourceRefs(),
    assetRefs: _assetRefs(),
    issues: _issues(),
  );
}

/// Content draft: literal syntax text, safe nested RawFallback, ContentAnswer
/// with a literal `|||`, and an explicit empty explanation.
QuestionDraftV2 _draftB() {
  return QuestionDraftV2(
    questionId: 'r6d_shared_question',
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: RichContent(nodes: <ContentNode>[
      const TextNode(_literalText),
      RawFallbackNode(<Object?, Object?>{
        'type': 'future_diagram',
        'payload': <Object?, Object?>{
          'shape': 'synthetic',
          'items': <Object?>[
            1,
            <Object?, Object?>{'nested': 'value'},
          ],
        },
      }),
    ]),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'A',
        label: '丙',
        content: _text('third'),
      ),
    ],
    answer: ContentAnswer(content: _text('A ||| B')),
    explanation: RichContent(nodes: const <ContentNode>[]),
    sourceRefs: _sourceRefs(),
    assetRefs: _assetRefs(),
    issues: _issues(),
  );
}

/// Direct unsafe RawFallback in the stem slot.
QuestionDraftV2 _unsafeDirectDraft() {
  return QuestionDraftV2(
    questionId: 'r6d_unsafe_direct',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: <ContentNode>[
      RawFallbackNode(<Object?, Object?>{
        'type': 'future_diagram',
        'providerResponse': <Object?, Object?>{'status': 'synthetic'},
      }),
    ]),
  );
}

/// Multi-level nested unsafe RawFallback in an option (non-stem) slot.
QuestionDraftV2 _unsafeNestedDraft() {
  return QuestionDraftV2(
    questionId: 'r6d_unsafe_nested',
    kind: QuestionKind.singleChoice,
    stem: _text('Safe stem.'),
    options: <QuestionOption>[
      QuestionOption(
        optionId: 'A',
        label: '甲',
        content: RichContent(nodes: <ContentNode>[
          RawFallbackNode(<Object?, Object?>{
            'type': 'future_diagram',
            'payload': <Object?, Object?>{
              'nested': <Object?, Object?>{'providerBody': 'leak'},
            },
          }),
        ]),
      ),
    ],
  );
}

String _unsafePayloadJson() {
  return jsonEncode(<String, Object?>{
    'schemaVersion': 2,
    'questionId': 'r6d_unsafe_read',
    'questionNumber': null,
    'kind': 'short_answer',
    'stem': <String, Object?>{
      'schemaVersion': 1,
      'nodes': <Object?>[
        <String, Object?>{
          'type': 'future_diagram',
          'providerResponse': <String, Object?>{'status': 'synthetic'},
        },
      ],
    },
    'options': <Object?>[],
    'answer': null,
    'explanation': null,
    'sourceRefs': <Object?>[],
    'assetRefs': <Object?>[],
    'issues': <Object?>[],
  });
}

Future<Database> _singletonDb() => DatabaseHelper.instance.database;

Future<void> _insertTypedRow(
  Database db,
  QuestionDraftV2 draft, {
  required String storageId,
  required int createdAt,
}) async {
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> _insertLegacyRow(
  Database db, {
  required String id,
  required int createdAt,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'Legacy stem text.',
    'options': '[]',
    'standard_answer': 'Legacy answer|||Legacy explanation.',
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': createdAt,
    'bank_name': _bankName,
  });
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

Future<void> _insertCorruptRow(
  Database db, {
  required String id,
  required int version,
  required String? payloadJson,
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'Corrupt synthetic parent.',
    'options': '[]',
    'standard_answer': 'x|||',
    'created_at': 1,
    'bank_name': _bankName,
  });
  await db.insert('question_v2_payloads', <String, Object?>{
    'question_id': id,
    'payload_schema_version': version,
    'payload_json': payloadJson,
  });
}

String _fixedPayloadMessage(QuestionV2PayloadFailure failure) {
  final detail = switch (failure) {
    QuestionV2PayloadFailure.malformedJson =>
      'The V2 sidecar payload is not valid JSON.',
    QuestionV2PayloadFailure.unsupportedSchema =>
      'The V2 payload schema is not supported.',
    QuestionV2PayloadFailure.schemaMismatch =>
      'The V2 sidecar schema version and payload root disagree.',
    QuestionV2PayloadFailure.invalidPayload =>
      'The V2 payload cannot be read safely.',
    QuestionV2PayloadFailure.unsafePayload =>
      'The V2 payload contains unsafe content.',
  };
  return 'QuestionV2PayloadException(${failure.name}): $detail';
}

String _fixedSchemaMessage(QuestionV2SchemaFailure failure) {
  final detail = switch (failure) {
    QuestionV2SchemaFailure.unsupportedSourceVersion =>
      'The source database version is below the supported migration floor.',
    QuestionV2SchemaFailure.malformedParentSchema =>
      'The parent schema does not satisfy the frozen v15 requirements.',
    QuestionV2SchemaFailure.malformedSidecarSchema =>
      'The question_v2_payloads sidecar does not match the frozen '
          'definition.',
    QuestionV2SchemaFailure.foreignKeysDisabled =>
      'Foreign key enforcement is disabled on the opened connection.',
    QuestionV2SchemaFailure.foreignKeyViolation =>
      'The database contains foreign key violations.',
  };
  return 'QuestionV2SchemaException(${failure.name}): $detail';
}

Future<Database> _openSeam(String path) =>
    DatabaseHelper.instance.openPathForTesting(path);

Future<Database> _openRaw(String path) {
  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(),
  );
}

Future<int> _userVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return rows.single['user_version'] as int;
}

Future<void> _setUserVersion(Database db, int version) async {
  await db.execute('PRAGMA user_version = $version');
}

/// Downgrades a v15 fixture to the schema shape that existed at [version],
/// always removing the v15 sidecar and, where practical, the legacy
/// columns/tables that the matching onUpgrade steps recreate.
Future<void> _downgradeToVersion(Database raw, int version) async {
  await raw.execute('DROP TABLE question_v2_payloads');
  if (version < 13) {
    await raw.execute('ALTER TABLE questions DROP COLUMN raw_explanation');
  }
  if (version < 11) {
    await raw.execute('DROP TABLE import_tasks');
  } else if (version < 14) {
    await raw.execute('ALTER TABLE import_tasks DROP COLUMN warnings');
    await raw.execute('ALTER TABLE import_tasks DROP COLUMN diagnostics');
  }
}

Future<void> _seedV1Data(Database db) async {
  await db.insert('questions', <String, Object?>{
    'id': 'q_seed_1',
    'type': 0,
    'content': 'seed stem one',
    'options': '["A. one","B. two"]',
    'standard_answer': 'A|||seed explanation',
    'explanation': 'seed explanation',
    'raw_explanation': 'raw seed',
    'created_at': 1700000001,
    'bank_name': 'seed_bank',
  });
  await db.insert('questions', <String, Object?>{
    'id': 'q_seed_2',
    'type': 3,
    'content': 'seed stem two',
    'options': '[]',
    'standard_answer': 'answer two|||',
    'created_at': 1700000002,
    'bank_name': 'seed_bank',
  });
  await db.insert('review_states', <String, Object?>{
    'question_id': 'q_seed_1',
    'state': 1,
    'next_review_time': 1700001000,
    'lapses': 2,
    'difficulty': 3.5,
    'stability': 4.5,
    'reps': 7,
    'last_lapse_time': 1700000000,
    'last_review_time': 1700000005,
  });
  await db.insert('bank_folders', <String, Object?>{
    'bank_name': 'seed_bank',
    'folder_name': '默认学科',
  });
}

Future<Map<String, String>> _snapshotStable(Database db) async {
  return <String, String>{
    'questions': jsonEncode(await db.rawQuery(
      'SELECT id, type, content, options, standard_answer, explanation, '
      'created_at, bank_name FROM questions ORDER BY id',
    )),
    'review_states': jsonEncode(await db.query(
      'review_states',
      orderBy: 'rowid',
    )),
    'bank_folders': jsonEncode(await db.query(
      'bank_folders',
      orderBy: 'rowid',
    )),
  };
}

/// Opens through the seam, expects the given failure, and proves the failed
/// open left user_version and the sidecar SQL text unchanged.
Future<void> _expectRejectedSchema(
  String path,
  QuestionV2SchemaFailure expectedFailure, {
  required String reason,
}) async {
  final before = await _openRaw(path);
  final versionBefore = await _userVersion(before);
  final sqlBefore = (await before.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' "
    "AND name = 'question_v2_payloads'",
  ))
      .map((row) => row['sql'])
      .toList();
  await before.close();

  QuestionV2SchemaException? caught;
  try {
    await _openSeam(path);
  } on QuestionV2SchemaException catch (error) {
    caught = error;
  }
  expect(caught, isNotNull, reason: reason);
  expect(caught!.failure, expectedFailure, reason: reason);
  expect(caught.toString(), _fixedSchemaMessage(expectedFailure),
      reason: reason);
  expect(caught.toString(), isNot(contains('CREATE')), reason: reason);
  expect(caught.toString(), isNot(contains('FOREIGN')), reason: reason);

  final after = await _openRaw(path);
  expect(await _userVersion(after), versionBefore, reason: reason);
  final sqlAfter = (await after.rawQuery(
    "SELECT sql FROM sqlite_master WHERE type = 'table' "
    "AND name = 'question_v2_payloads'",
  ))
      .map((row) => row['sql'])
      .toList();
  expect(sqlAfter, sqlBefore, reason: reason);
  await after.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('r6d_acceptance_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('synthetic acceptance main path', () {
    test(
        'repository save writes compatibility rows, payloads, states, and '
        'folder for duplicate draft ids', () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: '  $_bankName  ',
        folderName: '  Math  ',
        questions: <QuestionDraftV2>[_draftA(), _draftB()],
      );

      final db = await _singletonDb();
      final questions = await db.query('questions', orderBy: 'rowid');
      expect(questions, hasLength(2));
      final ids =
          questions.map((row) => row['id'] as String).toList(growable: false);
      expect(ids[0], isNot(ids[1]));
      for (final id in ids) {
        expect(_canonicalUuidPattern.hasMatch(id), isTrue);
        expect(id, isNot('r6d_shared_question'));
      }
      expect(questions[0]['bank_name'], _bankName);
      expect(questions[1]['bank_name'], _bankName);
      expect(questions[0]['created_at'], questions[1]['created_at']);
      expect(questions[0]['created_at'], greaterThan(0));
      expect(questions[0]['raw_explanation'], isNull);
      expect(questions[1]['raw_explanation'], isNull);

      // V1 compatibility projection: kind, stem, ordered options, answer,
      // explanation, and the full-width literal ||| replacement.
      expect(questions[0]['type'], 0);
      expect(questions[1]['type'], 3);
      expect(
        questions[0]['content'],
        r'Stem A: \(x+1\) and \[y=2\]',
      );
      expect(
        questions[1]['content'],
        '$_literalText[Unsupported content]',
      );
      expect(
        jsonDecode(questions[0]['options']! as String),
        <String>[r'甲. first \(a+b\)', r'乙. second'],
      );
      expect(
        jsonDecode(questions[1]['options']! as String),
        <String>[r'丙. third'],
      );
      expect(questions[0]['standard_answer'], '甲,乙|||');
      expect(questions[1]['standard_answer'], 'A ｜｜｜ B|||');
      expect(questions[0]['explanation'], '');
      expect(questions[1]['explanation'], '');

      // RawFallback must never leak type/payload/nested values into V1
      // text fields, while the literal path-like TextNode text is ordinary.
      final v1Text = <String>[
        questions[0]['content']! as String,
        questions[0]['options']! as String,
        questions[0]['standard_answer']! as String,
        questions[1]['content']! as String,
        questions[1]['options']! as String,
        questions[1]['standard_answer']! as String,
      ].join('\n');
      expect(v1Text, isNot(contains('future_diagram')));
      expect(v1Text, isNot(contains('shape')));
      expect(v1Text, isNot(contains('synthetic')));
      expect(v1Text, isNot(contains('nested')));
      expect(v1Text, isNot(contains('"payload"')));
      expect(v1Text, contains(r'C:\not-a-real-path-inside-text'));
      expect(v1Text, contains('https://example.invalid/inside-text'));

      // Sidecar rows carry the full lossless V2 payload.
      final payloads = await db.query('question_v2_payloads', orderBy: 'rowid');
      expect(payloads, hasLength(2));
      final payloadById = <String, Map<String, dynamic>>{
        for (final row in payloads)
          row['question_id'] as String:
              jsonDecode(row['payload_json']! as String)
                  as Map<String, dynamic>,
      };
      for (final row in payloads) {
        expect(
            row['payload_schema_version'], QuestionDraftV2Codec.schemaVersion);
      }
      final payloadA = payloadById[ids[0]]!;
      final payloadB = payloadById[ids[1]]!;
      expect(payloadA['questionId'], 'r6d_shared_question');
      expect(payloadB['questionId'], 'r6d_shared_question');
      expect(payloadA['kind'], 'single_choice');
      expect(payloadB['kind'], 'short_answer');
      expect(payloadA['questionNumber'], 1);
      expect(payloadB['questionNumber'], 2);

      // Literal syntax stays plain TextNode text; math and fallback keep
      // their own structural nodes in V2.
      final stemANodes =
          (payloadA['stem']! as Map<String, dynamic>)['nodes'] as List<dynamic>;
      expect(
        stemANodes.map((node) => node['type']).toList(),
        <String>['text', 'inline_math', 'text', 'block_math'],
      );
      expect(stemANodes[1]['latex'], 'x+1');
      expect(stemANodes[3]['latex'], 'y=2');
      final stemBNodes =
          (payloadB['stem']! as Map<String, dynamic>)['nodes'] as List<dynamic>;
      expect(stemBNodes[0]['type'], 'text');
      expect(stemBNodes[0]['text'], _literalText);
      expect(stemBNodes[1]['type'], 'future_diagram');
      expect(
        stemBNodes[1]['payload'],
        <String, Object?>{
          'shape': 'synthetic',
          'items': <Object?>[
            1,
            <String, Object?>{'nested': 'value'}
          ],
        },
      );

      // V2 distinguishes null from explicit empty explanation and keeps the
      // literal ||| answer byte-for-byte.
      expect(payloadA['explanation'], isNull);
      expect(payloadB['explanation'], <String, Object?>{
        'schemaVersion': 1,
        'nodes': <Object?>[],
      });
      final answerB = (payloadB['answer']! as Map<String, dynamic>)['content']
          as Map<String, dynamic>;
      expect(
        ((answerB['nodes'] as List<dynamic>).single
            as Map<String, dynamic>)['text'],
        'A ||| B',
      );
      expect(payloadA['answer'], <String, Object?>{
        'type': 'choice',
        'optionIds': <Object?>['A', 'B'],
      });

      // Asset refs in V2 never carry bytes, paths, OCR, or provider bodies.
      final assetList = payloadA['assetRefs'] as List<dynamic>;
      expect(assetList, hasLength(2));
      for (final asset in assetList.cast<Map<String, dynamic>>()) {
        expect(asset.keys.toSet(), <String>{
          'sourceId',
          'assetId',
          'kind',
          'mimeType',
          'pixelWidth',
          'pixelHeight',
        });
      }
      expect(
        assetList.map((asset) => asset['sourceId']).toList(),
        <String>['r6d_src_alpha', 'r6d_src_beta'],
      );
      expect(
        assetList.map((asset) => asset['assetId']).toList(),
        <String>['shared_asset_001', 'shared_asset_001'],
      );

      // Every new question has its initial review state and the folder
      // mapping is observable in the same successful transaction.
      final states = await db.query('review_states', orderBy: 'question_id');
      expect(states, hasLength(2));
      expect(
        states.map((row) => row['question_id']).toSet(),
        ids.toSet(),
      );
      for (final state in states) {
        expect(state['state'], 0);
        expect(state['lapses'], 0);
        expect(state['next_review_time'], 0);
      }
      final folders = await db.query('bank_folders');
      expect(folders, hasLength(1));
      expect(folders.single['bank_name'], _bankName);
      expect(folders.single['folder_name'], 'Math');
    });

    test('repository read returns full structural V2 drafts', () async {
      final draftA = _draftA();
      final draftB = _draftB();
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: null,
        questions: <QuestionDraftV2>[draftA, draftB],
      );

      final decoded = await repository.getPersistedQuestionsByBank(_bankName);
      expect(decoded, hasLength(2));
      final typedRows = decoded.cast<TypedPersistedQuestion>().toList();
      expect(typedRows[0].storageId, isNot(typedRows[1].storageId));
      for (final typed in typedRows) {
        expect(_canonicalUuidPattern.hasMatch(typed.storageId), isTrue);
        expect(typed.bankName, _bankName);
        expect(typed.createdAt, greaterThan(0));
      }
      expect(typedRows[0].createdAt, typedRows[1].createdAt);

      final readA = typedRows.singleWhere((typed) => typed.draft == draftA);
      final readB = typedRows.singleWhere((typed) => typed.draft == draftB);
      expect(readA.draft, draftA);
      expect(readB.draft, draftB);

      // Structural comparisons beyond string summaries: counts, order,
      // source identity, asset source ownership, and issue structure.
      expect(readA.draft.sourceRefs, draftA.sourceRefs);
      expect(readB.draft.sourceRefs, draftB.sourceRefs);
      expect(readA.draft.sourceRefs, hasLength(2));
      expect(readA.draft.sourceRefs[0].sourceId, 'r6d_src_alpha');
      expect(readA.draft.sourceRefs[1].sourceId, 'r6d_src_beta');
      expect(readA.draft.assetRefs, draftA.assetRefs);
      expect(readA.draft.assetRefs, hasLength(2));
      expect(readA.draft.assetRefs[0].sourceId, 'r6d_src_alpha');
      expect(readA.draft.assetRefs[1].sourceId, 'r6d_src_beta');
      expect(readA.draft.assetRefs[0].localAssetId, 'shared_asset_001');
      expect(readA.draft.assetRefs[1].localAssetId, 'shared_asset_001');
      expect(readA.draft.issues, draftA.issues);
      expect(readB.draft.issues, draftB.issues);
      expect(readA.draft.issues, hasLength(2));
      expect(readA.draft.options, draftA.options);
      expect(readA.draft.answer, draftA.answer);
      expect(readB.draft.answer, draftB.answer);
      expect(readA.draft.explanation, isNull);
      expect(readB.draft.explanation, isNotNull);
      expect(readB.draft.explanation!.nodes, isEmpty);
    });

    test('single and bank deletes cascade sidecars and review states',
        () async {
      final repository = QuestionRepository();
      await repository.saveQuestionDraftsV2ToBank(
        bankName: _bankName,
        folderName: 'Math',
        questions: <QuestionDraftV2>[_draftA(), _draftB()],
      );
      final db = await _singletonDb();
      final ids = (await db.query('questions', orderBy: 'rowid'))
          .map((row) => row['id'] as String)
          .toList(growable: false);
      expect(ids, hasLength(2));

      await repository.deleteQuestion(ids[0]);
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('question_v2_payloads'), hasLength(1));
      expect(await db.query('review_states'), hasLength(1));
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      await repository.deleteQuestionBank(_bankName);
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      // The frozen bank-delete path does not remove folder mappings; the
      // observable row is documented rather than asserted away.
      expect(await db.query('bank_folders'), hasLength(1));
    });
  });

  group('unsafe write acceptance', () {
    test(
        'direct unsafe raw fallback in the stem fails before any write with '
        'a fixed safe exception', () async {
      final db = await _singletonDb();
      await db.insert('bank_folders', <String, Object?>{
        'bank_name': _bankName,
        'folder_name': 'Math',
      });
      final repository = QuestionRepository();

      QuestionV2PayloadException? caught;
      try {
        await repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_unsafeDirectDraft()],
        );
      } on QuestionV2PayloadException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure, QuestionV2PayloadFailure.unsafePayload);
      expect(
        caught.toString(),
        _fixedPayloadMessage(QuestionV2PayloadFailure.unsafePayload),
      );
      expect(caught.toString(), isNot(contains('providerResponse')));
      expect(caught.toString(), isNot(contains('synthetic')));
      expect(caught.toString(), isNot(contains('r6d_unsafe_direct')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(
        () => (caught as dynamic).cause,
        throwsA(isA<NoSuchMethodError>()),
      );
      expect(
        () => (caught as dynamic).message,
        throwsA(isA<NoSuchMethodError>()),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      final folders = await db.query('bank_folders');
      expect(folders, hasLength(1));
      expect(folders.single['folder_name'], 'Math');
    });

    test(
        'nested unsafe raw fallback in an option fails before any write with '
        'a fixed safe exception', () async {
      final db = await _singletonDb();
      await db.insert('bank_folders', <String, Object?>{
        'bank_name': _bankName,
        'folder_name': 'Math',
      });
      final repository = QuestionRepository();

      QuestionV2PayloadException? caught;
      try {
        await repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: null,
          questions: <QuestionDraftV2>[_unsafeNestedDraft()],
        );
      } on QuestionV2PayloadException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure, QuestionV2PayloadFailure.unsafePayload);
      expect(caught.toString(), isNot(contains('providerBody')));
      expect(caught.toString(), isNot(contains('leak')));
      expect(caught.toString(), isNot(contains('r6d_unsafe_nested')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(
        () => (caught as dynamic).cause,
        throwsA(isA<NoSuchMethodError>()),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      final folders = await db.query('bank_folders');
      expect(folders, hasLength(1));
      expect(folders.single['folder_name'], 'Math');
    });
  });

  group('corrupt and unsafe read precedence', () {
    test(
        'malformed JSON sidecar fails the whole bank without partial or '
        'V1 fallback', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draftA(),
          storageId: _storageIdA, createdAt: 2);
      await _insertLegacyRow(db, id: 'r6d_legacy_ok', createdAt: 1);
      await _insertCorruptRow(
        db,
        id: _storageIdB,
        version: 2,
        payloadJson: '{corrupt',
      );

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>()
              .having(
                (error) => error.failure,
                'failure',
                QuestionV2PayloadFailure.malformedJson,
              )
              .having(
                (error) => error.toString(),
                'toString',
                _fixedPayloadMessage(QuestionV2PayloadFailure.malformedJson),
              ),
        ),
      );
    });

    test('column/root schema mismatch fails the whole bank', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draftA(),
          storageId: _storageIdA, createdAt: 2);
      await _insertLegacyRow(db, id: 'r6d_legacy_ok', createdAt: 1);
      await _insertCorruptRow(
        db,
        id: _storageIdB,
        version: 2,
        payloadJson: jsonEncode(<String, Object?>{'schemaVersion': 3}),
      );

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.schemaMismatch,
          ),
        ),
      );
    });

    test('unsupported schema version fails the whole bank', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draftA(),
          storageId: _storageIdA, createdAt: 2);
      await _insertLegacyRow(db, id: 'r6d_legacy_ok', createdAt: 1);
      await _insertCorruptRow(
        db,
        id: _storageIdB,
        version: 3,
        payloadJson: jsonEncode(<String, Object?>{'schemaVersion': 3}),
      );

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.unsupportedSchema,
          ),
        ),
      );
    });

    test('unsafe decoded payload fails the whole bank', () async {
      final db = await _singletonDb();
      await _insertTypedRow(db, _draftA(),
          storageId: _storageIdA, createdAt: 2);
      await _insertLegacyRow(db, id: 'r6d_legacy_ok', createdAt: 1);
      await _insertCorruptRow(
        db,
        id: _storageIdB,
        version: 2,
        payloadJson: _unsafePayloadJson(),
      );

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.unsafePayload,
          ),
        ),
      );
    });

    test('only one sidecar alias present fails the whole bank', () async {
      final db = await _singletonDb();
      // A synthetic table shape where the payload column is nullable allows
      // the partial sidecar row the frozen schema cannot express.
      await db.execute('DROP TABLE question_v2_payloads');
      await db.execute('''
        CREATE TABLE question_v2_payloads (
          question_id TEXT PRIMARY KEY NOT NULL,
          payload_schema_version INTEGER NOT NULL,
          payload_json TEXT
        )
      ''');
      await _insertTypedRow(db, _draftA(),
          storageId: _storageIdA, createdAt: 2);
      await _insertLegacyRow(db, id: 'r6d_legacy_ok', createdAt: 1);
      await _insertCorruptRow(
        db,
        id: _storageIdB,
        version: 2,
        payloadJson: null,
      );

      await expectLater(
        QuestionRepository().getPersistedQuestionsByBank(_bankName),
        throwsA(
          isA<QuestionV2PayloadException>().having(
            (error) => error.failure,
            'failure',
            QuestionV2PayloadFailure.invalidPayload,
          ),
        ),
      );
    });
  });

  group('close and reopen', () {
    test('typed rows survive close and reopen through the production seam',
        () async {
      final path = p.join(tempDir.path, 'r6d_close_reopen.db');
      final draftA = _draftA();
      final draftB = _draftB();
      final first = await _openSeam(path);
      try {
        final frozenA = _mapper.freezeForWrite(
          storageId: _storageIdA,
          bankName: _bankName,
          createdAt: 1700000001,
          draft: draftA,
        );
        final frozenB = _mapper.freezeForWrite(
          storageId: _storageIdB,
          bankName: _bankName,
          createdAt: 1700000002,
          draft: draftB,
        );
        await first.insert('questions', frozenA.questionRow);
        await first.insert('question_v2_payloads', frozenA.payloadRow);
        await first.insert('questions', frozenB.questionRow);
        await first.insert('question_v2_payloads', frozenB.payloadRow);
        await _insertReviewState(first, _storageIdA);
        await _insertReviewState(first, _storageIdB);
        await first.insert('bank_folders', <String, Object?>{
          'bank_name': _bankName,
          'folder_name': 'Math',
        });
        await _insertLegacyRow(first,
            id: 'r6d_legacy_close', createdAt: 1700000000);
      } finally {
        await first.close();
      }

      final second = await _openSeam(path);
      try {
        expect(await _userVersion(second), 15);
        expect(
          (await second.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
        );
        expect(await second.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        expect(await second.query('question_v2_payloads'), hasLength(2));

        final rows = await second.rawQuery(
          '''
          SELECT q.*,
                 p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
                 p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
          FROM questions q
          LEFT JOIN question_v2_payloads p ON q.id = p.question_id
          WHERE q.bank_name = ?
          ORDER BY q.created_at DESC
          ''',
          <Object?>[_bankName],
        );
        final decoded =
            rows.map(_mapper.decodeJoinedRow).toList(growable: false);
        expect(
          decoded.map((question) => question.storageId).toList(),
          <String>[_storageIdB, _storageIdA, 'r6d_legacy_close'],
        );
        final typedB = decoded[0] as TypedPersistedQuestion;
        final typedA = decoded[1] as TypedPersistedQuestion;
        expect(typedA.draft, draftA);
        expect(typedB.draft, draftB);
        expect(typedA.draft.sourceRefs, draftA.sourceRefs);
        expect(typedA.draft.assetRefs, draftA.assetRefs);
        expect(typedA.draft.issues, draftA.issues);
        expect(typedA.draft.options, draftA.options);
        expect(typedA.draft.explanation, isNull);
        expect(typedB.draft.explanation, isNotNull);
        expect(typedB.draft.explanation!.nodes, isEmpty);
        final legacy = decoded[2] as LegacyPersistedQuestion;
        expect(legacy.storageId, 'r6d_legacy_close');
        expect(legacy.bankName, _bankName);
        expect(legacy.question.answer, 'Legacy answer');

        final states = await second.query('review_states', orderBy: 'rowid');
        expect(states, hasLength(2));
        expect(
          states.map((row) => row['question_id']).toSet(),
          <String>{_storageIdA, _storageIdB},
        );
        final folders = await second.query('bank_folders');
        expect(folders.single['folder_name'], 'Math');
        expect(
          await second.rawQuery(
            "SELECT id FROM questions WHERE id LIKE 'r6b_v15_probe_parent_%'",
          ),
          isEmpty,
        );
      } finally {
        await second.close();
      }
    });
  });

  group('migration acceptance', () {
    test('fresh v15 database matches the frozen sidecar contract', () async {
      final db = await _openSeam(p.join(tempDir.path, 'r6d_fresh.db'));
      try {
        expect(await _userVersion(db), 15);
        expect(
          (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
          1,
        );
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        final tables = <String>{
          for (final row in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          ))
            row['name'] as String,
        };
        expect(tables, contains('question_v2_payloads'));
        expect(tables, contains('bank_folders'));

        await db.insert('questions', <String, Object?>{
          'id': 'q_fresh',
          'type': 0,
          'content': 'fresh stem',
          'standard_answer': 'A',
          'created_at': 1,
        });
        await db.insert('question_v2_payloads', <String, Object?>{
          'question_id': 'q_fresh',
          'payload_schema_version': 2,
          'payload_json': '{"schemaVersion":2,"synthetic":true}',
        });
        await db.delete('questions',
            where: 'id = ?', whereArgs: <Object?>['q_fresh']);
        expect(await db.query('question_v2_payloads'), isEmpty);
      } finally {
        await db.close();
      }
    });

    test('v10 through v14 upgrades preserve rows without forging sidecars',
        () async {
      for (final oldVersion in <int>[10, 11, 12, 13, 14]) {
        final path = p.join(tempDir.path, 'r6d_upgrade_v$oldVersion.db');
        final created = await _openSeam(path);
        await _seedV1Data(created);
        final stableBefore = await _snapshotStable(created);
        await created.close();

        final raw = await _openRaw(path);
        await _downgradeToVersion(raw, oldVersion);
        await _setUserVersion(raw, oldVersion);
        await raw.close();

        final upgraded = await _openSeam(path);
        try {
          expect(await _userVersion(upgraded), 15, reason: 'v$oldVersion');
          expect(
            (await upgraded.rawQuery('PRAGMA foreign_keys'))
                .single
                .values
                .single,
            1,
            reason: 'v$oldVersion',
          );
          expect(
            await upgraded.rawQuery('PRAGMA foreign_key_check'),
            isEmpty,
            reason: 'v$oldVersion',
          );
          expect(
            await upgraded.query('question_v2_payloads'),
            isEmpty,
            reason: 'v$oldVersion',
          );
          expect(
            await _snapshotStable(upgraded),
            stableBefore,
            reason: 'v$oldVersion',
          );
          final ids = (await upgraded.rawQuery('SELECT id FROM questions'))
              .map((row) => row['id'] as String)
              .toSet();
          expect(ids, <String>{'q_seed_1', 'q_seed_2'}, reason: 'v$oldVersion');
        } finally {
          await upgraded.close();
        }
      }
    });

    test('representative invalid sidecar schemas are rejected safely',
        () async {
      final cases = <String, (String, QuestionV2SchemaFailure)>{
        'wrong_check': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_schema_version INTEGER NOT NULL
              CHECK(payload_schema_version >= 1),
            payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
            FOREIGN KEY(question_id) REFERENCES questions(id)
              ON DELETE CASCADE
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
        'missing_check': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_schema_version INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            FOREIGN KEY(question_id) REFERENCES questions(id)
              ON DELETE CASCADE
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
        'comment_spoof_check': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_schema_version INTEGER NOT NULL
              /* CHECK(payload_schema_version > 0) */,
            payload_json TEXT NOT NULL /* CHECK(length(payload_json) > 0) */,
            FOREIGN KEY(question_id) REFERENCES questions(id)
              ON DELETE CASCADE
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
        'wrong_fk_target': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_schema_version INTEGER NOT NULL
              CHECK(payload_schema_version > 0),
            payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
            FOREIGN KEY(question_id) REFERENCES review_states(id)
              ON DELETE CASCADE
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
        'wrong_delete_action': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_schema_version INTEGER NOT NULL
              CHECK(payload_schema_version > 0),
            payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
            FOREIGN KEY(question_id) REFERENCES questions(id)
              ON DELETE RESTRICT
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
        'malformed_columns': (
          '''
          CREATE TABLE question_v2_payloads (
            question_id TEXT PRIMARY KEY NOT NULL,
            payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
            payload_schema_version INTEGER NOT NULL
              CHECK(payload_schema_version > 0),
            FOREIGN KEY(question_id) REFERENCES questions(id)
              ON DELETE CASCADE
          );
          ''',
          QuestionV2SchemaFailure.malformedSidecarSchema,
        ),
      };
      for (final entry in cases.entries) {
        final path = p.join(tempDir.path, 'r6d_invalid_${entry.key}.db');
        final created = await _openSeam(path);
        await created.close();
        final raw = await _openRaw(path);
        await raw.execute('DROP TABLE question_v2_payloads');
        await raw.execute(entry.value.$1);
        await _setUserVersion(raw, 14);
        await raw.close();
        await _expectRejectedSchema(
          path,
          entry.value.$2,
          reason: entry.key,
        );
      }
    });

    test('malformed parent questions schema is rejected safely', () async {
      final path = p.join(tempDir.path, 'r6d_invalid_parent.db');
      final created = await _openSeam(path);
      await created.close();
      final raw = await _openRaw(path);
      await raw.execute('DROP TABLE questions');
      await raw.execute('''
        CREATE TABLE questions (
          id TEXT PRIMARY KEY NOT NULL,
          type INTEGER NOT NULL,
          content TEXT NOT NULL,
          options TEXT,
          standard_answer TEXT NOT NULL,
          explanation TEXT,
          raw_explanation TEXT,
          bank_name TEXT
        );
      ''');
      await _setUserVersion(raw, 14);
      await raw.close();
      await _expectRejectedSchema(
        path,
        QuestionV2SchemaFailure.malformedParentSchema,
        reason: 'missing created_at',
      );
    });
  });

  group('transaction rollback acceptance', () {
    test(
        'mid-batch sidecar failure after the first parent rolls back all '
        'four scopes', () async {
      final db = await _singletonDb();
      await db.insert('bank_folders', <String, Object?>{
        'bank_name': _bankName,
        'folder_name': 'Math',
      });
      await db.execute('''
        CREATE TRIGGER r6d_block_second_payload
        BEFORE INSERT ON question_v2_payloads
        WHEN (SELECT COUNT(*) FROM question_v2_payloads) >= 1
        BEGIN SELECT RAISE(ABORT, 'r6d_synthetic_second_payload_failure'); END;
      ''');

      final repository = QuestionRepository();
      QuestionV2WriteException? caught;
      try {
        await repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: 'Physics',
          questions: <QuestionDraftV2>[_draftA(), _draftB()],
        );
      } on QuestionV2WriteException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure, QuestionV2WriteFailure.transactionFailed);
      expect(
        caught.toString(),
        'QuestionV2WriteException(transactionFailed): '
        'The typed question batch cannot be written atomically.',
      );
      expect(caught.toString(),
          isNot(contains('r6d_synthetic_second_payload_failure')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(caught.toString(), isNot(contains('Physics')));
      expect(
        () => (caught as dynamic).cause,
        throwsA(isA<NoSuchMethodError>()),
      );

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      final folders = await db.query('bank_folders');
      expect(folders, hasLength(1));
      expect(folders.single['folder_name'], 'Math');
    });

    test(
        'folder upsert failure rolls back parents, sidecars, states, and '
        'folder', () async {
      final db = await _singletonDb();
      await db.execute('''
        CREATE TRIGGER r6d_block_folder
        BEFORE INSERT ON bank_folders
        BEGIN SELECT RAISE(ABORT, 'r6d_synthetic_folder_failure'); END;
      ''');

      final repository = QuestionRepository();
      QuestionV2WriteException? caught;
      try {
        await repository.saveQuestionDraftsV2ToBank(
          bankName: _bankName,
          folderName: 'Math',
          questions: <QuestionDraftV2>[_draftA(), _draftB()],
        );
      } on QuestionV2WriteException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.failure, QuestionV2WriteFailure.transactionFailed);
      expect(
          caught.toString(), isNot(contains('r6d_synthetic_folder_failure')));
      expect(caught.toString(), isNot(contains(_bankName)));
      expect(caught.toString(), isNot(contains('Math')));

      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
      expect(await db.query('review_states'), isEmpty);
      expect(await db.query('bank_folders'), isEmpty);
    });
  });
}
