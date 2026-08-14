// P7-V0 focused validation / privacy / concurrency / acceptance.
//
// End-to-end contract acceptance across the real production chain on a real
// SQLite test database (synthetic sqflite FFI in-memory handle through the
// frozen DatabaseHelper singleton):
//
//   real QuestionRepository (StudyQuestionQueryPort)
//   -> AiAnswerGenerationService (I0) with a deterministic fake
//      AiAnswerProviderPort (never live, never a real key)
//   -> transient AnswerCandidate + AnswerCandidateReviewSession
//   -> explicit confirmation
//   -> AiAnswerCommitCommand -> AiAnswerCommitRepository
//   -> TypedAnswerPersistenceKernel -> real SQLite
//
// No live network, no real provider key, no real user database, no
// production filesystem, no external fixture, no MCP. All sentinel strings
// are fictional.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/answers/answer_candidate_review_session.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/ai_answer_commit_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _mapper = QuestionV2PersistenceMapper();
const _bankName = 'p7_v0_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _providerProfileId = 'engine_001';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  group('A. fill end to end', () {
    test(
        'missing answer -> one Candidate -> confirmation -> one formal '
        'mutation with V1/V2 consistency and schema v21', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);

      final snapshot = await _DurabilitySnapshot.capture();
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final candidate = generated.candidate;

      // Exactly one Candidate; AI origin; answer-only; fill intent.
      expect(generated.reviewSession.candidates, hasLength(1));
      expect(candidate.origin, isA<AiAnswerOrigin>());
      expect(candidate.reviewOnlyExplanation, isNull);
      expect(candidate.writeIntent, CandidateWriteIntent.fill);
      expect(
        generated.reviewSession.outcomeOf(candidate.candidateId),
        CandidateReviewOutcome.pendingFill,
      );

      // Confirmation is required: an unconfirmed session never reaches the
      // durable boundary.
      final unconfirmedSession = generated.reviewSession;
      await expectLater(
        _commit(
          session: unconfirmedSession,
          confirmation: _handConfirmation(unconfirmedSession),
        ),
        _commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(await snapshot.unchanged(), isTrue,
          reason: 'zero writes before explicit confirmation');

      // Exact confirmation advances the session revision exactly once.
      expect(generated.confirmation.sessionRevision, 1);
      final committed = await _commit(
        session: generated.confirmedSession,
        confirmation: generated.confirmation,
      );
      expect(
        committed.outcomeOf(candidate.candidateId),
        CandidateReviewOutcome.committed,
      );

      // V2 payload answer updated; V1 standard_answer projection updated;
      // review_states byte/field-equivalent unchanged; schema stays v21.
      final db = await _db();
      final expected = _mapper.freezeAnswerUpdate(
        storageId: _storageId,
        replacementDraft: _withAnswer(seedDraft, _content('x = 1')),
      );
      expect(await _payloadJsonOf(db), expected.payloadRow['payload_json']);
      expect(await _standardAnswerOf(db), expected.standardAnswer);
      expect(await _reviewRowOf(db), snapshot.reviewRow,
          reason: 'review state must stay untouched');
      expect(await _userVersionOf(db), 21);

      // Reload returns the new typed answer.
      final reloaded = await QuestionRepository()
          .getStudyQuestionDetail(_storageId, nowUnixSeconds: 1700000001);
      expect(reloaded, isA<TypedStudyQuestionRead>());
      expect(
        (reloaded as TypedStudyQuestionRead).draft.answer,
        ContentAnswer(content: _text('x = 1')),
      );
    });
  });

  group('B. noOp', () {
    test(
        'structurally equal durable answer -> terminal noOp with zero '
        'transaction and zero durable candidate/provenance data', () async {
      final seedDraft = _contentDraft(
        answer: ContentAnswer(content: _text('x = 1')),
      );
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();

      final service = _generationService(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final outcome = await service.generateForQuestion(storageId: _storageId);
      final generated = outcome as AiAnswerGenerationGenerated;
      expect(generated.candidate.writeIntent, CandidateWriteIntent.noOp);
      expect(
        generated.reviewSession.outcomeOf(generated.candidate.candidateId),
        CandidateReviewOutcome.noOp,
      );

      // No confirmation exists: noOp is terminal and never committable.
      final session = generated.reviewSession;
      await expectLater(
        _commit(
          session: session,
          confirmation: _handConfirmation(session),
        ),
        _commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );
      expect(
        () => session.confirmFill(generated.candidate.candidateId),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.noOpTerminal,
          ),
        ),
      );

      // Zero transaction/write: every row is byte-identical, and no
      // candidate/provenance/session text exists anywhere.
      expect(await snapshot.unchanged(), isTrue,
          reason: 'noOp must produce zero durable change');
      final db = await _db();
      final dump = await _dumpDatabase(db);
      expect(dump, isNot(contains(generated.candidate.candidateId)));
      expect(dump, isNot(contains('sessionRevision')));
    });
  });

  group('C. replace end to end', () {
    test(
        'direct replace bypass closed, two-step confirmation, one formal '
        'mutation, V1/V2 consistent, review_states unchanged', () async {
      final seedDraft = _contentDraft(
        answer: ContentAnswer(content: _text('x = 9')),
      );
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();

      final generated = await _generate(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final candidate = generated.candidate;
      expect(candidate.writeIntent, CandidateWriteIntent.replace);
      expect(
        generated.reviewSession.outcomeOf(candidate.candidateId),
        CandidateReviewOutcome.pendingReplace,
      );

      // Direct replace confirmation without selection is closed.
      expect(
        () => generated.reviewSession.confirmReplace(candidate.candidateId),
        throwsA(
          isA<AnswerCandidateReviewException>().having(
            (error) => error.failure,
            'failure',
            AnswerCandidateReviewFailure.replaceFlowRequired,
          ),
        ),
      );
      expect(await snapshot.unchanged(), isTrue,
          reason: 'the first review decision must persist nothing');

      // An unselected replace session can never commit.
      await expectLater(
        _commit(
          session: generated.reviewSession,
          confirmation: _handConfirmation(generated.reviewSession),
        ),
        _commitFailure(AiAnswerCommitFailure.candidateNotCommittable),
      );

      // Second explicit confirmation: select -> reconfirm -> commit.
      final selected = generated.reviewSession.selectForReplace(
        candidate.candidateId,
      );
      final decided = selected.confirmReplace(candidate.candidateId);
      expect(decided.confirmation.sessionRevision, 2);
      final committed = await _commit(
        session: decided.session,
        confirmation: decided.confirmation,
      );
      expect(
        committed.outcomeOf(candidate.candidateId),
        CandidateReviewOutcome.committed,
      );

      final db = await _db();
      final expected = _mapper.freezeAnswerUpdate(
        storageId: _storageId,
        replacementDraft: _withAnswer(seedDraft, _content('x = 1')),
      );
      expect(await _payloadJsonOf(db), expected.payloadRow['payload_json']);
      expect(await _standardAnswerOf(db), expected.standardAnswer);
      expect(await _reviewRowOf(db), snapshot.reviewRow);
      final reloaded = await _reloadDraft(db);
      expect(reloaded.answer, ContentAnswer(content: _text('x = 1')));
    });
  });

  group('D. real concurrent competing commits', () {
    test(
        'two incompatible AI candidates race on one real SQLite DB: exactly '
        'one compatible candidate wins, the loser fails stale, and the winner '
        'is never overwritten', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();

      // Two independent I0 generations over the SAME real repository/SQLite
      // target produce two incompatible fill candidates from the identical
      // original expectedDraft.
      final a = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
        idPrefix: 'gen_a',
      );
      final b = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 2')),
        idPrefix: 'gen_b',
      );
      expect(a.candidate.expectedDraft, b.candidate.expectedDraft);
      expect(a.candidate.answer, isNot(b.candidate.answer));

      // Genuinely concurrent launch: both commits are started before either
      // is awaited, racing on the same real SQLite database.
      final attempts = await Future.wait<_CommitAttempt>([
        _tryCommit(
          command: AiAnswerCommitCommand(
            persistencePort: AiAnswerCommitRepository(),
          ),
          session: a.confirmedSession,
          confirmation: a.confirmation,
        ),
        _tryCommit(
          command: AiAnswerCommitCommand(
            persistencePort: AiAnswerCommitRepository(),
          ),
          session: b.confirmedSession,
          confirmation: b.confirmation,
        ),
      ]);

      // Exactly one compatible candidate wins; the loser MUST fail closed on
      // the frozen stale contract (never a double success, never a lost
      // update, never a partial mutation).
      final successes = attempts.whereType<_CommitSucceeded>().toList();
      final failures = attempts.whereType<_CommitFailed>().toList();
      expect(successes, hasLength(1),
          reason: 'exactly one compatible candidate may commit');
      expect(failures, hasLength(1),
          reason: 'the losing candidate must fail, not silently succeed');
      expect(
        failures.single.failure,
        AiAnswerCommitFailure.staleTarget,
        reason: 'the loser must fail on the frozen stale semantics, not a '
            'lock race or persistence failure',
      );

      final winner = successes.single.answer;
      final db = await _db();
      final reloaded = await _reloadDraft(db);
      expect(reloaded.answer, winner,
          reason: 'the loser must never overwrite the winner');
      final payload = jsonDecode(
        await _payloadJsonOf(db),
      ) as Map<String, dynamic>;
      final payloadAnswer = payload['answer'] as Map<String, dynamic>;
      final nodes = ((payloadAnswer['content'] as Map<String, dynamic>)['nodes']
          as List<dynamic>);
      expect(nodes.single['text'], _answerText(winner),
          reason: 'V2 payload must hold exactly the winner answer');
      expect(await _reviewRowOf(db), snapshot.reviewRow,
          reason: 'review_states must stay untouched by the race');
      final expected = _mapper.freezeAnswerUpdate(
        storageId: _storageId,
        replacementDraft: _withAnswerValue(seedDraft, winner),
      );
      expect(await _standardAnswerOf(db), expected.standardAnswer,
          reason: 'V1 projection must stay consistent with the V2 winner');
    });
  });

  group('E. durable stale matrix (cross-layer)', () {
    test(
        'answer drift after generation -> staleTarget, zero incompatible '
        'write', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );

      // Another writer fills the answer while the candidate is pending.
      await QuestionRepository().updateTypedAnswer(
        storageId: _storageId,
        expectedDraft: seedDraft,
        newAnswer: ContentAnswer(content: _text('x = 9')),
      );

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final db = await _db();
      final reloaded = await _reloadDraft(db);
      expect(reloaded.answer, ContentAnswer(content: _text('x = 9')),
          reason: 'the external change is preserved; the AI answer is not');
      final standard = await _standardAnswerOf(db);
      expect(standard, contains('x = 9'));
      expect(standard, isNot(contains('x = 1')));
    });

    test('non-answer draft drift (stem) -> staleTarget with zero mutation',
        () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      await _updatePayload(_contentDraft(stemText: 'changed stem'));

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final db = await _db();
      final reloaded = await _reloadDraft(db);
      expect((reloaded.stem.nodes.single as TextNode).text, 'changed stem');
      expect(reloaded.answer, isNull);
    });

    test('options drift -> staleTarget with zero mutation', () async {
      final seedDraft = _choiceDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_choiceResult('opt_a')),
      );
      await _updatePayload(
        _choiceDraft(options: <QuestionOption>[
          _option('opt_a', 'A', 'x = 1'),
          _option('opt_b', 'B', 'x = 2'),
        ]),
      );

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final reloaded = await _reloadDraft(await _db());
      expect(reloaded.options, hasLength(2));
      expect(reloaded.answer, isNull);
    });

    test('explanation drift -> staleTarget with zero mutation', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      await _updatePayload(
        _withExplanation(seedDraft, _text('changed explanation')),
      );

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final reloaded = await _reloadDraft(await _db());
      expect(reloaded.answer, isNull);
    });

    test('source/assets/issues drift -> staleTarget with zero mutation',
        () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      await _updatePayload(
        QuestionDraftV2(
          questionId: seedDraft.questionId,
          kind: seedDraft.kind,
          questionNumber: seedDraft.questionNumber,
          stem: seedDraft.stem,
          options: seedDraft.options,
          answer: seedDraft.answer,
          explanation: seedDraft.explanation,
          sourceRefs: <SourceRef>[
            SourceRef.document(sourceId: 'drifted_artifact_001'),
          ],
          assetRefs: <SourcedAssetRef>[
            SourcedAssetRef(
              sourceId: 'drifted_artifact_001',
              asset: AssetRef(
                assetId: 'drifted_asset_001',
                kind: AssetKind.image,
                mimeType: 'image/png',
              ),
            ),
          ],
          issues: <ImportIssue>[
            ImportIssue(
              code: 'drifted_issue',
              severity: ImportIssueSeverity.warning,
              field: ImportIssueField.stem,
            ),
          ],
        ),
      );

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final reloaded = await _reloadDraft(await _db());
      expect(reloaded.sourceRefs, hasLength(1));
      expect(reloaded.assetRefs, hasLength(1));
      expect(reloaded.issues, hasLength(1));
      expect(reloaded.answer, isNull);
    });

    test('bank change after generation -> staleTarget with zero mutation',
        () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final db = await _db();
      await db.update(
        'questions',
        <String, Object?>{'bank_name': 'drifted_bank'},
        where: 'id = ?',
        whereArgs: <Object?>[_storageId],
      );

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      final reloaded = await _reloadDraft(db);
      expect(reloaded.answer, isNull);
    });

    test(
        'question deleted after generation -> staleTarget with zero '
        'incompatible write', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final db = await _db();
      await db.delete('questions',
          where: 'id = ?', whereArgs: <Object?>[_storageId]);

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await db.query('questions'), isEmpty);
      expect(await db.query('question_v2_payloads'), isEmpty);
    });

    test(
        'typed target becomes legacy after generation -> staleTarget with '
        'zero incompatible write', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final db = await _db();
      await db.delete('question_v2_payloads');

      await expectLater(
        _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        ),
        _commitFailure(AiAnswerCommitFailure.staleTarget),
      );
      expect(await db.query('questions'), hasLength(1));
      expect(await db.query('question_v2_payloads'), isEmpty);
    });
  });

  group('F. provider admission / egress privacy', () {
    test(
        'non-empty assetRefs -> unsupportedQuestionContent with zero '
        'provider calls and zero mutation', () async {
      final seedDraft = QuestionDraftV2(
        questionId: _storageId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _text('solve for x'),
        sourceRefs: <SourceRef>[
          SourceRef.document(sourceId: 'artifact_001'),
        ],
        assetRefs: <SourcedAssetRef>[
          SourcedAssetRef(
            sourceId: 'artifact_001',
            asset: AssetRef(
              assetId: 'asset_001',
              kind: AssetKind.image,
              mimeType: 'image/png',
            ),
          ),
        ],
      );
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(_contentResult('x = 1'));

      await expectLater(
        _generationService(
          questionPort: QuestionRepository(),
          providerPort: provider,
        ).generateForQuestion(storageId: _storageId),
        _generationFailure(
          AiAnswerGenerationFailure.unsupportedQuestionContent,
        ),
      );
      expect(provider.calls, 0,
          reason: 'admission happens before any network request');
      expect(await snapshot.unchanged(), isTrue,
          reason: 'zero Candidate, zero commit, zero mutation');
    });

    test(
        'RawFallback question content -> unsupportedQuestionContent with '
        'zero provider calls and zero mutation', () async {
      final seedDraft = QuestionDraftV2(
        questionId: _storageId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: RichContent(nodes: <ContentNode>[
          RawFallbackNode(<String, Object?>{
            'type': 'raw_fallback',
            'payload': <String, Object?>{'shape': 'synthetic'},
          }),
        ]),
      );
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(_contentResult('x = 1'));

      await expectLater(
        _generationService(
          questionPort: QuestionRepository(),
          providerPort: provider,
        ).generateForQuestion(storageId: _storageId),
        _generationFailure(
          AiAnswerGenerationFailure.unsupportedQuestionContent,
        ),
      );
      expect(provider.calls, 0);
      expect(await snapshot.unchanged(), isTrue);
    });

    test(
        'provider request carries only kind/stem/options: no storageId, '
        'bankName, questionId, current answer, explanation, source/asset '
        'refs, issues, paths, base64, or generation metadata', () async {
      const sentinelBank = 'SENTINEL_BANK';
      const sentinelExplanation = 'SENTINEL_EXPLANATION';
      const sentinelSource = 'SENTINEL_SOURCE';
      const sentinelIssue = 'sentinel_issue_code';
      const sentinelCurrentAnswer = 'SENTINEL_CURRENT_ANSWER';
      const sentinelPath = 'SENTINEL_PATH';
      const sentinelBase64 = 'SENTINEL_BASE64';
      const sentinelGeneration = 'SENTINEL_GENERATION';

      // Every sentinel lives inside the durable draft; only the safe
      // text/math stem may ever reach the provider request.
      final seedDraft = QuestionDraftV2(
        questionId: _storageId,
        kind: QuestionKind.shortAnswer,
        questionNumber: 1,
        stem: _text('solve for x'),
        sourceRefs: <SourceRef>[
          SourceRef.document(sourceId: sentinelSource),
        ],
        answer: ContentAnswer(content: _text(sentinelCurrentAnswer)),
        explanation: _text('$sentinelExplanation $sentinelPath '
            '$sentinelBase64 $sentinelGeneration'),
        assetRefs: const <SourcedAssetRef>[],
        issues: <ImportIssue>[
          ImportIssue(
            code: sentinelIssue,
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.stem,
          ),
        ],
      );
      await _seedTarget(draft: seedDraft, bankName: sentinelBank);
      final provider = _provider(_contentResult('x = 1'));
      final service = _generationService(
        questionPort: QuestionRepository(),
        providerPort: provider,
      );

      final outcome = await service.generateForQuestion(storageId: _storageId);
      expect(outcome, isA<AiAnswerGenerationGenerated>());

      final request = provider.requests.single;
      // Structural boundary: the request exposes only kind/stem/options.
      expect(request.kind, QuestionKind.shortAnswer);
      expect(request.options, isEmpty);
      final payload = _renderSafeContent(request.stem);

      final origin = (outcome as AiAnswerGenerationGenerated).candidate.origin
          as AiAnswerOrigin;
      for (final forbidden in <String>[
        sentinelBank,
        sentinelExplanation,
        sentinelSource,
        sentinelIssue,
        sentinelCurrentAnswer,
        sentinelPath,
        sentinelBase64,
        sentinelGeneration,
        _storageId,
        origin.generationId,
        origin.providerProfileId,
        _providerProfileId,
      ]) {
        expect(payload, isNot(contains(forbidden)),
            reason: 'sentinel $forbidden must never reach the provider');
      }
      expect(payload, contains('solve for x'));
      expect(payload, isNot(contains('explanation')));
    });
  });

  group('G. durable privacy', () {
    test(
        'candidate/generation/provider sentinels never enter SQLite; only '
        'candidate.answer becomes the formal durable answer', () async {
      const sentinelCandidate = 'SENTINEL_CANDIDATE_PRIVATE';
      const sentinelGeneration = 'SENTINEL_GENERATION_PRIVATE';
      const sentinelProvider = 'SENTINEL_PROVIDER_PRIVATE';

      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);

      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(
          _contentResult('x = 1', providerProfileId: sentinelProvider),
        ),
        idPrefix: 'sentinel',
        candidateIdOverride: sentinelCandidate,
        generationIdOverride: sentinelGeneration,
      );
      expect((generated.candidate.origin as AiAnswerOrigin).generationId,
          sentinelGeneration);
      expect(
        (generated.candidate.origin as AiAnswerOrigin).providerProfileId,
        sentinelProvider,
      );
      expect(generated.candidate.candidateId, sentinelCandidate);

      await _commit(
        session: generated.confirmedSession,
        confirmation: generated.confirmation,
      );

      final db = await _db();
      final dump = await _dumpDatabase(db);
      for (final forbidden in <String>[
        sentinelCandidate,
        sentinelGeneration,
        sentinelProvider,
        'generatedAtUtc',
        'sessionRevision',
        'reviewOnlyExplanation',
        'providerRequest',
        'providerResult',
        'reasoning',
        'chainOfThought',
        'http',
        'api_key',
        'Bearer',
        'requestBody',
      ]) {
        expect(dump, isNot(contains(forbidden)),
            reason: 'sentinel/transient field $forbidden must never be '
                'persisted');
      }

      // Only candidate.answer becomes the formal durable answer.
      final payload = jsonDecode(
        await _payloadJsonOf(db),
      ) as Map<String, dynamic>;
      final answer = payload['answer'] as Map<String, dynamic>;
      final nodes =
          ((answer['content'] as Map<String, dynamic>)['nodes'] as List);
      expect(nodes, <Object?>[
        <String, Object?>{'type': 'text', 'text': 'x = 1'}
      ]);
      expect(await _standardAnswerOf(db), contains('x = 1'));
      expect(await _userVersionOf(db), 21);
    });
  });

  group('H. failure privacy', () {
    test(
        'raw provider failure surfaces only internalError, never the raw '
        'cause', () async {
      await _seedTarget(draft: _contentDraft());
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(
        _contentResult('x = 1'),
        rawError: StateError('SENTINEL_RAW_PROVIDER'),
      );
      try {
        await _generationService(
          questionPort: QuestionRepository(),
          providerPort: provider,
        ).generateForQuestion(storageId: _storageId);
        fail('expected a typed generation failure');
      } on AiAnswerGenerationException catch (error) {
        expect(error.failure, AiAnswerGenerationFailure.internalError);
        expect(error.toString(), isNot(contains('SENTINEL_RAW_PROVIDER')));
        expect(error.toString(), isNot(contains('http')));
      }
      expect(await snapshot.unchanged(), isTrue);
    });

    test(
        'malformed provider output maps to the typed category with a fixed '
        'safe message', () async {
      await _seedTarget(draft: _contentDraft());
      final provider = _provider(
        _contentResult('x = 1'),
        providerError: const AiAnswerProviderException(
          AiAnswerProviderFailure.malformedProviderOutput,
        ),
      );
      try {
        await _generationService(
          questionPort: QuestionRepository(),
          providerPort: provider,
        ).generateForQuestion(storageId: _storageId);
        fail('expected malformedProviderOutput');
      } on AiAnswerGenerationException catch (error) {
        expect(
          error.failure,
          AiAnswerGenerationFailure.malformedProviderOutput,
        );
        expect(error.toString(), isNot(contains('http')));
        expect(error.toString(), isNot(contains('api_key')));
        expect(error.toString(), isNot(contains('SENTINEL')));
      }
    });

    test('stale commit never exposes the drifted raw value', () async {
      await _seedTarget(draft: _contentDraft());
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final db = await _db();
      await db.update(
        'questions',
        <String, Object?>{'bank_name': 'SENTINEL_BANK_DRIFT'},
        where: 'id = ?',
        whereArgs: <Object?>[_storageId],
      );
      try {
        await _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        );
        fail('expected staleTarget');
      } on AiAnswerCommitException catch (error) {
        expect(error.failure, AiAnswerCommitFailure.staleTarget);
        expect(error.toString(), isNot(contains('SENTINEL')));
      }
    });

    test(
        'physical persistence failure maps to persistenceFailed and never '
        'exposes the raw SQL sentinel', () async {
      await _seedTarget(draft: _contentDraft());
      final generated = await _generateFill(
        questionPort: QuestionRepository(),
        providerPort: _provider(_contentResult('x = 1')),
      );
      final db = await _db();
      await db.execute(
        'CREATE TRIGGER p7_v0_fail_questions BEFORE UPDATE ON questions '
        "BEGIN SELECT RAISE(FAIL, 'SENTINEL_SQL_PERSISTENCE'); END",
      );
      final payloadBefore = await _payloadJsonOf(db);
      final standardBefore = await _standardAnswerOf(db);

      try {
        await _commit(
          session: generated.confirmedSession,
          confirmation: generated.confirmation,
        );
        fail('expected persistenceFailed');
      } on AiAnswerCommitException catch (error) {
        expect(error.failure, AiAnswerCommitFailure.persistenceFailed);
        expect(
          error.toString(),
          isNot(contains('SENTINEL_SQL_PERSISTENCE')),
          reason: 'raw SQL must never surface in a public typed exception',
        );
      }
      // The payload UPDATE happened before the failing questions UPDATE; the
      // whole transaction must have rolled back.
      expect(await _payloadJsonOf(db), payloadBefore);
      expect(await _standardAnswerOf(db), standardBefore);
    });

    test('every public failure renders a fixed safe message', () {
      for (final failure in AiAnswerGenerationFailure.values) {
        final message = AiAnswerGenerationException(failure).toString();
        expect(message, contains('AiAnswerGenerationException'));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Bearer')));
        expect(message, isNot(contains('SENTINEL')));
      }
      for (final failure in AiAnswerCommitFailure.values) {
        final message = AiAnswerCommitException(failure).toString();
        expect(message, contains('AiAnswerCommitException'));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Bearer')));
        expect(message, isNot(contains('SENTINEL')));
      }
    });
  });

  group('I. cancel / supersede safety', () {
    test(
        'cancel while the provider call is in flight, then late provider '
        'success -> discarded, no Candidate, no review session, zero durable '
        'mutation', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(
        _contentResult('x = 1'),
        deferred: true,
      );
      final service = _generationService(
        questionPort: QuestionRepository(),
        providerPort: provider,
      );

      // 1. Start generation; 2. prove the provider call has actually been
      // entered and is in flight; 3. the provider was really invoked once.
      final entered = provider.waitUntilCalls(1);
      final pending = service.generateForQuestion(storageId: _storageId);
      await entered;
      expect(provider.calls, 1,
          reason: 'the provider call must be in flight before cancellation');

      // 4. Cancel after entry; 5. release the deferred result afterwards.
      service.cancel(_storageId);
      provider.complete();

      // 6. The late success must be discarded, never exposed or written.
      final outcome = await pending;
      expect(outcome, isA<AiAnswerGenerationDiscarded>());
      expect(
        (outcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.cancelled,
      );
      expect(outcome, isNot(isA<AiAnswerGenerationGenerated>()));
      expect(provider.calls, 1, reason: 'the provider was called exactly once');
      expect(await snapshot.unchanged(), isTrue,
          reason: 'a late result after cancel must never mutate anything');
    });

    test(
        'cancel while the provider call is in flight, then late provider '
        'failure -> discarded, never a typed failure, zero durable mutation',
        () async {
      await _seedTarget(draft: _contentDraft());
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(
        _contentResult('x = 1'),
        deferred: true,
        rawError: StateError('SENTINEL_RAW_PROVIDER'),
      );
      final service = _generationService(
        questionPort: QuestionRepository(),
        providerPort: provider,
      );

      // Prove the failing provider call is in flight before cancellation.
      final entered = provider.waitUntilCalls(1);
      final pending = service.generateForQuestion(storageId: _storageId);
      await entered;
      expect(provider.calls, 1);

      service.cancel(_storageId);
      provider.complete(); // Releases the raw provider failure after cancel.

      final outcome = await pending;
      expect(outcome, isA<AiAnswerGenerationDiscarded>());
      expect(
        (outcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.cancelled,
      );
      expect(provider.calls, 1,
          reason: 'the provider failure really arrived and was discarded');
      expect(await snapshot.unchanged(), isTrue);
    });

    test(
        'first provider call still in flight when the second generation '
        'supersedes it -> first discarded, second generated, zero durable '
        'mutation', () async {
      final seedDraft = _contentDraft();
      await _seedTarget(draft: seedDraft);
      final snapshot = await _DurabilitySnapshot.capture();
      final provider = _provider(
        _contentResult('x = 1'),
        deferred: true,
      );
      final service = _generationService(
        questionPort: QuestionRepository(),
        providerPort: provider,
      );

      // 1. First generation; 2. wait until the FIRST provider call is
      // genuinely pending; 3. start the second generation, which supersedes
      // the first; 4. wait until the second provider invocation is also in
      // flight, proving both old and new calls race on the same target.
      final firstEntered = provider.waitUntilCalls(1);
      final first = service.generateForQuestion(storageId: _storageId);
      await firstEntered;
      expect(provider.calls, 1,
          reason: 'the superseded provider call must already be in flight');

      final secondEntered = provider.waitUntilCalls(2);
      final second = service.generateForQuestion(storageId: _storageId);
      await secondEntered;
      expect(provider.calls, 2,
          reason: 'both generations really reached the provider');

      // 5. Release both deferred results; 6. await both generations.
      provider.complete();
      final firstOutcome = await first;
      final secondOutcome = await second;
      expect(firstOutcome, isA<AiAnswerGenerationDiscarded>());
      expect(
        (firstOutcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.superseded,
      );
      expect(secondOutcome, isA<AiAnswerGenerationGenerated>());
      expect(provider.calls, 2,
          reason: 'the intended two-call race actually occurred');
      expect(await snapshot.unchanged(), isTrue,
          reason: 'generation alone never writes; the superseded result is '
              'never exposed or committed');
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Deterministic fake provider port: records every request, counts calls,
/// and can be deferred with an explicit completion gate. Never live.
///
/// [waitUntilCalls] is a completer-based synchronization proof that a
/// provider invocation has actually entered [generateAnswer] (i.e., the
/// provider call is genuinely in flight), never a Duration sleep.
class _FakeProviderPort implements AiAnswerProviderPort {
  _FakeProviderPort({
    required this.result,
    this.providerError,
    this.rawError,
    bool deferred = false,
  }) : _gate = deferred ? Completer<void>() : null;

  final AiAnswerProviderResult result;
  final AiAnswerProviderException? providerError;
  final Object? rawError;
  final Completer<void>? _gate;

  final List<AiAnswerProviderRequest> requests = <AiAnswerProviderRequest>[];
  final Map<int, Completer<void>> _callWaiters = <int, Completer<void>>{};
  int calls = 0;

  /// Completes when at least [count] provider invocations have actually
  /// entered [generateAnswer]. Returns an already-completed future when the
  /// count is already reached; otherwise the waiter completes the moment the
  /// count is reached inside the next invocation.
  Future<void> waitUntilCalls(int count) {
    if (calls >= count) return Future<void>.value();
    final completer = Completer<void>();
    _callWaiters[count] = completer;
    return completer.future;
  }

  void complete() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<AiAnswerProviderResult> generateAnswer(
    AiAnswerProviderRequest request,
  ) async {
    calls++;
    requests.add(request);
    final waiter = _callWaiters.remove(calls);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    final gate = _gate;
    if (gate != null) {
      await gate.future;
    }
    final typed = providerError;
    if (typed != null) throw typed;
    final raw = rawError;
    if (raw != null) throw raw;
    return result;
  }
}

// ---------------------------------------------------------------------------
// Seed / durability helpers
// ---------------------------------------------------------------------------

Future<Database> _db() => DatabaseHelper.instance.database;

/// Seeds one typed question through the frozen mapper + real SQLite.
Future<void> _seedTarget({
  required QuestionDraftV2 draft,
  String bankName = _bankName,
}) async {
  final db = await _db();
  final frozen = _mapper.freezeForWrite(
    storageId: _storageId,
    bankName: bankName,
    createdAt: 1700000001,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': _storageId,
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

/// Rewrites the sidecar payload with a drifted draft, simulating another
/// writer between generation and commit.
Future<void> _updatePayload(QuestionDraftV2 replacement) async {
  final db = await _db();
  final frozen = _mapper.freezeForWrite(
    storageId: _storageId,
    bankName: _bankName,
    createdAt: 1700000001,
    draft: replacement,
  );
  await db.update(
    'question_v2_payloads',
    frozen.payloadRow,
    where: 'question_id = ?',
    whereArgs: <Object?>[_storageId],
  );
}

Future<String> _payloadJsonOf(Database db) async {
  final rows = await db.query(
    'question_v2_payloads',
    columns: <String>['payload_json'],
    where: 'question_id = ?',
    whereArgs: <Object?>[_storageId],
  );
  expect(rows, hasLength(1));
  return rows.single['payload_json']! as String;
}

Future<String> _standardAnswerOf(Database db) async {
  final rows = await db.query(
    'questions',
    columns: <String>['standard_answer'],
    where: 'id = ?',
    whereArgs: <Object?>[_storageId],
  );
  expect(rows, hasLength(1));
  return rows.single['standard_answer']! as String;
}

Future<Map<String, Object?>> _reviewRowOf(Database db) async {
  final rows = await db.query(
    'review_states',
    where: 'question_id = ?',
    whereArgs: <Object?>[_storageId],
  );
  expect(rows, hasLength(1));
  return rows.single;
}

Future<int> _userVersionOf(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return rows.single['user_version'] as int;
}

Future<QuestionDraftV2> _reloadDraft(Database db) async {
  final rows = await db.rawQuery(
    '''
    SELECT q.*,
           p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
           p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
    FROM questions q
    LEFT JOIN question_v2_payloads p ON q.id = p.question_id
    WHERE q.id = ?
    ''',
    <Object?>[_storageId],
  );
  expect(rows, hasLength(1));
  final decoded = _mapper.decodeJoinedRow(rows.single);
  expect(decoded, isA<TypedPersistedQuestion>());
  return (decoded as TypedPersistedQuestion).draft;
}

/// Dumps every row of every user table as one string for privacy scans.
Future<String> _dumpDatabase(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%'",
  );
  final buffer = StringBuffer();
  for (final row in tables) {
    final name = row['name']! as String;
    final rows = await db.query(name);
    for (final entry in rows) {
      buffer.write(entry.values.join('|'));
      buffer.write('\n');
    }
  }
  return buffer.toString();
}

/// Snapshot of every durability-relevant row, for byte-equivalent change
/// detection.
final class _DurabilitySnapshot {
  _DurabilitySnapshot({
    required this.payloadJson,
    required this.standardAnswer,
    required this.reviewRow,
    required this.questionCount,
    required this.payloadCount,
    required this.reviewCount,
  });

  final String payloadJson;
  final String standardAnswer;
  final Map<String, Object?> reviewRow;
  final int questionCount;
  final int payloadCount;
  final int reviewCount;

  static Future<_DurabilitySnapshot> capture() async {
    final db = await _db();
    return _DurabilitySnapshot(
      payloadJson: await _payloadJsonOf(db),
      standardAnswer: await _standardAnswerOf(db),
      reviewRow: await _reviewRowOf(db),
      questionCount: (await db.query('questions')).length,
      payloadCount: (await db.query('question_v2_payloads')).length,
      reviewCount: (await db.query('review_states')).length,
    );
  }

  Future<bool> unchanged() async {
    final db = await _db();
    return await _payloadJsonOf(db) == payloadJson &&
        await _standardAnswerOf(db) == standardAnswer &&
        (await _reviewRowOf(db)).toString() == reviewRow.toString() &&
        (await db.query('questions')).length == questionCount &&
        (await db.query('question_v2_payloads')).length == payloadCount &&
        (await db.query('review_states')).length == reviewCount;
  }
}

// ---------------------------------------------------------------------------
// Chain helpers
// ---------------------------------------------------------------------------

Future<
    ({
      AnswerCandidate candidate,
      AnswerCandidateReviewSession confirmedSession,
      AnswerCandidateConfirmation confirmation,
      AnswerCandidateReviewSession reviewSession,
    })> _generateFill({
  required QuestionRepository questionPort,
  required AiAnswerProviderPort providerPort,
  String idPrefix = 'v0',
  String? candidateIdOverride,
  String? generationIdOverride,
}) async {
  final generated = await _generate(
    questionPort: questionPort,
    providerPort: providerPort,
    idPrefix: idPrefix,
    candidateIdOverride: candidateIdOverride,
    generationIdOverride: generationIdOverride,
  );
  final decided = generated.reviewSession.confirmFill(
    generated.candidate.candidateId,
  );
  return (
    candidate: generated.candidate,
    reviewSession: generated.reviewSession,
    confirmedSession: decided.session,
    confirmation: decided.confirmation,
  );
}

/// Generates one candidate through the real chain without confirming it.
Future<
    ({
      AnswerCandidate candidate,
      AnswerCandidateReviewSession reviewSession,
    })> _generate({
  required QuestionRepository questionPort,
  required AiAnswerProviderPort providerPort,
  String idPrefix = 'v0',
  String? candidateIdOverride,
  String? generationIdOverride,
}) async {
  var counter = 0;
  final service = _generationService(
    questionPort: questionPort,
    providerPort: providerPort,
    idFactory: () {
      if (generationIdOverride != null && counter == 0) {
        counter++;
        return generationIdOverride;
      }
      if (candidateIdOverride != null && counter == 1) {
        counter++;
        return candidateIdOverride;
      }
      return '${idPrefix}_token_${counter++}';
    },
  );
  final outcome = await service.generateForQuestion(storageId: _storageId);
  final generated = outcome as AiAnswerGenerationGenerated;
  return (
    candidate: generated.candidate,
    reviewSession: generated.reviewSession,
  );
}

AiAnswerGenerationService _generationService({
  required QuestionRepository questionPort,
  required AiAnswerProviderPort providerPort,
  String Function()? idFactory,
  DateTime Function()? clock,
}) {
  var counter = 0;
  return AiAnswerGenerationService(
    questionPort: questionPort,
    providerPort: providerPort,
    idFactory: idFactory ?? () => 'v0_token_${counter++}',
    clock: clock ?? () => DateTime.utc(2026, 8, 20, 12),
  );
}

Future<AnswerCandidateReviewSession> _commit({
  required AnswerCandidateReviewSession session,
  required AnswerCandidateConfirmation confirmation,
}) {
  return AiAnswerCommitCommand(
    persistencePort: AiAnswerCommitRepository(),
  ).commit(session: session, confirmation: confirmation);
}

AnswerCandidateConfirmation _handConfirmation(
  AnswerCandidateReviewSession session, {
  int? sessionRevision,
}) {
  return AnswerCandidateConfirmation(
    candidate: session.candidates.single,
    sessionRevision: sessionRevision ?? session.sessionRevision,
  );
}

// ---------------------------------------------------------------------------
// Commit attempt result for the real concurrency race
// ---------------------------------------------------------------------------

sealed class _CommitAttempt {
  const _CommitAttempt();
}

final class _CommitSucceeded extends _CommitAttempt {
  const _CommitSucceeded(this.answer);

  final QuestionAnswer answer;
}

final class _CommitFailed extends _CommitAttempt {
  const _CommitFailed(this.failure);

  final AiAnswerCommitFailure failure;
}

Future<_CommitAttempt> _tryCommit({
  required AiAnswerCommitCommand command,
  required AnswerCandidateReviewSession session,
  required AnswerCandidateConfirmation confirmation,
}) async {
  try {
    await command.commit(session: session, confirmation: confirmation);
    return _CommitSucceeded(confirmation.candidate.answer);
  } on AiAnswerCommitException catch (error) {
    return _CommitFailed(error.failure);
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

RichContent _text(String text) =>
    RichContent(nodes: <ContentNode>[TextNode(text)]);

RichContent _content(String text) => _text(text);

QuestionAnswer _contentResultAnswer(String text) =>
    ContentAnswer(content: _text(text));

AiAnswerProviderResult _contentResult(
  String text, {
  String providerProfileId = _providerProfileId,
}) {
  return AiAnswerProviderResult(
    answer: _contentResultAnswer(text),
    providerProfileId: providerProfileId,
  );
}

AiAnswerProviderResult _choiceResult(
  String optionId, {
  String providerProfileId = _providerProfileId,
}) {
  return AiAnswerProviderResult(
    answer: ChoiceAnswer(optionIds: <String>[optionId]),
    providerProfileId: providerProfileId,
  );
}

_FakeProviderPort _provider(
  AiAnswerProviderResult result, {
  AiAnswerProviderException? providerError,
  Object? rawError,
  bool deferred = false,
}) {
  return _FakeProviderPort(
    result: result,
    providerError: providerError,
    rawError: rawError,
    deferred: deferred,
  );
}

QuestionDraftV2 _contentDraft({
  String stemText = 'solve for x',
  QuestionAnswer? answer,
}) {
  return QuestionDraftV2(
    questionId: _storageId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text(stemText),
    answer: answer,
  );
}

QuestionDraftV2 _choiceDraft({
  QuestionAnswer? answer,
  Iterable<QuestionOption>? options,
}) {
  return QuestionDraftV2(
    questionId: _storageId,
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('choose'),
    options: options ?? _defaultChoiceOptions,
    answer: answer,
  );
}

final Iterable<QuestionOption> _defaultChoiceOptions = <QuestionOption>[
  QuestionOption(
    optionId: 'opt_a',
    label: 'A',
    content: RichContent(nodes: <ContentNode>[TextNode('x = 1')]),
  ),
  QuestionOption(
    optionId: 'opt_b',
    label: 'B',
    content: RichContent(nodes: <ContentNode>[TextNode('x = 2')]),
  ),
  QuestionOption(
    optionId: 'opt_c',
    label: 'C',
    content: RichContent(nodes: <ContentNode>[TextNode('x = 3')]),
  ),
];

QuestionOption _option(
  String optionId,
  String label,
  String content, {
  SourceRef? sourceRef,
}) {
  return QuestionOption(
    optionId: optionId,
    label: label,
    content: _text(content),
    sourceRef: sourceRef,
  );
}

QuestionDraftV2 _withAnswer(QuestionDraftV2 draft, RichContent answer) {
  return _withAnswerValue(draft, ContentAnswer(content: answer));
}

QuestionDraftV2 _withAnswerValue(QuestionDraftV2 draft, QuestionAnswer answer) {
  return QuestionDraftV2(
    questionId: draft.questionId,
    kind: draft.kind,
    questionNumber: draft.questionNumber,
    stem: draft.stem,
    options: draft.options,
    answer: answer,
    explanation: draft.explanation,
    sourceRefs: draft.sourceRefs,
    assetRefs: draft.assetRefs,
    issues: draft.issues,
  );
}

QuestionDraftV2 _withExplanation(
    QuestionDraftV2 draft, RichContent explanation) {
  return QuestionDraftV2(
    questionId: draft.questionId,
    kind: draft.kind,
    questionNumber: draft.questionNumber,
    stem: draft.stem,
    options: draft.options,
    answer: draft.answer,
    explanation: explanation,
    sourceRefs: draft.sourceRefs,
    assetRefs: draft.assetRefs,
    issues: draft.issues,
  );
}

String _renderSafeContent(AiAnswerSafeContent content) {
  return content.nodes
      .map((node) => switch (node) {
            AiAnswerSafeText(:final text) => text,
            AiAnswerSafeInlineMath(:final latex) => latex,
            AiAnswerSafeBlockMath(:final latex) => latex,
          })
      .join();
}

String _answerText(QuestionAnswer answer) {
  return switch (answer) {
    ChoiceAnswer(:final optionIds) => optionIds.join(','),
    ContentAnswer(:final content) => content.nodes
        .map((node) => switch (node) {
              TextNode(:final text) => text,
              InlineMathNode(:final latex) => latex,
              BlockMathNode(:final latex) => latex,
              RawFallbackNode() => '',
            })
        .join(),
  };
}

Matcher _generationFailure(AiAnswerGenerationFailure failure) {
  return throwsA(
    isA<AiAnswerGenerationException>().having(
      (error) => error.failure,
      'failure',
      failure,
    ),
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
