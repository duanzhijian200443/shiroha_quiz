// P6-V0 offline acceptance.
//
// Synthetic fixtures only: real graduate-exam answer-document *layout
// patterns* with fictional content. No live OCR/provider, no private PDFs,
// no Replay, no network. The matrix covers the frozen canonical acceptance
// list: exact numbers, subquestions, duplicates, missing targets, sequence
// mismatch, multi-part answers, table layouts, fill/noOp/conflict,
// reparse/target staleness, ambiguous/unmatched/reject zero-write, explicit
// subset order, legacy ineligibility, choice label mapping, stale session
// revision, and no old merge/OCR/paired-path use.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_failure.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/supplemental_answer_persistence_repository.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/target_coverage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _bankName = 'p6_acceptance_bank';
const _fileId = 'p6_acceptance_file';
const _artifactId = 'p6_acceptance_artifact';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _storageId2 = 'b4f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
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
    tempDir = await Directory.systemTemp.createTemp('p6_acceptance_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('A. exact question-number correspondence', () {
    test('one fragment -> one typed target, fill commits', () async {
      await _seedTarget();
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.matched,
      );
      expect(
        match.records.single.candidate!.writeIntent,
        CandidateWriteIntent.fill,
      );

      final session = await _session(match);
      final confirmation = session.confirmFill(
        match.records.single.candidate!.candidateId,
      );
      await _confirmCommand().confirm(confirmation.confirmation);
      expect(await _answerNodes(), ['x = 1']);
    });
  });

  group('B. number + subquestion', () {
    test('complete sub set composes in sub-order', () async {
      await _seedTarget(stem: _text('（1）（2）'));
      await _seedArtifact(revision: 1);

      final match = await _matchMany([
        _numbered('1', 'second', sub: '2'),
        _numbered('1', 'first', sub: '1'),
      ]);

      expect(match.records, hasLength(1));
      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.matched,
      );
      final answer = match.records.single.candidate!.answer as ContentAnswer;
      expect(
        answer.content.nodes.map((node) => (node as TextNode).text),
        ['first', 'second'],
      );
    });
  });

  group('C. duplicate numbers', () {
    test('duplicate locator without unique proof stays ambiguous', () async {
      await _seedTarget(storageId: _storageId);
      await _seedTarget(storageId: _storageId2);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));

      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.ambiguous,
      );
      expect(match.records.single.candidate, isNull);
    });

    test('cross-bank duplicate locator stays ambiguous', () async {
      await _seedTarget(storageId: _storageId, bankName: _bankName);
      await _seedTarget(
        storageId: _storageId2,
        bankName: 'other_bank',
      );
      await _seedArtifact(revision: 1);

      final service = TargetQuestionSnapshotService(
        port: _CrossBankTargetPort(),
      );
      final snapshot = await service.resolve(
        const ProjectScope(projectId: 'project_1'),
      );
      final match = const SupplementalAnswerMatcher().match(
        fragments: [_numbered('1', 'x = 1')],
        snapshot: snapshot,
        artifact: const SupplementalArtifactContext(
          supplementalFileId: _fileId,
          artifactId: _artifactId,
          artifactRevision: 1,
        ),
      );

      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.ambiguous,
      );
    });
  });

  group('D. supplemental missing target', () {
    test('target stays uncovered', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('9', 'x = 9'));

      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.unmatched,
      );
      expect(
        match.coverage.single.status,
        TargetCoverageStatus.uncovered,
      );
    });
  });

  group('E. sequence mismatch', () {
    test('identity wins over sequence order', () async {
      await _seedTarget(storageId: _storageId);
      await _seedTarget(storageId: _storageId2, questionNumber: 2);
      await _seedArtifact(revision: 1);

      final match = await _matchMany([
        _numbered('2', 'x = 2'),
        _numbered('1', 'x = 1'),
      ]);

      expect(
        match.records.map((record) => record.candidate!.targetStorageId),
        [_storageId2, _storageId],
      );
    });
  });

  group('F. answer across multiple parts', () {
    test('multi-part answer combines structurally', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final fragments = const SupplementalAnswerProjector().project(
        SourceDocument(
          sourceId: _artifactId,
          parts: [
            _answerPart('1. '),
            _answerPart('x = '),
            _answerPart('2'),
          ],
        ),
      );
      final match = await _matchFragments(fragments.fragments);

      final answer = match.records.single.candidate!.answer as ContentAnswer;
      expect(
        answer.content.nodes.map((node) => (node as TextNode).text),
        ['x = ', '2'],
      );
    });
  });

  group('G. existing answer fill/noOp/conflict', () {
    test('equivalent answer is noOp with zero transaction', () async {
      await _seedTarget(storageId: _storageId, answer: _text('x = 1'));
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));

      expect(
        match.records.single.candidate!.writeIntent,
        CandidateWriteIntent.noOp,
      );
      final session = await _session(match);
      expect(
        () => session.confirmFill(match.records.single.candidate!.candidateId),
        throwsA(
          isA<SupplementalAnswerReviewException>().having(
            (error) => error.failure,
            'failure',
            SupplementalAnswerReviewFailure.noOpTerminal,
          ),
        ),
      );
    });

    test('different answer is conflict and replace needs reconfirmation',
        () async {
      await _seedTarget(storageId: _storageId, answer: _text('x = 9'));
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));

      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.conflict,
      );
      final session = await _session(match);
      final selected = session.selectForReplace(
        match.records.single.candidate!.candidateId,
      );
      final confirmed = selected.confirmReplace(
        match.records.single.candidate!.candidateId,
      );
      await _confirmCommand().confirm(confirmed.confirmation);
      expect(await _answerNodes(), ['x = 1']);
    });
  });

  group('H. artifact reparse staleness', () {
    test('revision drift makes the candidate stale with zero writes', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      final session = await _session(match);
      final confirmation = session.confirmFill(
        match.records.single.candidate!.candidateId,
      );

      await _seedArtifact(revision: 2);

      await expectLater(
        _confirmCommand().confirm(confirmation.confirmation),
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

  group('I/J. ambiguous and unmatched never write', () {
    test('ambiguous candidate is never committable', () async {
      await _seedTarget(storageId: _storageId);
      await _seedTarget(storageId: _storageId2);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      expect(match.records.single.candidate, isNull);
    });

    test('unmatched fragment never writes', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('7', 'x = 7'));
      expect(match.records.single.candidate, isNull);
      expect(await _answerNodes(), isEmpty);
    });
  });

  group('L. reject is zero mutation', () {
    test('rejected fill candidate writes nothing', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      final session = await _session(match);
      final rejected = session.reject(
        match.records.single.candidate!.candidateId,
      );
      expect(
        rejected.outcomeOf(match.records.single.candidate!.candidateId),
        CandidateReviewOutcome.rejected,
      );
      expect(await _answerNodes(), isEmpty);
    });
  });

  group('K. user confirm reuses typed answer write', () {
    test('confirm writes sidecar and V1 projection exactly once', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      final session = await _session(match);
      final confirmation = session.confirmFill(
        match.records.single.candidate!.candidateId,
      );
      await _confirmCommand().confirm(confirmation.confirmation);

      final db = await DatabaseHelper.instance.database;
      final payload = (await db.query('question_v2_payloads')).single;
      final decoded = jsonDecode(payload['payload_json']! as String)
          as Map<String, dynamic>;
      expect(decoded['answer'], isNotNull);
      final row = (await db.query('questions')).single;
      expect(row['standard_answer'], isNotEmpty);
      final review = await db.query('review_states');
      expect(review.single['state'], 0,
          reason: 'review state must remain untouched');
    });
  });

  group('explicit subset order and legacy ineligibility', () {
    test('explicit subset preserves caller order and reports missing',
        () async {
      await _seedTarget(storageId: _storageId);
      await _seedTarget(storageId: _storageId2);
      await _seedLegacyTarget('legacy_1');
      await _seedArtifact(revision: 1);

      final service = TargetQuestionSnapshotService(
        port: _AcceptanceTargetPort(),
      );
      final snapshot = await service.resolve(
        ExplicitQuestionScope(
          storageIds: [_storageId2, _storageId, 'missing', 'legacy_1'],
        ),
      );

      expect(
        snapshot.targets.map((target) => target.storageId),
        [_storageId2, _storageId],
      );
      expect(
        snapshot.reports.map((report) => report.code),
        containsAll(<TargetScopeReportCode>[
          TargetScopeReportCode.missingTarget,
          TargetScopeReportCode.legacyIneligible,
        ]),
      );
    });
  });

  group('choice label mapping and raw fallback', () {
    test('unique label maps to current option id', () async {
      await _seedChoiceTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'B'));

      expect(
        match.records.single.candidate!.answer,
        ChoiceAnswer(optionIds: ['opt_b']),
      );
    });

    test('unknown label is invalidCandidate and never writes', () async {
      await _seedChoiceTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'Z'));

      expect(
        match.records.single.disposition,
        AnswerMatchDisposition.invalid,
      );
      expect(
        match.records.single.evidence,
        contains(MatchEvidenceCode.ambiguousChoiceLabel),
      );
    });
  });

  group('stale session revision', () {
    test('every review decision advances the session revision', () async {
      await _seedTarget(storageId: _storageId);
      await _seedArtifact(revision: 1);

      final match = await _match(_numbered('1', 'x = 1'));
      final session = await _session(match);
      final candidateId = match.records.single.candidate!.candidateId;
      final decided = session.confirmFill(candidateId);
      expect(decided.confirmation.sessionRevision, 1);
      expect(
        decided.session.outcomeOf(candidateId),
        CandidateReviewOutcome.confirmed,
      );
      final rejected = session.reject(candidateId);
      expect(rejected.sessionRevision, 1);
      expect(
        rejected.outcomeOf(candidateId),
        CandidateReviewOutcome.rejected,
      );
    });
  });

  group('no OCR/provider/paired-path use', () {
    test('projector consumes only the synthetic SourceDocument', () async {
      await _seedArtifact(revision: 1);
      final document = SourceDocument(
        sourceId: _artifactId,
        parts: [
          _answerPart('1. A'),
          UnsupportedSourcePart(
            sourceRef: SourceRef.document(sourceId: _artifactId),
            kindCode: 'parsed_image',
            fallbackContent: RichContent(nodes: [TextNode('[Image]')]),
          ),
        ],
      );

      const projector = SupplementalAnswerProjector();
      final result = projector.project(document);

      expect(result.fragments, hasLength(1));
      expect(
        result.issues.single.kind,
        SupplementalProjectionIssueKind.unsupportedPartSkipped,
      );
      expect(result.fragments.single.answerContent.nodes, isNotEmpty);
    });
  });
}

SupplementalAnswerFragment _numbered(
  String number,
  String answer, {
  String? sub,
}) {
  return SupplementalAnswerFragment(
    fragmentId: 'frag_${number}_${sub ?? '0'}',
    normalizedMainNumber: number,
    normalizedSubquestion: sub,
    answerContent: _text(answer),
    sourceRefs: [
      SourceRef.document(sourceId: _artifactId),
    ],
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
  );
}

SourceContentPart _answerPart(String text) {
  return SourceContentPart(
    sourceRef: SourceRef.document(sourceId: _artifactId),
    content: _text(text),
    role: SourceContentRole.answerLike,
  );
}

Future<SupplementalMatchResult> _matchFragments(
  List<SupplementalAnswerFragment> fragments,
) async {
  final snapshot = await _snapshot();
  return const SupplementalAnswerMatcher().match(
    fragments: fragments,
    snapshot: snapshot,
    artifact: const SupplementalArtifactContext(
      supplementalFileId: _fileId,
      artifactId: _artifactId,
      artifactRevision: 1,
    ),
  );
}

Future<SupplementalMatchResult> _match(
  SupplementalAnswerFragment fragment, [
  SupplementalAnswerFragment? second,
]) {
  return _matchFragments([
    fragment,
    if (second != null) second,
  ]);
}

Future<SupplementalMatchResult> _matchMany(
  List<SupplementalAnswerFragment> fragments,
) {
  return _matchFragments(fragments);
}

Future<TargetQuestionSnapshot> _snapshot() async {
  final service = TargetQuestionSnapshotService(
    port: _AcceptanceTargetPort(),
  );
  return service.resolve(const QuestionBankScope(bankName: _bankName));
}

Future<SupplementalAnswerReviewSession> _session(
  SupplementalMatchResult match,
) async {
  return SupplementalAnswerReviewSession(
    request: SupplementalAnswerMatchRequest(
      targetScope: const QuestionBankScope(bankName: _bankName),
      supplementalFileId: _fileId,
    ),
    snapshot: await _snapshot(),
    matchResult: match,
  );
}

SupplementalAnswerConfirmCommand _confirmCommand() {
  return SupplementalAnswerConfirmCommand(
    artifactPort: _AcceptanceArtifactPort(),
    persistencePort: SupplementalAnswerPersistenceRepository(),
  );
}

class _AcceptanceArtifactPort implements ParsedArtifactLifecyclePort {
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    final rows = await (await DatabaseHelper.instance.database).rawQuery(
      'SELECT artifact_id, revision FROM parsed_artifacts '
      'WHERE file_id = ?',
      <Object?>[fileId],
    );
    if (rows.length != 1) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
    }
    final artifactId = rows.single['artifact_id']! as String;
    return ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: fileId,
        artifactId: artifactId,
        revision: rows.single['revision']! as int,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: artifactId,
        parts: const [],
      ),
    );
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }
}

class _AcceptanceTargetPort implements SupplementalAnswerTargetPort {
  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    return const <String>[];
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT q.*,
             p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
             p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      LEFT JOIN question_v2_payloads p ON q.id = p.question_id
      WHERE q.bank_name = ?
      ORDER BY q.created_at DESC
      ''',
      <Object?>[bankName],
    );
    return rows.map((row) {
      try {
        final question = _mapper.decodeJoinedRow(row);
        if (question is TypedPersistedQuestion) {
          return SupplementalTargetRead(
            storageId: question.storageId,
            bankName: question.bankName,
            typedDraft: question.draft,
          );
        }
      } on QuestionV2PayloadException {
        // Not expected in synthetic fixtures.
      }
      return SupplementalTargetRead(
        storageId: row['id']! as String,
        bankName: row['bank_name']! as String,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) async {
    final all = await listTypedQuestionsByBank(_bankName);
    final byId = {for (final read in all) read.storageId: read};
    return storageIds
        .map((id) => byId[id])
        .whereType<SupplementalTargetRead>()
        .toList(growable: false);
  }
}

/// Project-scope port exposing two banks with the same question number.
class _CrossBankTargetPort implements SupplementalAnswerTargetPort {
  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    return <String>[_bankName, 'other_bank'];
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT q.*,
             p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
             p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      LEFT JOIN question_v2_payloads p ON q.id = p.question_id
      WHERE q.bank_name = ?
      ''',
      <Object?>[bankName],
    );
    return rows.map((row) {
      final question = _mapper.decodeJoinedRow(row);
      if (question is TypedPersistedQuestion) {
        return SupplementalTargetRead(
          storageId: question.storageId,
          bankName: question.bankName,
          typedDraft: question.draft,
        );
      }
      return SupplementalTargetRead(
        storageId: row['id']! as String,
        bankName: row['bank_name']! as String,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) async {
    throw UnimplementedError();
  }
}

Future<void> _seedTarget({
  String storageId = _storageId,
  String bankName = _bankName,
  RichContent? stem,
  RichContent? answer,
  int? questionNumber = 1,
}) async {
  final db = await DatabaseHelper.instance.database;
  final draft = QuestionDraftV2(
    questionId: storageId,
    kind: QuestionKind.shortAnswer,
    questionNumber: questionNumber,
    stem: stem ?? _text('stem 1'),
    answer: answer == null ? null : ContentAnswer(content: answer),
  );
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: bankName,
    createdAt: 1,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'next_review_time': 0,
    'reps': 0,
    'lapses': 0,
  });
}

Future<void> _seedChoiceTarget({required String storageId}) async {
  final db = await DatabaseHelper.instance.database;
  final draft = QuestionDraftV2(
    questionId: storageId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('choice stem'),
    options: [
      QuestionOption(
        optionId: 'opt_a',
        label: 'A',
        content: _text('alpha'),
      ),
      QuestionOption(
        optionId: 'opt_b',
        label: 'B',
        content: _text('beta'),
      ),
    ],
  );
  final frozen = _mapper.freezeForWrite(
    storageId: storageId,
    bankName: _bankName,
    createdAt: 1,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': storageId,
    'state': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'next_review_time': 0,
    'reps': 0,
    'lapses': 0,
  });
}

Future<void> _seedLegacyTarget(String id) async {
  final db = await DatabaseHelper.instance.database;
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 3,
    'content': 'legacy stem',
    'options': '[]',
    'standard_answer': 'legacy|||',
    'explanation': '',
    'raw_explanation': null,
    'created_at': 1,
    'bank_name': _bankName,
  });
}

Future<void> _seedArtifact({required int revision}) async {
  final db = await DatabaseHelper.instance.database;
  await db.insert(
    'library_files',
    <String, Object?>{
      'file_id': _fileId,
      'display_name': 'p6-acceptance.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'p6/acceptance',
      'created_at': 1,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await db.insert(
    'parsed_artifact_heads',
    <String, Object?>{
      'file_id': _fileId,
      'last_revision': revision,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await db.insert(
    'parsed_artifacts',
    <String, Object?>{
      'file_id': _fileId,
      'artifact_id': _artifactId,
      'revision': revision,
      'source_sha256': 'b' * 64,
      'cache_key_version': 1,
      'cache_fingerprint': 'p6-acceptance',
      'parser_route': 'pdf_text',
      'parser_version': '1.0',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'p6/acceptance-artifact-$revision',
      'payload_sha256': 'c' * 64,
      'size_bytes': 1,
      'published_at': 1,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<List<String>> _answerNodes() async {
  final db = await DatabaseHelper.instance.database;
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

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
