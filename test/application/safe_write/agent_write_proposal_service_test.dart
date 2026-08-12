// W0-P1 pure-application acceptance: transient proposals, canonical
// fingerprint deduplication, one-active-per-source-turn, the fill-only
// policy and the in-memory lifecycle gate. The persistence port is faked so
// no database, provider, network or private document is touched.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

const _bankName = 'w0_p1_synthetic_bank';
const _storageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';
const _conversationId = 'conv_p1_001';
const _messageId = 'msg_p1_user_001';

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _choiceDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_p1_choice_q',
    kind: QuestionKind.singleChoice,
    questionNumber: 1,
    stem: _text('Choice stem.'),
    options: <QuestionOption>[
      QuestionOption(optionId: 'opt_a', label: 'A', content: _text('first')),
      QuestionOption(optionId: 'opt_b', label: 'B', content: _text('second')),
      QuestionOption(optionId: 'opt_c', label: 'C', content: _text('third')),
    ],
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

QuestionDraftV2 _contentDraft({QuestionAnswer? answer}) {
  return QuestionDraftV2(
    questionId: 'w0_p1_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: _text('Content stem.'),
    answer: answer,
    explanation: _text('Explanation.'),
  );
}

AgentWriteAdmissionRequest _request(String messageId) {
  return AgentWriteAdmissionRequest(
    sourceConversationId: _conversationId,
    sourceMessageId: messageId,
    scope: ConversationScope.global(),
    targetStorageId: _storageId,
  );
}

AgentWriteAdmittedTarget _grantedTarget(QuestionDraftV2 draft) {
  return AgentWriteAdmittedTarget(
    storageId: _storageId,
    bankName: _bankName,
    draft: draft,
  );
}

class _FakePersistence
    implements AgentWritePersistencePort, AgentWriteReconciliationPort {
  _FakePersistence({required this.admissionResult});

  AgentWriteAdmissionResult admissionResult;
  Object? commitError;
  AgentWriteReconciliationResult reconciliationResult =
      const AgentWriteReconciliationUnavailable();
  Object? reconciliationError;
  final commitCalls = <AgentWriteCommitRequest>[];
  final reconciliationCalls = <AgentWriteReconciliationRequest>[];
  Completer<void>? commitGate;

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    return admissionResult;
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commitCalls.add(request);
    final gate = commitGate;
    if (gate != null) await gate.future;
    final failure = commitError;
    if (failure != null) throw failure;
  }

  @override
  Future<AgentWriteReconciliationResult> reconcileAfterAmbiguousCommit(
    AgentWriteReconciliationRequest request,
  ) async {
    reconciliationCalls.add(request);
    final error = reconciliationError;
    if (error != null) throw error;
    return reconciliationResult;
  }
}

/// Persistence-only fake (no reconciliation adapter): ambiguous COMMIT
/// failures stay unconfirmable exactly like pre-repair composition.
class _PersistenceOnlyFake implements AgentWritePersistencePort {
  _PersistenceOnlyFake({required this.admissionResult});

  final AgentWriteAdmissionResult admissionResult;
  Object? commitError;
  final commitCalls = <AgentWriteCommitRequest>[];

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    return admissionResult;
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commitCalls.add(request);
    final failure = commitError;
    if (failure != null) throw failure;
  }
}

void main() {
  group('fingerprint and one-active rule', () {
    test('same semantic fingerprint reuses the same proposal id', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      final first = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      );
      final second = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      );

      expect(first, isA<AgentWriteStageResultStaged>());
      expect(second, isA<AgentWriteStageResultStaged>());
      final firstProposal = (first as AgentWriteStageResultStaged).proposal;
      final secondProposal = (second as AgentWriteStageResultStaged).proposal;
      expect(secondProposal.id, firstProposal.id);
      expect(secondProposal.outcome, AgentWriteProposalOutcome.pending);
    });

    test(
      'different payload creates a new id and supersedes the old pending',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        );
        final service = AgentWriteProposalService(persistence);

        final first = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer one')),
        )) as AgentWriteStageResultStaged;
        final second = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer two')),
        )) as AgentWriteStageResultStaged;

        expect(second.proposal.id, isNot(first.proposal.id));
        expect(
          service.proposalById(first.proposal.id).outcome,
          AgentWriteProposalOutcome.superseded,
        );
        expect(second.proposal.outcome, AgentWriteProposalOutcome.pending);
      },
    );

    test('each source turn has at most one active/pending proposal', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      final first = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;
      final second = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;

      expect(second.proposal.id, first.proposal.id);
      final active = {
        service.proposalById(first.proposal.id),
        service.proposalById(second.proposal.id),
      }.where((p) => p.outcome == AgentWriteProposalOutcome.pending);
      expect(active, hasLength(1));
    });

    test('different source turns may each hold a pending proposal', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      final turnOne = (await service.stageProposal(
        admissionRequest: _request('msg_p1_user_001'),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;
      final turnTwo = (await service.stageProposal(
        admissionRequest: _request('msg_p1_user_002'),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;

      expect(turnTwo.proposal.id, isNot(turnOne.proposal.id));
      expect(turnOne.proposal.outcome, AgentWriteProposalOutcome.pending);
      expect(turnTwo.proposal.outcome, AgentWriteProposalOutcome.pending);
    });

    test(
      'createdAt and preview never participate in the fingerprint',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        );
        final service = AgentWriteProposalService(persistence);

        final first = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final second = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        expect(identical(second.proposal, first.proposal), isTrue);
        expect(second.proposal.id, first.proposal.id);
      },
    );
  });

  group('preview and admission safety', () {
    test('preview is built only from the admitted target snapshot', () async {
      final draft = _choiceDraft();
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(_grantedTarget(draft)),
      );
      final service = AgentWriteProposalService(persistence);

      final staged = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      )) as AgentWriteStageResultStaged;
      final preview = staged.proposal.preview;

      expect(preview.bankName, _bankName);
      expect(preview.stem, draft.stem);
      expect(preview.options, draft.options);
      expect(
        preview.proposedAnswer,
        ChoiceAnswer(optionIds: <String>['opt_b']),
      );
    });

    test(
      'admission denial and unavailability pass through without a proposal',
      () async {
        final deniedService = AgentWriteProposalService(
          _FakePersistence(admissionResult: const AgentWriteAdmissionDenied()),
        );
        final denied = await deniedService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        );
        expect(denied, isA<AgentWriteStageResultDenied>());

        final unavailableService = AgentWriteProposalService(
          _FakePersistence(
            admissionResult: const AgentWriteAdmissionUnavailable(),
          ),
        );
        final unavailable = await unavailableService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        );
        expect(unavailable, isA<AgentWriteStageResultUnavailable>());
      },
    );
  });

  group('fill-only policy', () {
    test('an already-answered admitted target is ineligible', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(
            _contentDraft(answer: ContentAnswer(content: _text('old'))),
          ),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      final result = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('new')),
      );

      expect(result, isA<AgentWriteStageResultIneligible>());
    });

    test(
        'whitespace-only, raw fallback and unknown choice payloads are '
        'ineligible', () async {
      final contentService = AgentWriteProposalService(
        _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        ),
      );
      expect(
        await contentService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('   ')),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
      expect(
        await contentService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[
                RawFallbackNode(<Object?, Object?>{
                  'type': 'future_diagram',
                  'payload': <Object?, Object?>{'shape': 'synthetic'},
                }),
              ],
            ),
          ),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );

      final choiceService = AgentWriteProposalService(
        _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_choiceDraft()),
          ),
        ),
      );
      expect(
        await choiceService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ChoiceAnswer(optionIds: <String>['ghost_opt']),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
    });

    test(
        'manual typed repair capabilities are untouched by the fill-only '
        'policy', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      // The proposal layer only refuses staging; the shared manual command is
      // a separate seam (covered by its own acceptance) and is never called
      // by this service.
      final result = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      );

      expect(result, isA<AgentWriteStageResultStaged>());
      expect(persistence.commitCalls, isEmpty);
    });
  });

  group('proposed-answer kind and structural validity policy', () {
    test('singleChoice accepts only a valid ChoiceAnswer', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_choiceDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);

      final staged = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_b']),
      );
      expect(staged, isA<AgentWriteStageResultStaged>());

      final mismatch = await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      );
      expect(mismatch, isA<AgentWriteStageResultIneligible>());
    });

    test(
      'fillBlank and shortAnswer accept only a non-empty ContentAnswer',
      () async {
        final fillBlankDraft = QuestionDraftV2(
          questionId: 'w0_p1_fill_q',
          kind: QuestionKind.fillBlank,
          questionNumber: 3,
          stem: _text('Fill stem.'),
        );
        for (final draft in <QuestionDraftV2>[
          fillBlankDraft,
          _contentDraft(),
        ]) {
          final service = AgentWriteProposalService(
            _FakePersistence(
              admissionResult: AgentWriteAdmissionGranted(
                _grantedTarget(draft),
              ),
            ),
          );

          final staged = await service.stageProposal(
            admissionRequest: _request(_messageId),
            proposedAnswer: ContentAnswer(content: _text('answer')),
          );
          expect(staged, isA<AgentWriteStageResultStaged>());

          final mismatch = await service.stageProposal(
            admissionRequest: _request(_messageId),
            proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_a']),
          );
          expect(mismatch, isA<AgentWriteStageResultIneligible>());
        }
      },
    );

    test('whitespace-only math does not make content non-empty', () async {
      final service = AgentWriteProposalService(
        _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        ),
      );

      expect(
        await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[InlineMathNode('   ')]),
          ),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
      expect(
        await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(
            content: RichContent(nodes: <ContentNode>[BlockMathNode(' \t ')]),
          ),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
    });

    test(
      'mixed visible content is accepted despite whitespace nodes',
      () async {
        final service = AgentWriteProposalService(
          _FakePersistence(
            admissionResult: AgentWriteAdmissionGranted(
              _grantedTarget(_contentDraft()),
            ),
          ),
        );

        final staged = await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(
            content: RichContent(
              nodes: <ContentNode>[
                TextNode('   '),
                InlineMathNode('x^2+1'),
                TextNode('  '),
              ],
            ),
          ),
        );

        expect(staged, isA<AgentWriteStageResultStaged>());
      },
    );

    test('duplicate and unknown choice identities are ineligible', () async {
      final service = AgentWriteProposalService(
        _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_choiceDraft()),
          ),
        ),
      );

      expect(
        await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ChoiceAnswer(optionIds: <String>['opt_a', 'opt_a']),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
      expect(
        await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ChoiceAnswer(
            optionIds: <String>['opt_a', 'ghost_opt'],
          ),
        ),
        isA<AgentWriteStageResultIneligible>(),
      );
    });
  });

  group('lifecycle gate', () {
    test('approve commits exactly once and reports committed', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);
      final staged = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;

      final approved = await service.approveProposal(staged.proposal.id);
      final reapproved = await service.approveProposal(staged.proposal.id);

      expect(approved.outcome, AgentWriteProposalOutcome.committed);
      expect(reapproved.outcome, AgentWriteProposalOutcome.committed);
      expect(persistence.commitCalls, hasLength(1));
      final request = persistence.commitCalls.single;
      expect(request.sourceConversationId, _conversationId);
      expect(request.sourceMessageId, _messageId);
      expect(request.targetStorageId, _storageId);
      expect(request.expectedBankName, _bankName);
      expect(request.proposedAnswer, ContentAnswer(content: _text('answer')));
    });

    test('concurrent approvals share one in-flight commit', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);
      final staged = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;

      final results = await Future.wait(<Future<AgentWriteProposal>>[
        service.approveProposal(staged.proposal.id),
        service.approveProposal(staged.proposal.id),
      ]);

      expect(
        results.every((p) => p.outcome == AgentWriteProposalOutcome.committed),
        isTrue,
      );
      expect(persistence.commitCalls, hasLength(1));
    });

    test('commit failure maps to the frozen outcome categories', () async {
      final stalePersistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      )..commitError = const TypedAnswerMutationException(
          TypedAnswerMutationFailure.stale,
        );
      final staleService = AgentWriteProposalService(stalePersistence);
      final staleStaged = (await staleService.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;
      final stale = await staleService.approveProposal(staleStaged.proposal.id);
      expect(stale.outcome, AgentWriteProposalOutcome.stale);

      final ambiguousPersistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      )..commitError = const TypedAnswerMutationException(
          TypedAnswerMutationFailure.transactionFailed,
        );
      final ambiguousService = AgentWriteProposalService(ambiguousPersistence);
      final ambiguousStaged = (await ambiguousService.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;
      final ambiguous = await ambiguousService.approveProposal(
        ambiguousStaged.proposal.id,
      );
      expect(ambiguous.outcome, AgentWriteProposalOutcome.unknownOutcome);

      final invalidPersistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      )..commitError = const TypedAnswerMutationException(
          TypedAnswerMutationFailure.invalidAnswer,
        );
      final invalidService = AgentWriteProposalService(invalidPersistence);
      final invalidStaged = (await invalidService.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer')),
      )) as AgentWriteStageResultStaged;
      final invalid = await invalidService.approveProposal(
        invalidStaged.proposal.id,
      );
      expect(invalid.outcome, AgentWriteProposalOutcome.invalid);
    });

    test(
      'reject wins only while pending; committed and committing stay put',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        );
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        final rejected = service.rejectProposal(staged.proposal.id);
        expect(rejected.outcome, AgentWriteProposalOutcome.rejected);
        expect(rejected.id, staged.proposal.id);

        final replayed = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        expect(replayed.proposal.outcome, AgentWriteProposalOutcome.rejected);

        final approvedAfterReject = await service.approveProposal(
          staged.proposal.id,
        );
        expect(approvedAfterReject.outcome, AgentWriteProposalOutcome.rejected);
        expect(persistence.commitCalls, isEmpty);
      },
    );

    test(
      'committed proposals are never reactivated by replay or approval',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        );
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        await service.approveProposal(staged.proposal.id);

        final replayed = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        expect(replayed.proposal.id, staged.proposal.id);
        expect(replayed.proposal.outcome, AgentWriteProposalOutcome.committed);
        expect(persistence.commitCalls, hasLength(1));
      },
    );

    test('a superseded proposal cannot be approved or rejected', () async {
      final persistence = _FakePersistence(
        admissionResult: AgentWriteAdmissionGranted(
          _grantedTarget(_contentDraft()),
        ),
      );
      final service = AgentWriteProposalService(persistence);
      final first = (await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer one')),
      )) as AgentWriteStageResultStaged;
      await service.stageProposal(
        admissionRequest: _request(_messageId),
        proposedAnswer: ContentAnswer(content: _text('answer two')),
      );

      final approved = await service.approveProposal(first.proposal.id);
      final rejected = service.rejectProposal(first.proposal.id);

      expect(approved.outcome, AgentWriteProposalOutcome.superseded);
      expect(rejected.outcome, AgentWriteProposalOutcome.superseded);
      expect(persistence.commitCalls, isEmpty);
    });

    test('unknown proposal id is rejected by the service', () async {
      final service = AgentWriteProposalService(
        _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        ),
      );

      expect(
        () => service.rejectProposal('proposal_missing'),
        throwsArgumentError,
      );
      await expectLater(
        service.approveProposal('proposal_missing'),
        throwsArgumentError,
      );
    });
  });

  group('ambiguous COMMIT reconciliation', () {
    test(
      'transactionFailed with the exact post-image reports committed and '
      'reconciles exactly once with zero retry',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationResult = const AgentWriteReconciliationCommitted();
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        final approved = await service.approveProposal(staged.proposal.id);

        expect(approved.outcome, AgentWriteProposalOutcome.committed);
        expect(persistence.commitCalls, hasLength(1));
        expect(persistence.reconciliationCalls, hasLength(1));
        final request = persistence.reconciliationCalls.single;
        expect(request.sourceConversationId, _conversationId);
        expect(request.sourceMessageId, _messageId);
        expect(request.targetStorageId, _storageId);
        expect(request.expectedBankName, _bankName);
        expect(request.expectedDraft, staged.proposal.expectedDraft);
        expect(request.proposedAnswer, staged.proposal.proposedAnswer);
      },
    );

    test(
      'transactionFailed with the exact baseline returns pending with zero '
      'automatic retry; one explicit Approve performs exactly one new commit',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationResult = const AgentWriteReconciliationBaseline();
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        final ambiguous = await service.approveProposal(staged.proposal.id);

        expect(ambiguous.outcome, AgentWriteProposalOutcome.pending);
        expect(persistence.commitCalls, hasLength(1));
        expect(persistence.reconciliationCalls, hasLength(1));
        await Future<void>.delayed(Duration.zero);
        expect(
          persistence.commitCalls,
          hasLength(1),
          reason: 'Reconciliation must never trigger an automatic retry.',
        );

        persistence.commitError = null;
        final retried = await service.approveProposal(staged.proposal.id);

        expect(retried.outcome, AgentWriteProposalOutcome.committed);
        expect(persistence.commitCalls, hasLength(2));
        expect(
          persistence.reconciliationCalls,
          hasLength(1),
          reason: 'A successful explicit retry does not reconcile again.',
        );
      },
    );

    test(
      'transactionFailed with any other confirmed draft reports stale',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationResult = const AgentWriteReconciliationConflicted();
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        final approved = await service.approveProposal(staged.proposal.id);

        expect(approved.outcome, AgentWriteProposalOutcome.stale);
        expect(persistence.commitCalls, hasLength(1));
        expect(persistence.reconciliationCalls, hasLength(1));
      },
    );

    test(
      'unavailable and failed reconciliation reads stay unknownOutcome with '
      'zero retry',
      () async {
        final unavailablePersistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationResult = const AgentWriteReconciliationUnavailable();
        final unavailableService =
            AgentWriteProposalService(unavailablePersistence);
        final unavailableStaged = (await unavailableService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        final unavailable = await unavailableService.approveProposal(
          unavailableStaged.proposal.id,
        );
        expect(
          unavailable.outcome,
          AgentWriteProposalOutcome.unknownOutcome,
        );
        expect(unavailablePersistence.commitCalls, hasLength(1));

        final throwingPersistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationError = StateError('synthetic read failure');
        final throwingService = AgentWriteProposalService(throwingPersistence);
        final throwingStaged = (await throwingService.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        final throwing = await throwingService.approveProposal(
          throwingStaged.proposal.id,
        );
        expect(throwing.outcome, AgentWriteProposalOutcome.unknownOutcome);
        expect(throwingPersistence.commitCalls, hasLength(1));
      },
    );

    test(
      'a persistence without a reconciliation adapter keeps unknownOutcome',
      () async {
        final persistence = _PersistenceOnlyFake(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          );
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;

        final approved = await service.approveProposal(staged.proposal.id);

        expect(approved.outcome, AgentWriteProposalOutcome.unknownOutcome);
        expect(persistence.commitCalls, hasLength(1));
      },
    );

    test(
      'concurrent re-approval after an ambiguous baseline shares one new '
      'commit attempt',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        )
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.transactionFailed,
          )
          ..reconciliationResult = const AgentWriteReconciliationBaseline();
        final service = AgentWriteProposalService(persistence);
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer')),
        )) as AgentWriteStageResultStaged;
        final ambiguous = await service.approveProposal(staged.proposal.id);
        expect(ambiguous.outcome, AgentWriteProposalOutcome.pending);
        expect(persistence.commitCalls, hasLength(1));

        persistence.commitError = null;
        final results = await Future.wait(<Future<AgentWriteProposal>>[
          service.approveProposal(staged.proposal.id),
          service.approveProposal(staged.proposal.id),
        ]);

        expect(
          results.every(
            (p) => p.outcome == AgentWriteProposalOutcome.committed,
          ),
          isTrue,
        );
        expect(
          persistence.commitCalls,
          hasLength(2),
          reason: 'One explicit retry performs exactly one new commit shared '
              'by the concurrent approvals.',
        );
        expect(persistence.reconciliationCalls, hasLength(1));
      },
    );
  });

  group('pre-activation result-size gate', () {
    test(
      'a rejected gate leaves no active/pending proposal and no supersession',
      () async {
        final persistence = _FakePersistence(
          admissionResult: AgentWriteAdmissionGranted(
            _grantedTarget(_contentDraft()),
          ),
        );
        final service = AgentWriteProposalService(persistence);
        final first = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer one')),
        )) as AgentWriteStageResultStaged;

        // The second admission yields a materially different snapshot; the
        // gate must see that exact candidate before any mutation.
        final hugeDraft = QuestionDraftV2(
          questionId: 'w0_p1_huge_q',
          kind: QuestionKind.shortAnswer,
          questionNumber: 2,
          stem: _text('x' * 70000),
        );
        persistence.admissionResult =
            AgentWriteAdmissionGranted(_grantedTarget(hugeDraft));
        AgentWriteProposal? gatedCandidate;
        await expectLater(
          service.stageProposal(
            admissionRequest: _request(_messageId),
            proposedAnswer: ContentAnswer(content: _text('answer two')),
            resultSizeGate: (candidate) {
              gatedCandidate = candidate;
              return false;
            },
          ),
          throwsA(isA<AgentWriteStageResultTooLargeException>()),
        );

        expect(gatedCandidate, isNotNull);
        expect(gatedCandidate!.id, startsWith('proposal_'));
        expect(gatedCandidate!.preview.stem, hugeDraft.stem);
        expect(gatedCandidate!.outcome, AgentWriteProposalOutcome.pending);
        expect(
          service.proposalById(first.proposal.id).outcome,
          AgentWriteProposalOutcome.pending,
          reason: 'A rejected result-size gate must not supersede the prior '
              'pending proposal.',
        );

        // No hidden proposal or stale active entry: staging the same payload
        // with a passing gate creates a fresh id instead of replaying the
        // rejected candidate.
        final staged = (await service.stageProposal(
          admissionRequest: _request(_messageId),
          proposedAnswer: ContentAnswer(content: _text('answer two')),
          resultSizeGate: (_) => true,
        )) as AgentWriteStageResultStaged;
        expect(staged.proposal.id, isNot(first.proposal.id));
        expect(staged.proposal.outcome, AgentWriteProposalOutcome.pending);
        expect(
          service.proposalById(first.proposal.id).outcome,
          AgentWriteProposalOutcome.superseded,
        );
      },
    );
  });
}
