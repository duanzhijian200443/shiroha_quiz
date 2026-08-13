// P6-C0 atomic confirm boundary acceptance.
//
// All databases are synthetic sqflite FFI in-memory handles. No real
// application database, private document, OCR, Replay, Provider, or network
// path is touched. The tests prove that artifact generation recheck, typed
// target CAS, and the shared typed answer kernel run inside one caller-owned
// transaction with zero writes on any stale/invalid condition.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/supplemental_answer_persistence_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _bankName = 'synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _fileId = 'file_001';
const _artifactId = 'artifact_001';
const _mapper = QuestionV2PersistenceMapper();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('p6_c0_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('P6-C0 atomic confirm', () {
    test('fill commits through the shared kernel in one transaction', () async {
      await _seedTarget();
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.fill,
      );

      await repository.confirmCandidate(candidate);

      final db = await _singletonDb();
      final payload = (await db.query('question_v2_payloads')).single;
      final decoded = jsonDecode(payload['payload_json']! as String)
          as Map<String, dynamic>;
      expect(decoded['answer'], isNotNull);
      expect(
        (await db.query('questions')).single['standard_answer'],
        isNot(isEmpty),
      );
      final review = await db.query('review_states');
      expect(review.single['state'], 0,
          reason: 'review state must stay untouched');
    });

    test('artifact generation drift fails stale with zero writes', () async {
      await _seedTarget();
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(),
        artifactRevision: 1,
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );

      final db = await _singletonDb();
      expect(
        jsonDecode(
          (await db.query('question_v2_payloads')).single['payload_json']!
              as String,
        )['answer'],
        isNull,
      );
      expect(
        (await db.query('questions')).single['standard_answer'],
        '|||',
      );
    });

    test('target draft drift fails stale with zero writes', () async {
      await _seedTarget(answer: _text('x = 9'));
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );
      expect(await _answerNodes(), ['x = 9']);
    });

    test('fill precondition fails stale when an answer already exists',
        () async {
      await _seedTarget(answer: _text('x = 9'));
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(answer: _text('x = 9')),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );
      expect(await _answerNodes(), ['x = 9']);
    });

    test('replace commits only when the current answer differs', () async {
      await _seedTarget(answer: _text('x = 9'));
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(answer: _text('x = 9')),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.replace,
      );

      await repository.confirmCandidate(candidate);

      expect(await _answerNodes(), ['x = 1']);
    });

    test('noOp never reaches the write boundary', () async {
      await _seedTarget(answer: _text('x = 1'));
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(answer: _text('x = 1')),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.noOp,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.invalidCandidate,
          ),
        ),
      );
      expect(await _answerNodes(), ['x = 1']);
    });

    test('missing target fails stale', () async {
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );
    });

    test('bank drift fails stale', () async {
      await _seedTarget(bankName: 'other_bank');
      await _seedArtifact(revision: 2);
      final repository = SupplementalAnswerPersistenceRepository();
      final candidate = _candidate(
        expectedDraft: _draft(),
        artifactRevision: 2,
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository.confirmCandidate(candidate),
        throwsA(
          isA<SupplementalAnswerException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerFailure.staleTarget,
          ),
        ),
      );
      expect(await _answerNodes(), isEmpty);
    });
  });
}

Future<Database> _singletonDb() => DatabaseHelper.instance.database;

Future<void> _seedTarget({
  RichContent? answer,
  String bankName = _bankName,
}) async {
  final db = await _singletonDb();
  final frozen = _mapper.freezeForWrite(
    storageId: _storageId,
    bankName: bankName,
    createdAt: 1,
    draft: _draft(answer: answer),
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': _storageId,
    'state': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'next_review_time': 0,
    'reps': 0,
    'lapses': 0,
  });
}

Future<void> _seedArtifact({required int revision}) async {
  final db = await _singletonDb();
  await db.insert('library_files', <String, Object?>{
    'file_id': _fileId,
    'display_name': 'synthetic.pdf',
    'mime_type': 'application/pdf',
    'size_bytes': 1,
    'sha256': 'c' * 64,
    'storage_key': 'p6/library-$_fileId',
    'created_at': 1,
  });
  await db.insert('parsed_artifact_heads', <String, Object?>{
    'file_id': _fileId,
    'last_revision': revision,
  });
  await db.insert('parsed_artifacts', <String, Object?>{
    'file_id': _fileId,
    'artifact_id': _artifactId,
    'revision': revision,
    'source_sha256': 'a' * 64,
    'cache_key_version': 1,
    'cache_fingerprint': 'fingerprint',
    'parser_route': 'pdf_text',
    'parser_version': '1.0',
    'options_schema_version': 1,
    'payload_schema_version': 1,
    'storage_key': 'p6/storage-$revision',
    'payload_sha256': 'b' * 64,
    'size_bytes': 1,
    'published_at': 1,
  });
}

Future<List<String>> _answerNodes() async {
  final db = await _singletonDb();
  final payload = (await db.query('question_v2_payloads')).single;
  final decoded =
      jsonDecode(payload['payload_json']! as String) as Map<String, dynamic>;
  final answer = decoded['answer'] as Map<String, dynamic>?;
  if (answer == null) return const <String>[];
  final content = answer['content'] as Map<String, dynamic>;
  return (content['nodes'] as List<dynamic>)
      .map((node) => (node as Map<String, dynamic>)['text'] as String)
      .toList();
}

QuestionDraftV2 _draft({RichContent? answer}) {
  return QuestionDraftV2(
    questionId: 'q_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text('stem'),
    answer: answer == null ? null : ContentAnswer(content: answer),
    sourceRefs: [
      SourceRef.document(sourceId: _artifactId),
    ],
  );
}

AnswerCandidate _candidate({
  required QuestionDraftV2 expectedDraft,
  required int artifactRevision,
  required CandidateWriteIntent writeIntent,
}) {
  return AnswerCandidate(
    candidateId: 'cand_frag_1_q_1',
    targetStorageId: _storageId,
    targetBankName: _bankName,
    expectedDraft: expectedDraft,
    supplementalFileId: _fileId,
    artifactId: _artifactId,
    artifactRevision: artifactRevision,
    answer: ContentAnswer(content: _text('x = 1')),
    supplementalSourceRefs: [
      SourceRef.document(sourceId: _artifactId),
    ],
    matchEvidence: const [],
    writeIntent: writeIntent,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
