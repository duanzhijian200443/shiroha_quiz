/// Synthetic in-memory database support for the T0 study query tests.
///
/// All databases are synthetic sqflite FFI in-memory handles opened through
/// the frozen [DatabaseHelper] seam. No real application database, private
/// document, OCR, Replay, Provider, or network path is touched.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const QuestionV2PersistenceMapper testMapper = QuestionV2PersistenceMapper();

const String bankMath = 'Math';
const String bankPhysics = 'Physics';
const String bankThird = 'ThirdBank';
const String bankCorrupt = 'CorruptBank';
const String uncategorizedFolder = '📁 未分类题库';

/// Canonical synthetic UUIDv4 storage ids.
const String idTyped1 = '11111111-1111-4111-8111-111111111111';
const String idTyped2 = '22222222-2222-4222-8222-222222222222';
const String idTyped5 = '55555555-5555-4555-8555-555555555555';
const String idCorrupt = '99999999-9999-4999-8999-999999999999';

RichContent textContent(String value) {
  return RichContent(nodes: <ContentNode>[TextNode(value)]);
}

RichContent richContent(List<ContentNode> nodes) {
  return RichContent(nodes: nodes);
}

/// Raw fallback node payload with a safe, non-forbidden marker key.
Map<String, Object?> rawFallbackPayload(String marker) {
  return <String, Object?>{
    'type': 'raw_fallback',
    'payload': <String, Object?>{'marker': marker},
  };
}

QuestionOption optionA() {
  return QuestionOption(
    optionId: 'A',
    label: 'A',
    content: textContent('one'),
  );
}

QuestionOption optionB() {
  return QuestionOption(
    optionId: 'B',
    label: 'B',
    content: textContent('two'),
  );
}

QuestionDraftV2 makeDraft(
  String questionId, {
  RichContent? stem,
  QuestionKind kind = QuestionKind.singleChoice,
  List<QuestionOption> options = const <QuestionOption>[],
  QuestionAnswer? answer,
  RichContent? explanation,
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: kind,
    stem: stem ?? textContent('Synthetic stem $questionId'),
    options: options,
    answer: answer,
    explanation: explanation,
  );
}

Future<void> initTestDatabaseFactory() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Future<void> resetTestDatabase() async {
  await DatabaseHelper.resetRuntimeProfileForTesting();
}

Future<Database> openTestDatabase() {
  return DatabaseHelper.instance.database;
}

Future<void> insertTypedQuestion(
  Database db, {
  required QuestionDraftV2 draft,
  required String storageId,
  required int createdAt,
  required String bankName,
}) async {
  final frozen = testMapper.freezeForWrite(
    storageId: storageId,
    bankName: bankName,
    createdAt: createdAt,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
}

Future<void> insertLegacyQuestion(
  Database db, {
  required String id,
  required int createdAt,
  required String bankName,
  String content = 'Legacy stem text.',
  int type = 3,
  String options = '["A. one","B. two"]',
  String answer = 'Legacy answer',
  String? explanation = 'Legacy explanation.',
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': type,
    'content': content,
    'options': options,
    'standard_answer': explanation == null ? answer : '$answer|||$explanation',
    'explanation': explanation,
    'raw_explanation': null,
    'created_at': createdAt,
    'bank_name': bankName,
  });
}

Future<void> insertReviewState(
  Database db, {
  required String questionId,
  int state = 0,
  int nextReviewTime = 0,
  int lapses = 0,
  double difficulty = 5.0,
  int lastLapseTime = 0,
}) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': state,
    'next_review_time': nextReviewTime,
    'lapses': lapses,
    'difficulty': difficulty,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': lastLapseTime,
    'last_review_time': 0,
  });
}

Future<void> insertReviewLog(
  Database db, {
  required String questionId,
  required int reviewTime,
}) async {
  await db.insert('review_logs', <String, Object?>{
    'id': 'log_${questionId}_$reviewTime',
    'question_id': questionId,
    'grade': 1,
    'llm_score': null,
    'review_time': reviewTime,
    'duration_ms': 1000,
    'user_answer': null,
    'ai_evaluation': null,
  });
}

/// Corrupts the sidecar of an existing typed row (synthetic).
Future<void> corruptSidecar(
  Database db, {
  required String storageId,
}) async {
  await db.update(
    'question_v2_payloads',
    <String, Object?>{'payload_json': '{oops'},
    where: 'question_id = ?',
    whereArgs: <Object?>[storageId],
  );
}

int unixSeconds(String iso) {
  return DateTime.parse(iso).toUtc().millisecondsSinceEpoch ~/ 1000;
}

/// Seeds synthetic non-empty rows in the frozen v16/v17 J0 metadata tables
/// (`library_files`, `projects`, `project_files`, `project_banks`) so the
/// READ_ONLY proof snapshot covers rows that a write would mutate.
Future<void> insertJ0MetadataRows(Database db) async {
  const String fileId = '11111111-1111-4111-8111-aaaaaaaaaaaa';
  const String projectId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  final createdAt = unixSeconds('2026-08-08T10:00:00Z');

  await db.insert('library_files', <String, Object?>{
    'file_id': fileId,
    'display_name': 'Synthetic J0 library file',
    'mime_type': 'application/pdf',
    'size_bytes': 1234,
    'sha256': 'a' * 64,
    'storage_key': 'j0/synthetic/library.pdf',
    'created_at': createdAt,
  });
  await db.insert('projects', <String, Object?>{
    'project_id': projectId,
    'display_name': 'Synthetic J0 project',
    'created_at': createdAt,
  });
  await db.insert('project_files', <String, Object?>{
    'project_id': projectId,
    'file_id': fileId,
  });
  await db.insert('project_banks', <String, Object?>{
    'project_id': projectId,
    'bank_name': bankMath,
  });
}

/// Canonical row snapshots of the seven tables the READ_ONLY proof covers.
Future<List<String>> snapshotCoreTables(Database db) async {
  return <String>[
    for (final table in <String>[
      'questions',
      'question_v2_payloads',
      'review_states',
      'library_files',
      'projects',
      'project_files',
      'project_banks',
    ])
      jsonEncode(await db.query(table, orderBy: 'rowid')),
  ];
}
