// P7-C0 transactional AI commit boundary acceptance.
//
// All databases are synthetic sqflite FFI in-memory handles; no real
// application database, private document, provider, or network path is
// touched. The tests prove that durable-target revalidation, the write-intent
// precondition, and the shared typed answer kernel run inside one
// caller-owned transaction with zero writes on any stale/invalid condition,
// full rollback on a physical failure, and answer-only persistence.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/ai_answer_commit_repository.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _bankName = 'synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
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
    tempDir = await Directory.systemTemp.createTemp('p7_c0_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  AiAnswerCommitRepository repository() => AiAnswerCommitRepository();

  group('P7-C0 transactional commit', () {
    test('fill commits exactly one answer-only mutation', () async {
      await _seedTarget();
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await repository().commitAnswer(candidate);

      expect(await _answerNodes(), ['x = 1']);
      final db = await _singletonDb();
      expect(
        (await db.query('questions')).single['standard_answer'],
        isNot(isEmpty),
      );
      final review = await db.query('review_states');
      expect(review.single['state'], 0,
          reason: 'review state must stay untouched');
    });

    test('replace commits only when the current answer differs', () async {
      await _seedTarget(answer: _text('x = 9'));
      final candidate = _candidate(
        expectedDraft: _draft(answer: _text('x = 9')),
        writeIntent: CandidateWriteIntent.replace,
      );

      await repository().commitAnswer(candidate);

      expect(await _answerNodes(), ['x = 1']);
    });

    test('noOp never reaches the write boundary', () async {
      await _seedTarget();
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.noOp,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(await _answerNodes(), isEmpty);
    });

    test('non-AI origin is rejected before any transaction', () async {
      await _seedTarget();
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
        origin: _supplementalOrigin(),
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(await _answerNodes(), isEmpty);
    });
  });

  group('stale durable matrix', () {
    test('bank change fails stale with zero writes', () async {
      await _seedTarget(bankName: 'other_bank');
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await _answerNodes(), isEmpty);
    });

    test('complete draft change fails stale with zero writes', () async {
      await _seedTarget(draft: _draft(stemText: 'changed stem'));
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await _answerNodes(), isEmpty);
    });

    test('answer already filled fails the fill precondition stale', () async {
      await _seedTarget(answer: _text('x = 9'));
      final candidate = _candidate(
        expectedDraft: _draft(answer: _text('x = 9')),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await _answerNodes(), ['x = 9']);
    });

    test('replace precondition fails when the current answer vanished',
        () async {
      await _seedTarget();
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.replace,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await _answerNodes(), isEmpty);
    });

    test('deleted target fails stale', () async {
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
    });

    test('legacy target fails closed', () async {
      await _seedTarget(legacyOnly: true);
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
    });
  });

  group('J. competing candidates', () {
    test(
        'first compatible commit wins; second becomes stale with one '
        'formal mutation', () async {
      await _seedTarget();
      final first = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
        answer: _text('x = 1'),
      );
      final second = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
        answer: _text('x = 2'),
        candidateId: 'cand_second',
      );

      await repository().commitAnswer(first);
      await expectLater(
        repository().commitAnswer(second),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );

      expect(await _answerNodes(), ['x = 1'],
          reason: 'exactly one compatible formal mutation');
    });
  });

  group('K. transaction rollback', () {
    test('second physical update failure rolls back the whole transaction',
        () async {
      await _seedTarget();
      final db = await _singletonDb();
      await db.execute(
        'CREATE TRIGGER p7_fail_questions BEFORE UPDATE ON questions '
        'BEGIN SELECT RAISE(FAIL, \'synthetic failure\'); END',
      );
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
      );

      await expectLater(
        repository().commitAnswer(candidate),
        _commitFailure(AiAnswerCommitFailure.persistenceFailed),
      );

      // The payload UPDATE happened before the failing questions UPDATE;
      // the whole transaction must have rolled back.
      expect(await _answerNodes(), isEmpty);
      expect(
        (await _singletonDb().then((db) => db.query('questions')))
            .single['standard_answer'],
        '|||',
      );
    });
  });

  group('M. privacy', () {
    test('no candidate provenance or session data enters SQLite', () async {
      await _seedTarget();
      const sentinelCandidateId = 'SENTINEL_CANDIDATE_ID';
      const sentinelGeneration = 'SENTINEL_GENERATION';
      const sentinelProfile = 'SENTINEL_PROFILE';
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
        candidateId: sentinelCandidateId,
        origin: AiAnswerOrigin(
          generationId: sentinelGeneration,
          providerProfileId: sentinelProfile,
          generatedAtUtc: DateTime.utc(2026, 8, 20, 12),
        ),
      );

      await repository().commitAnswer(candidate);

      final db = await _singletonDb();
      final payload = (await db.query('question_v2_payloads'))
          .single['payload_json']! as String;
      final questions =
          (await db.query('questions')).single['standard_answer']! as String;
      for (final sentinel in [
        sentinelCandidateId,
        sentinelGeneration,
        sentinelProfile,
        'cand_',
        'sessionRevision',
      ]) {
        expect(payload, isNot(contains(sentinel)));
        expect(questions, isNot(contains(sentinel)));
      }
      expect(payload, contains('x = 1'));
    });

    test('stale failures never leak candidate provenance', () async {
      await _seedTarget(bankName: 'other_bank');
      final candidate = _candidate(
        expectedDraft: _draft(),
        writeIntent: CandidateWriteIntent.fill,
        candidateId: 'SENTINEL_CAND_ID',
        origin: AiAnswerOrigin(
          generationId: 'SENTINEL_GEN',
          providerProfileId: 'SENTINEL_PROFILE',
          generatedAtUtc: DateTime.utc(2026, 8, 20, 12),
        ),
      );
      try {
        await repository().commitAnswer(candidate);
        fail('expected a typed commit failure');
      } on AiAnswerCommitException catch (error) {
        expect(error.failure, AiAnswerCommitFailure.staleTarget);
        expect(error.toString(), isNot(contains('SENTINEL')));
      }
    });
  });
}

Future<Database> _singletonDb() => DatabaseHelper.instance.database;

Future<void> _seedTarget({
  RichContent? answer,
  String bankName = _bankName,
  QuestionDraftV2? draft,
  bool legacyOnly = false,
}) async {
  final db = await _singletonDb();
  final frozen = _mapper.freezeForWrite(
    storageId: _storageId,
    bankName: bankName,
    createdAt: 1,
    draft: draft ?? _draft(answer: answer),
  );
  await db.insert('questions', frozen.questionRow);
  if (!legacyOnly) {
    await db.insert('question_v2_payloads', frozen.payloadRow);
  }
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

QuestionDraftV2 _draft({RichContent? answer, String stemText = 'stem'}) {
  return QuestionDraftV2(
    questionId: 'q_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text(stemText),
    answer: answer == null ? null : ContentAnswer(content: answer),
  );
}

AnswerCandidate _candidate({
  required QuestionDraftV2 expectedDraft,
  required CandidateWriteIntent writeIntent,
  RichContent? answer,
  String candidateId = 'cand_001',
  AnswerCandidateOrigin? origin,
}) {
  return AnswerCandidate(
    candidateId: candidateId,
    targetStorageId: _storageId,
    targetBankName: _bankName,
    expectedDraft: expectedDraft,
    answer: ContentAnswer(content: answer ?? _text('x = 1')),
    writeIntent: writeIntent,
    origin: origin ??
        AiAnswerOrigin(
          generationId: 'gen_001',
          providerProfileId: 'engine_001',
          generatedAtUtc: DateTime.utc(2026, 8, 20, 12),
        ),
  );
}

SupplementalAnswerOrigin _supplementalOrigin() {
  return SupplementalAnswerOrigin(
    supplementalFileId: 'file_001',
    artifactId: 'artifact_001',
    artifactRevision: 1,
    supplementalSourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
    matchEvidence: const [MatchEvidenceCode.uniqueMainNumber],
  );
}

Matcher _commitFailure(AiAnswerCommitFailure failure) {
  return throwsA(
    isA<AiAnswerCommitException>().having(
      (error) => error.failure,
      'failure',
      failure,
    ),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
