// P7-I0 AI generation use case acceptance.
//
// All ports are deterministic fakes; no live provider, real key, or database
// mutation. Sentinel strings are fictional.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/answers/answer_candidate_review_session.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('A. classification', () {
    test('missing current answer -> fill Candidate', () async {
      final harness = _Harness(draft: _contentDraft());
      final outcome = await harness.generate();
      final generated = outcome as AiAnswerGenerationGenerated;
      expect(generated.candidate.writeIntent, CandidateWriteIntent.fill);
      expect(
        generated.reviewSession.outcomeOf(generated.candidate.candidateId),
        CandidateReviewOutcome.pendingFill,
      );
    });

    test('structurally equal current answer -> noOp Candidate', () async {
      final harness = _Harness(
        draft: _contentDraft(answer: ContentAnswer(content: _text('x = 1'))),
      );
      final outcome = await harness.generate();
      final generated = outcome as AiAnswerGenerationGenerated;
      expect(generated.candidate.writeIntent, CandidateWriteIntent.noOp);
      expect(
        generated.reviewSession.outcomeOf(generated.candidate.candidateId),
        CandidateReviewOutcome.noOp,
      );
    });

    test('different current answer -> replace Candidate', () async {
      final harness = _Harness(
        draft: _contentDraft(answer: ContentAnswer(content: _text('x = 9'))),
      );
      final outcome = await harness.generate();
      final generated = outcome as AiAnswerGenerationGenerated;
      expect(generated.candidate.writeIntent, CandidateWriteIntent.replace);
      expect(
        generated.reviewSession.outcomeOf(generated.candidate.candidateId),
        CandidateReviewOutcome.pendingReplace,
      );
    });

    test(
        'historical multi-ID ChoiceAnswer with valid IDs -> replace, not '
        'invalidQuestionState', () async {
      final harness = _Harness(
        draft: _choiceDraft(
          answer: ChoiceAnswer(optionIds: ['opt_a', 'opt_b']),
        ),
        providerResult: _choiceResult('opt_a'),
      );
      final outcome = await harness.generate();
      final generated = outcome as AiAnswerGenerationGenerated;
      expect(generated.candidate.writeIntent, CandidateWriteIntent.replace);
    });
  });

  group('B. target/read', () {
    test('initial null -> questionMissing with zero provider calls', () async {
      final harness = _Harness(noQuestion: true);
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.questionMissing)),
      );
      expect(harness.provider.calls, 0);
    });

    test('legacy read -> questionNotTyped with zero provider calls', () async {
      final harness = _Harness(
        questionRead: LegacyStudyQuestionRead(
          questionId: 'q_1',
          bankName: 'bank_math',
          createdAt: 1,
          stemText: 'stem',
          optionsText: '[]',
          answerText: 'x',
          explanationText: null,
          legacyType: 0,
          review: _review(),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.questionNotTyped)),
      );
      expect(harness.provider.calls, 0);
    });

    test('impossible questionId mismatch -> internalError', () async {
      final harness = _Harness(
        questionRead: TypedStudyQuestionRead(
          questionId: 'different_id',
          bankName: 'bank_math',
          createdAt: 1,
          draft: _contentDraft(),
          review: _review(),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.internalError)),
      );
      expect(harness.provider.calls, 0);
    });
  });

  group('C. content admission', () {
    test('RawFallback in stem -> unsupportedQuestionContent, zero calls',
        () async {
      final harness = _Harness(
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.shortAnswer,
          questionNumber: 1,
          stem: RichContent(nodes: [_rawFallback()]),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
          _generationFailure(
              AiAnswerGenerationFailure.unsupportedQuestionContent),
        ),
      );
      expect(harness.provider.calls, 0);
    });

    test(
        'RawFallback in a choice option -> unsupportedQuestionContent, zero '
        'calls', () async {
      final harness = _Harness(
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.singleChoice,
          questionNumber: 1,
          stem: _text('stem'),
          options: [
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: RichContent(nodes: [_rawFallback()]),
            ),
          ],
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
          _generationFailure(
              AiAnswerGenerationFailure.unsupportedQuestionContent),
        ),
      );
      expect(harness.provider.calls, 0);
    });

    test('non-empty assetRefs -> unsupportedQuestionContent, zero calls',
        () async {
      final harness = _Harness(
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.shortAnswer,
          questionNumber: 1,
          stem: _text('stem'),
          sourceRefs: [SourceRef.document(sourceId: 'artifact_001')],
          assetRefs: [
            SourcedAssetRef(
              sourceId: 'artifact_001',
              asset: AssetRef(
                assetId: 'asset_001',
                kind: AssetKind.image,
                mimeType: 'image/png',
              ),
            ),
          ],
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
          _generationFailure(
              AiAnswerGenerationFailure.unsupportedQuestionContent),
        ),
      );
      expect(harness.provider.calls, 0);
    });

    test('empty/unusable stem -> invalidQuestionState, zero calls', () async {
      final harness = _Harness(
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.shortAnswer,
          questionNumber: 1,
          stem: RichContent(nodes: const []),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test('singleChoice without options -> invalidQuestionState', () async {
      final harness = _Harness(
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.singleChoice,
          questionNumber: 1,
          stem: _text('stem'),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test('empty choice option content -> invalidQuestionState', () async {
      final harness = _Harness(
        draft: _choiceDraft(
          options: [
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: RichContent(nodes: const []),
            ),
          ],
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test('content kind carrying options -> invalidQuestionState', () async {
      final harness = _Harness(
        draft: _contentDraft(
          options: [
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: _text('option A'),
            ),
          ],
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });
  });

  group('D. current answer state', () {
    test('singleChoice with ContentAnswer -> invalidQuestionState', () async {
      final harness = _Harness(
        draft: _choiceDraft(answer: ContentAnswer(content: _text('x'))),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test('content kind with ChoiceAnswer -> invalidQuestionState', () async {
      final harness = _Harness(
        draft: _contentDraft(
          answer: ChoiceAnswer(optionIds: ['opt_a']),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test(
        'current ChoiceAnswer referencing an unknown option -> '
        'invalidQuestionState', () async {
      final harness = _Harness(
        draft: _choiceDraft(
          answer: ChoiceAnswer(optionIds: ['opt_unknown']),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });

    test('duplicate current ChoiceAnswer ids -> invalidQuestionState',
        () async {
      final harness = _Harness(
        draft: _choiceDraft(
          answer: ChoiceAnswer(optionIds: ['opt_a', 'opt_a']),
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(
            _generationFailure(AiAnswerGenerationFailure.invalidQuestionState)),
      );
      expect(harness.provider.calls, 0);
    });
  });

  group('E. provider result validation', () {
    test('singleChoice result with one valid ID is accepted', () async {
      final harness = _Harness(
        draft: _choiceDraft(),
        providerResult: _choiceResult('opt_a'),
      );
      final outcome = await harness.generate();
      expect(outcome, isA<AiAnswerGenerationGenerated>());
    });

    test('wrong answer type for singleChoice -> validationFailed', () async {
      final harness = _Harness(
        draft: _choiceDraft(),
        providerResult: AiAnswerProviderResult(
          answer: ContentAnswer(content: _text('x = 1')),
          providerProfileId: 'engine_001',
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.validationFailed)),
      );
    });

    test('provider ChoiceAnswer with multiple IDs -> validationFailed',
        () async {
      final harness = _Harness(
        draft: _choiceDraft(),
        providerResult: AiAnswerProviderResult(
          answer: ChoiceAnswer(optionIds: ['opt_a', 'opt_b']),
          providerProfileId: 'engine_001',
        ),
      );
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.validationFailed)),
      );
    });

    test('provider unknown option ID -> validationFailed', () async {
      final harness = _Harness(
        draft: _choiceDraft(),
        providerResult: _choiceResult('opt_unknown'),
      );
      await expectLater(
        harness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.validationFailed)),
      );
    });

    test(
        'provider ContentAnswer with RawFallback or empty content -> '
        'validationFailed', () async {
      final rawHarness = _Harness(
        providerResult: AiAnswerProviderResult(
          answer: ContentAnswer(content: RichContent(nodes: [_rawFallback()])),
          providerProfileId: 'engine_001',
        ),
      );
      await expectLater(
        rawHarness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.validationFailed)),
      );
      final emptyHarness = _Harness(
        providerResult: AiAnswerProviderResult(
          answer: ContentAnswer(content: RichContent(nodes: const [])),
          providerProfileId: 'engine_001',
        ),
      );
      await expectLater(
        emptyHarness.generate(),
        throwsA(_generationFailure(AiAnswerGenerationFailure.validationFailed)),
      );
    });

    test('invalid providerProfileId -> validationFailed with no raw value',
        () async {
      final harness = _Harness(
        providerResult: AiAnswerProviderResult(
          answer: ContentAnswer(content: _text('x = 1')),
          providerProfileId: 'SENTINEL_BAD_PROFILE id',
        ),
      );
      try {
        await harness.generate();
        fail('expected validationFailed');
      } on AiAnswerGenerationException catch (error) {
        expect(error.failure, AiAnswerGenerationFailure.validationFailed);
        expect(error.toString(), isNot(contains('SENTINEL_BAD_PROFILE')));
      }
    });
  });

  group('F. stale target', () {
    test('stem changes during generation -> staleTarget, zero Candidate',
        () async {
      final harness = _Harness(
        draft: _contentDraft(),
        deferred: true,
      );
      final future = harness.generate();
      harness.question.read = TypedStudyQuestionRead(
        questionId: 'q_1',
        bankName: 'bank_math',
        createdAt: 1,
        draft: _contentDraft(stemText: 'changed stem'),
        review: _review(),
      );
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });

    test('answer changes during generation -> staleTarget', () async {
      final harness = _Harness(
        draft: _contentDraft(),
        deferred: true,
      );
      final future = harness.generate();
      harness.question.read = TypedStudyQuestionRead(
        questionId: 'q_1',
        bankName: 'bank_math',
        createdAt: 1,
        draft: _contentDraft(answer: ContentAnswer(content: _text('x = 9'))),
        review: _review(),
      );
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });

    test('deletion during generation -> staleTarget', () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final future = harness.generate();
      harness.question.read = null;
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });

    test('typed target becomes legacy -> staleTarget', () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final future = harness.generate();
      harness.question.read = LegacyStudyQuestionRead(
        questionId: 'q_1',
        bankName: 'bank_math',
        createdAt: 1,
        stemText: 'stem',
        optionsText: '[]',
        answerText: 'x',
        explanationText: null,
        legacyType: 0,
        review: _review(),
      );
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });

    test('bank changes during generation -> staleTarget', () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final future = harness.generate();
      harness.question.read = TypedStudyQuestionRead(
        questionId: 'q_1',
        bankName: 'other_bank',
        createdAt: 1,
        draft: _contentDraft(),
        review: _review(),
      );
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });

    test('explanation/source/assets/issues change -> staleTarget', () async {
      final base = _contentDraft();
      final harness = _Harness(draft: base, deferred: true);
      final future = harness.generate();
      harness.question.read = TypedStudyQuestionRead(
        questionId: 'q_1',
        bankName: 'bank_math',
        createdAt: 1,
        draft: QuestionDraftV2(
          questionId: 'q_1',
          kind: QuestionKind.shortAnswer,
          questionNumber: 1,
          stem: base.stem,
          answer: base.answer,
          explanation: _text('new explanation'),
          sourceRefs: base.sourceRefs,
          assetRefs: base.assetRefs,
          issues: base.issues,
        ),
        review: _review(),
      );
      harness.provider.complete();
      await expectLater(
        future,
        throwsA(_generationFailure(AiAnswerGenerationFailure.staleTarget)),
      );
    });
  });

  group('G. cancellation/supersession', () {
    test('cancel while pending then provider success -> Discarded(cancelled)',
        () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final future = harness.generate();
      harness.service.cancel('q_1');
      harness.provider.complete();
      final outcome = await future;
      expect(outcome, isA<AiAnswerGenerationDiscarded>());
      expect(
        (outcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.cancelled,
      );
    });

    test(
        'cancel while pending then provider failure -> Discarded(cancelled) '
        'and the failure is not exposed', () async {
      final harness = _Harness(
        draft: _contentDraft(),
        deferred: true,
        providerError: const AiAnswerProviderException(
          AiAnswerProviderFailure.providerTimeout,
        ),
      );
      final future = harness.generate();
      harness.service.cancel('q_1');
      harness.provider.complete();
      final outcome = await future;
      expect(
        (outcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.cancelled,
      );
    });

    test('cancel while pending then unexpected provider error -> discarded',
        () async {
      final harness = _Harness(
        draft: _contentDraft(),
        deferred: true,
        rawProviderError: StateError('SENTINEL_RAW_PROVIDER'),
      );
      final future = harness.generate();
      harness.service.cancel('q_1');
      harness.provider.complete();
      final outcome = await future;
      expect(
        (outcome as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.cancelled,
      );
    });

    test('second generation supersedes the first late result', () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final first = harness.generate();
      final second = harness.generate();
      harness.provider.complete();
      expect(
        (await first as AiAnswerGenerationDiscarded).reason,
        AiAnswerDiscardReason.superseded,
      );
      expect(await second, isA<AiAnswerGenerationGenerated>());
    });

    test('different storageIds do not supersede each other', () async {
      final harnessA = _Harness(
        draft: _contentDraft(questionId: 'q_a'),
        storageId: 'q_a',
      );
      final harnessB = _Harness(
        draft: _contentDraft(questionId: 'q_b'),
        storageId: 'q_b',
      );
      expect(await harnessA.generate(), isA<AiAnswerGenerationGenerated>());
      expect(await harnessB.generate(), isA<AiAnswerGenerationGenerated>());
    });

    test('cancelled/superseded results expose no Candidate', () async {
      final harness = _Harness(draft: _contentDraft(), deferred: true);
      final first = harness.generate();
      final second = harness.generate();
      harness.provider.complete();
      final firstOutcome = await first;
      final secondOutcome = await second;
      expect(firstOutcome, isA<AiAnswerGenerationDiscarded>());
      expect(secondOutcome, isA<AiAnswerGenerationGenerated>());
      expect(
          (secondOutcome as AiAnswerGenerationGenerated).candidate, isNotNull);
    });
  });

  group('H. provenance/privacy', () {
    test('Generated carries exactly one Candidate in one review session',
        () async {
      final harness = _Harness(draft: _contentDraft());
      final outcome = await harness.generate() as AiAnswerGenerationGenerated;
      expect(outcome.candidate.candidateId, isNotEmpty);
      expect(outcome.reviewSession.candidates, hasLength(1));
    });

    test('origin is AiAnswerOrigin with injected provenance', () async {
      final harness = _Harness(draft: _contentDraft());
      final outcome = await harness.generate() as AiAnswerGenerationGenerated;
      final origin = outcome.candidate.origin as AiAnswerOrigin;
      expect(origin.generationId, 'token_0');
      expect(origin.providerProfileId, 'engine_001');
      expect(origin.generatedAtUtc, DateTime.utc(2026, 8, 20, 12));
      expect(origin.generatedAtUtc.isUtc, isTrue);
      expect(outcome.candidate.candidateId, 'token_1');
      expect(outcome.candidate.reviewOnlyExplanation, isNull);
      expect(outcome.candidate.targetStorageId, 'q_1');
      expect(outcome.candidate.targetBankName, 'bank_math');
    });

    test('captured provider request contains only kind/stem/options', () async {
      const sentinelStorage = 'SENTINEL_STORAGE';
      const sentinelBank = 'SENTINEL_BANK';
      const sentinelQuestionId = 'SENTINEL_QUESTION_ID';
      const sentinelExplanation = 'SENTINEL_EXPLANATION';
      const sentinelSource = 'SENTINEL_SOURCE';
      const sentinelAsset = 'SENTINEL_ASSET';
      const sentinelIssue = 'SENTINEL_ISSUE';
      const sentinelCurrentAnswer = 'SENTINEL_CURRENT_ANSWER';
      const sentinelPath = 'SENTINEL_PATH';
      const sentinelBase64 = 'SENTINEL_BASE64';

      final draft = QuestionDraftV2(
        questionId: sentinelQuestionId,
        kind: QuestionKind.singleChoice,
        questionNumber: 1,
        stem: _text('solve for x'),
        sourceRefs: [SourceRef.document(sourceId: sentinelSource)],
        options: [
          QuestionOption(
            optionId: 'opt_a',
            label: 'A',
            content: _text('x = 1'),
            sourceRef: SourceRef.document(sourceId: sentinelAsset),
          ),
          QuestionOption(
            optionId: 'opt_b',
            label: 'B',
            content: _text('x = 2'),
          ),
        ],
        answer: ChoiceAnswer(optionIds: ['opt_a']),
        explanation: _text(sentinelExplanation),
        assetRefs: const [],
        issues: [
          ImportIssue(
            code: 'issue_code',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.stem,
          ),
        ],
      );
      final harness = _Harness(
        draft: draft,
        storageId: sentinelStorage,
        bankName: sentinelBank,
        providerResult: _choiceResult('opt_a'),
      );
      final outcome = await harness.generate();
      expect(outcome, isA<AiAnswerGenerationGenerated>());

      final request = harness.provider.requests.single;
      expect(request.kind, QuestionKind.singleChoice);
      final renderedStem = request.stem.nodes
          .map((node) => switch (node) {
                AiAnswerSafeText(:final text) => text,
                AiAnswerSafeInlineMath(:final latex) => latex,
                AiAnswerSafeBlockMath(:final latex) => latex,
              })
          .join();
      final renderedOptions = request.options
          .map((option) =>
              '${option.optionId}:${option.label}:${option.content.nodes.map((node) => switch (node) {
                    AiAnswerSafeText(:final text) => text,
                    AiAnswerSafeInlineMath(:final latex) => latex,
                    AiAnswerSafeBlockMath(:final latex) => latex,
                  }).join()}')
          .join();
      final payload = '$renderedStem|$renderedOptions';
      for (final sentinel in [
        sentinelStorage,
        sentinelBank,
        sentinelQuestionId,
        sentinelExplanation,
        sentinelSource,
        sentinelAsset,
        sentinelIssue,
        sentinelCurrentAnswer,
        sentinelPath,
        sentinelBase64,
      ]) {
        expect(payload, isNot(contains(sentinel)),
            reason: 'sentinel $sentinel must never reach the provider');
      }
      expect(renderedStem, contains('solve for x'));
      expect(renderedOptions, contains('opt_a'));
    });
  });

  group('I. failures', () {
    test('every AiAnswerProviderFailure maps 1:1', () async {
      final mappings = <AiAnswerProviderFailure, AiAnswerGenerationFailure>{
        AiAnswerProviderFailure.providerUnconfigured:
            AiAnswerGenerationFailure.providerUnconfigured,
        AiAnswerProviderFailure.providerAuthenticationFailed:
            AiAnswerGenerationFailure.providerAuthenticationFailed,
        AiAnswerProviderFailure.providerRateLimited:
            AiAnswerGenerationFailure.providerRateLimited,
        AiAnswerProviderFailure.providerTimeout:
            AiAnswerGenerationFailure.providerTimeout,
        AiAnswerProviderFailure.providerUnavailable:
            AiAnswerGenerationFailure.providerUnavailable,
        AiAnswerProviderFailure.providerRejected:
            AiAnswerGenerationFailure.providerRejected,
        AiAnswerProviderFailure.malformedProviderOutput:
            AiAnswerGenerationFailure.malformedProviderOutput,
        AiAnswerProviderFailure.validationFailed:
            AiAnswerGenerationFailure.validationFailed,
        AiAnswerProviderFailure.internalError:
            AiAnswerGenerationFailure.internalError,
      };
      for (final entry in mappings.entries) {
        final harness = _Harness(
          draft: _contentDraft(),
          providerError: AiAnswerProviderException(entry.key),
        );
        await expectLater(
          harness.generate(),
          throwsA(_generationFailure(entry.value)),
        );
      }
    });

    test('unexpected question-port exception -> internalError', () async {
      final harness = _Harness(
        draft: _contentDraft(),
        readError: StateError('SENTINEL_RAW_READ'),
      );
      try {
        await harness.generate();
        fail('expected internalError');
      } on AiAnswerGenerationException catch (error) {
        expect(error.failure, AiAnswerGenerationFailure.internalError);
        expect(error.toString(), isNot(contains('SENTINEL_RAW_READ')));
      }
    });

    test('unexpected provider exception -> internalError', () async {
      final harness = _Harness(
        draft: _contentDraft(),
        rawProviderError: StateError('SENTINEL_RAW_PROVIDER'),
      );
      try {
        await harness.generate();
        fail('expected internalError');
      } on AiAnswerGenerationException catch (error) {
        expect(error.failure, AiAnswerGenerationFailure.internalError);
        expect(error.toString(), isNot(contains('SENTINEL_RAW_PROVIDER')));
      }
    });

    test('every failure renders a fixed safe message', () {
      for (final failure in AiAnswerGenerationFailure.values) {
        final message = AiAnswerGenerationException(failure).toString();
        expect(message, contains('AiAnswerGenerationException'));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Bearer')));
      }
    });
  });
}

// --- fakes ---

class _FakeQuestionPort implements StudyQuestionQueryPort {
  _FakeQuestionPort(this.read);

  StudyQuestionRead? read;
  Object? readError;

  @override
  Future<StudyQuestionRead?> getStudyQuestionDetail(
    String questionId, {
    required int nowUnixSeconds,
  }) async {
    final error = readError;
    if (error != null) throw error;
    return read;
  }

  @override
  Future<StudyPage<QuestionBankSummary>> listStudyQuestionBanks({
    required int nowUnixSeconds,
    required int limit,
    String? afterBankName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPage<StudyQuestionRead>> searchStudyQuestions({
    required String bankName,
    required String query,
    required int nowUnixSeconds,
    required int limit,
    int? afterCreatedAt,
    String? afterId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<StudyPage<StudyQuestionRead>> listStudyWeakQuestions({
    required int nowUnixSeconds,
    required int limit,
    String? bankName,
    int? afterLastLapseTime,
    String? afterId,
  }) {
    throw UnimplementedError();
  }
}

class _FakeProviderPort implements AiAnswerProviderPort {
  _FakeProviderPort({
    required this.result,
    this.providerError,
    this.rawProviderError,
    bool deferred = false,
  }) : _gate = deferred ? Completer<void>() : null;

  final AiAnswerProviderResult result;
  final AiAnswerProviderException? providerError;
  final Object? rawProviderError;
  final Completer<void>? _gate;
  final List<AiAnswerProviderRequest> requests = <AiAnswerProviderRequest>[];
  int calls = 0;

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
    final gate = _gate;
    if (gate != null) {
      await gate.future;
    }
    final typed = providerError;
    if (typed != null) throw typed;
    final raw = rawProviderError;
    if (raw != null) throw raw;
    return result;
  }
}

class _Harness {
  _Harness({
    QuestionDraftV2? draft,
    this.storageId = 'q_1',
    String bankName = 'bank_math',
    bool noQuestion = false,
    AiAnswerProviderResult? providerResult,
    AiAnswerProviderException? providerError,
    Object? rawProviderError,
    bool deferred = false,
    StudyQuestionRead? questionRead,
    Object? readError,
  })  : provider = _FakeProviderPort(
          result: providerResult ??
              AiAnswerProviderResult(
                answer: ContentAnswer(content: _text('x = 1')),
                providerProfileId: 'engine_001',
              ),
          providerError: providerError,
          rawProviderError: rawProviderError,
          deferred: deferred,
        ),
        question = _FakeQuestionPort(
          questionRead ??
              (noQuestion
                  ? null
                  : TypedStudyQuestionRead(
                      questionId: storageId,
                      bankName: bankName,
                      createdAt: 1,
                      draft: draft ?? _contentDraft(),
                      review: _review(),
                    )),
        ) {
    if (readError != null) {
      question.readError = readError;
    }
    var counter = 0;
    service = AiAnswerGenerationService(
      questionPort: question,
      providerPort: provider,
      idFactory: () => 'token_${counter++}',
      clock: () => DateTime.utc(2026, 8, 20, 12),
    );
  }

  final String storageId;
  final _FakeQuestionPort question;
  final _FakeProviderPort provider;
  late final AiAnswerGenerationService service;

  Future<AiAnswerGenerationOutcome> generate() {
    return service.generateForQuestion(storageId: storageId);
  }
}

// --- fixtures ---

QuestionDraftV2 _contentDraft({
  String questionId = 'q_1',
  String stemText = 'solve for x',
  QuestionAnswer? answer,
  Iterable<QuestionOption> options = const [],
}) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _text(stemText),
    answer: answer,
    options: options,
  );
}

QuestionDraftV2 _choiceDraft({
  QuestionAnswer? answer,
  Iterable<QuestionOption>? options,
}) {
  return QuestionDraftV2(
    questionId: 'q_1',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('choose'),
    options: options ?? _defaultChoiceOptions,
    answer: answer,
  );
}

final List<QuestionOption> _defaultChoiceOptions = [
  QuestionOption(
    optionId: 'opt_a',
    label: 'A',
    content: RichContent(nodes: [TextNode('x = 1')]),
  ),
  QuestionOption(
    optionId: 'opt_b',
    label: 'B',
    content: RichContent(nodes: [TextNode('x = 2')]),
  ),
];

AiAnswerProviderResult _choiceResult(String optionId) {
  return AiAnswerProviderResult(
    answer: ChoiceAnswer(optionIds: [optionId]),
    providerProfileId: 'engine_001',
  );
}

RawFallbackNode _rawFallback() {
  return RawFallbackNode(<String, Object?>{
    'type': 'raw_fallback',
    'payload': <String, Object?>{'secret': 'nope'},
  });
}

StudyQuestionReviewState _review() {
  return const StudyQuestionReviewState(
    due: false,
    lapseCount: 0,
    difficulty: 5,
    lastLapseTime: null,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

Matcher _generationFailure(AiAnswerGenerationFailure failure) {
  return isA<AiAnswerGenerationException>().having(
    (error) => error.failure,
    'failure',
    failure,
  );
}
