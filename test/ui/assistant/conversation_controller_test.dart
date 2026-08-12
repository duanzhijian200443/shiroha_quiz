import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/safe_write/typed_answer_command.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/assistant/conversation_controller.dart';

void main() {
  test(
      'persists User before starting exact target and projects final Assistant',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final starts = <(String, String)>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        starts.add((conversationId, userMessageId));
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    expect(await controller.send('first question'), isTrue);
    expect(repository.messages, hasLength(1));
    expect(repository.messages.single.role, ConversationMessageRole.user);
    expect(starts, <(String, String)>[
      ('conversation-1', repository.messages.single.messageId),
    ]);
    expect(controller.turnPhase, AssistantTurnPhase.thinking);

    turns.single.emit(const AgentTurnTextDelta('A'));
    turns.single.emit(const AgentTurnTextDelta('B'));
    await _flush();
    expect(controller.transientAssistantText, 'AB');
    expect(controller.activeThread!.messages, hasLength(1));

    final assistant = repository.persistAssistant('AB');
    turns.single.complete(AgentTurnSuccess(assistantMessage: assistant));
    await _flush();
    expect(controller.transientAssistantText, isEmpty);
    expect(controller.activeThread!.messages, hasLength(2));
    expect(controller.activeThread!.messages.last, assistant);
    expect(controller.turnPhase, AssistantTurnPhase.idle);
  });

  test('projects Web and local tool lifecycle without exposing payloads',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness();
    final controller = _controller(repository, start: turn.start);

    await controller.send('study overview');
    turn.emit(
      const AgentTurnWebSearchEvent(AgentProviderWebSearchPhase.searching),
    );
    await _flush();
    expect(controller.turnPhase, AssistantTurnPhase.searchingWeb);
    expect(controller.turnStatusMessage, '正在搜索网页…');

    turn.emit(
      const AgentTurnToolCall(
        callId: 'private-call-id',
        name: 'get_study_overview',
      ),
    );
    await _flush();
    expect(controller.turnPhase, AssistantTurnPhase.usingLocalTool);
    expect(controller.turnStatusMessage, '正在读取学习概览…');
    expect(controller.turnStatusMessage, isNot(contains('private-call-id')));
  });

  test('failure retry targets same User and never appends a duplicate User',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final targets = <String>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        targets.add(userMessageId);
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    await controller.send('retry me');
    turns[0].emit(const AgentTurnTextDelta('partial'));
    turns[0].complete(
      const AgentTurnFailed(AgentTurnFailure.temporarilyUnavailable),
    );
    await _flush();
    expect(controller.canRetry, isTrue);
    expect(controller.transientAssistantText, 'partial');
    expect(repository.messages.where(_isUser), hasLength(1));

    expect(await controller.retryLastTurn(), isTrue);
    expect(targets, <String>[targets.first, targets.first]);
    expect(repository.messages.where(_isUser), hasLength(1));

    final assistant = repository.persistAssistant('final');
    turns[1].complete(AgentTurnSuccess(assistantMessage: assistant));
    await _flush();
    expect(controller.activeThread!.messages.where(_isUser), hasLength(1));
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));
  });

  test('cancel retains User and never promotes partial text to history',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness(cancelCompletes: true);
    final controller = _controller(repository, start: turn.start);

    await controller.send('cancel me');
    turn.emit(const AgentTurnTextDelta('partial'));
    await _flush();
    controller.cancelActiveTurn();
    await _flush();

    expect(turn.cancelled, isTrue);
    expect(repository.messages.where(_isUser), hasLength(1));
    expect(repository.messages.where(_isAssistant), isEmpty);
    expect(controller.activeThread!.messages.where(_isAssistant), isEmpty);
    expect(controller.transientAssistantText, 'partial');
    expect(controller.turnPhase, AssistantTurnPhase.cancelled);
  });

  test('already-completed result never duplicates persisted Assistant in UI',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness();
    final controller = _controller(repository, start: turn.start);

    await controller.send('once');
    final assistant = repository.persistAssistant('done');
    turn.complete(AgentTurnAlreadyCompleted(assistantMessage: assistant));
    await _flush();
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));

    // The same terminal identity cannot produce a second bubble.
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));
  });

  test('unconfigured Agent blocks pre-persist send with a safe settings hint',
      () async {
    final repository = _MemoryRepository();
    var providerStarts = 0;
    final controller = _controller(
      repository,
      configured: false,
      start: ({required conversationId, required userMessageId}) {
        providerStarts++;
        return _TurnHarness().session;
      },
    );

    expect(await controller.send('do not persist'), isFalse);
    expect(repository.messages, isEmpty);
    expect(repository.conversation, isNull);
    expect(providerStarts, 0);
    expect(controller.turnFailure, AgentTurnFailure.agentUnconfigured);
    expect(controller.needsAgentSettings, isTrue);
    expect(controller.errorMessage, isNot(contains('Exception')));
  });

  test('typed deletion and unavailable-scope failures map to safe UX',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    await controller.send('deleted');
    turns[0].complete(
      const AgentTurnFailed(AgentTurnFailure.conversationUnavailable),
    );
    await _flush();
    expect(controller.errorMessage, '对话已删除，回复未保存');

    await controller.retryLastTurn();
    turns[1].complete(
      const AgentTurnFailed(AgentTurnFailure.scopeUnavailable),
    );
    await _flush();
    expect(controller.errorMessage, '学习空间已删除，无法保存回复');
    expect(repository.messages.where(_isAssistant), isEmpty);
  });

  group('W0 proposal approval', () {
    test(
        'staged event projects the card and approve stays disabled while the '
        'turn is active', () async {
      final repository = _MemoryRepository();
      final turns = <_TurnHarness>[];
      final persistence = _FakeProposalPersistence();
      final service = AgentWriteProposalService(persistence);
      final controller = _controller(
        repository,
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          turns.add(turn);
          return turn.session;
        },
        proposalService: service,
      );

      expect(await controller.send('question'), isTrue);
      final proposal = await _stagePendingProposal(turns, persistence, service);

      expect(controller.hasProposalCard, isTrue);
      expect(controller.proposalId, proposal.id);
      expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);
      expect(controller.canApproveProposal, isFalse);
      expect(controller.canRejectProposal, isTrue);

      await _completeTurn(turns, controller);
      expect(controller.canApproveProposal, isTrue);
    });

    test('approve submits only the proposal identity and reports committed',
        () async {
      final repository = _MemoryRepository();
      final turns = <_TurnHarness>[];
      final persistence = _FakeProposalPersistence();
      final service = AgentWriteProposalService(persistence);
      final controller = _controller(
        repository,
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          turns.add(turn);
          return turn.session;
        },
        proposalService: service,
      );

      expect(await controller.send('question'), isTrue);
      await _stagePendingProposal(turns, persistence, service);
      await _completeTurn(turns, controller);

      await controller.approveProposal();

      expect(controller.proposalOutcome, AgentWriteProposalOutcome.committed);
      expect(persistence.commitCalls, hasLength(1));
      expect(
        persistence.commitCalls.single.proposedAnswer,
        ContentAnswer(content: _w0Text('answer')),
      );
    });

    test('late approval result never overwrites a newer staged proposal',
        () async {
      final repository = _MemoryRepository();
      final turns = <_TurnHarness>[];
      final commitBarrier = Completer<void>();
      final persistence = _FakeProposalPersistence()
        ..commitBarrier = commitBarrier;
      final service = AgentWriteProposalService(persistence);
      final controller = _controller(
        repository,
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          turns.add(turn);
          return turn.session;
        },
        proposalService: service,
      );

      expect(await controller.send('first question'), isTrue);
      final proposalA =
          await _stagePendingProposal(turns, persistence, service);
      await _completeTurn(turns, controller);

      final approvalA = controller.approveProposal();
      await _waitUntil(() => persistence.commitCalls.length == 1);
      expect(controller.proposalActionPending, isTrue);

      expect(await controller.send('second question'), isTrue);
      final stagedB = await service.stageProposal(
        admissionRequest: AgentWriteAdmissionRequest(
          sourceConversationId: 'conversation-1',
          sourceMessageId: 'message-2',
          scope: ConversationScope.global(),
          targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
        ),
        proposedAnswer: ContentAnswer(content: _w0Text('second answer')),
      );
      final proposalB = (stagedB as AgentWriteStageResultStaged).proposal;
      turns[1].emit(
        AgentTurnProposalStaged(
          proposalId: proposalB.id,
          outcome: 'pending',
          preview: _proposalPreviewMap(),
        ),
      );
      await _flush();
      expect(proposalB.id, isNot(proposalA.id));
      expect(controller.proposalId, proposalB.id);
      expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);

      commitBarrier.complete();
      await approvalA;

      expect(persistence.commitCalls, hasLength(1));
      expect(persistence.commitCalls.single.sourceMessageId, 'message-1');
      expect(controller.proposalId, proposalB.id);
      expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);

      turns[1].complete(
        AgentTurnSuccess(
          assistantMessage: ConversationMessage(
            messageId: 'assistant-2',
            conversationId: 'conversation-1',
            sequence: 3,
            role: ConversationMessageRole.assistant,
            content: 'ok',
            createdAt: DateTime.fromMillisecondsSinceEpoch(3, isUtc: true),
          ),
        ),
      );
      await _waitUntil(() => !controller.hasActiveTurn);
      expect(controller.proposalId, proposalB.id);
      expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);
      expect(controller.canApproveProposal, isTrue);
    });

    test('reject reports rejected with zero formal writes', () async {
      final repository = _MemoryRepository();
      final turns = <_TurnHarness>[];
      final persistence = _FakeProposalPersistence();
      final service = AgentWriteProposalService(persistence);
      final controller = _controller(
        repository,
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          turns.add(turn);
          return turn.session;
        },
        proposalService: service,
      );

      expect(await controller.send('question'), isTrue);
      await _stagePendingProposal(turns, persistence, service);
      await _completeTurn(turns, controller);

      controller.rejectProposal();

      expect(controller.proposalOutcome, AgentWriteProposalOutcome.rejected);
      expect(persistence.commitCalls, isEmpty);
    });

    test('natural-language agreement never triggers a commit', () async {
      final repository = _MemoryRepository();
      final turns = <_TurnHarness>[];
      final persistence = _FakeProposalPersistence();
      final service = AgentWriteProposalService(persistence);
      final controller = _controller(
        repository,
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          turns.add(turn);
          return turn.session;
        },
        proposalService: service,
      );

      expect(await controller.send('\u597d\u7684'), isTrue);
      await _completeTurn(turns, controller);

      expect(controller.hasProposalCard, isFalse);
      expect(persistence.commitCalls, isEmpty);
    });

    test('commit failures project safe stale and unknown outcomes', () async {
      final stalePersistence = _FakeProposalPersistence()
        ..commitError = const TypedAnswerMutationException(
          TypedAnswerMutationFailure.stale,
        );
      final staleService = AgentWriteProposalService(stalePersistence);
      final staleTurns = <_TurnHarness>[];
      final staleController = _controller(
        _MemoryRepository(),
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          staleTurns.add(turn);
          return turn.session;
        },
        proposalService: staleService,
      );
      expect(await staleController.send('question'), isTrue);
      await _stagePendingProposal(staleTurns, stalePersistence, staleService);
      await _completeTurn(staleTurns, staleController);
      await staleController.approveProposal();
      expect(
        staleController.proposalOutcome,
        AgentWriteProposalOutcome.stale,
      );
      expect(staleController.proposalStatusText, isNotNull);

      final ambiguousPersistence = _FakeProposalPersistence()
        ..commitError = const TypedAnswerMutationException(
          TypedAnswerMutationFailure.transactionFailed,
        );
      final ambiguousService = AgentWriteProposalService(ambiguousPersistence);
      final ambiguousTurns = <_TurnHarness>[];
      final ambiguousController = _controller(
        _MemoryRepository(),
        start: ({required conversationId, required userMessageId}) {
          final turn = _TurnHarness();
          ambiguousTurns.add(turn);
          return turn.session;
        },
        proposalService: ambiguousService,
      );
      expect(await ambiguousController.send('question'), isTrue);
      await _stagePendingProposal(
        ambiguousTurns,
        ambiguousPersistence,
        ambiguousService,
      );
      await _completeTurn(ambiguousTurns, ambiguousController);
      await ambiguousController.approveProposal();
      expect(
        ambiguousController.proposalOutcome,
        AgentWriteProposalOutcome.unknownOutcome,
      );
      expect(ambiguousController.proposalStatusText, isNotNull);
    });
  });

  group('W0 proposal passive-dismissal restoration', () {
    test(
      'switching away and back restores the exact pending proposal and '
      'preview',
      () async {
        final repository = _MemoryRepository();
        final turns = <_TurnHarness>[];
        final persistence = _FakeProposalPersistence();
        final service = AgentWriteProposalService(persistence);
        final controller = _controller(
          repository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            turns.add(turn);
            return turn.session;
          },
          proposalService: service,
        );
        await repository.seedConversation(
          'conversation-other',
          'message-seed',
        );

        expect(await controller.send('question'), isTrue);
        final proposal =
            await _stagePendingProposal(turns, persistence, service);
        await _completeTurn(turns, controller);
        expect(controller.proposalId, proposal.id);

        expect(await controller.openConversation('conversation-other'), isTrue);
        expect(controller.hasProposalCard, isFalse);

        expect(await controller.openConversation('conversation-1'), isTrue);
        expect(controller.proposalId, proposal.id);
        expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);
        expect(controller.proposalPreview['bank_name'], 'w0_u1_synthetic_bank');
        expect(controller.proposalPreview['proposed_answer'], isA<Map>());
        expect(controller.canApproveProposal, isTrue);
      },
    );

    test(
      'rejected and committed outcomes restore accurately when previously '
      'bound',
      () async {
        final rejectedRepository = _MemoryRepository();
        final rejectedTurns = <_TurnHarness>[];
        final rejectedPersistence = _FakeProposalPersistence();
        final rejectedService = AgentWriteProposalService(rejectedPersistence);
        final rejectedController = _controller(
          rejectedRepository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            rejectedTurns.add(turn);
            return turn.session;
          },
          proposalService: rejectedService,
        );
        await rejectedRepository.seedConversation(
          'conversation-other',
          'message-seed',
        );
        await rejectedController.send('question');
        final rejectedProposal = await _stagePendingProposal(
          rejectedTurns,
          rejectedPersistence,
          rejectedService,
        );
        await _completeTurn(rejectedTurns, rejectedController);
        rejectedController.rejectProposal();
        expect(
          rejectedController.proposalOutcome,
          AgentWriteProposalOutcome.rejected,
        );
        await rejectedController.openConversation('conversation-other');
        await rejectedController.openConversation('conversation-1');
        expect(rejectedController.proposalId, rejectedProposal.id);
        expect(
          rejectedController.proposalOutcome,
          AgentWriteProposalOutcome.rejected,
        );

        final committedRepository = _MemoryRepository();
        final committedTurns = <_TurnHarness>[];
        final committedPersistence = _FakeProposalPersistence();
        final committedService =
            AgentWriteProposalService(committedPersistence);
        final committedController = _controller(
          committedRepository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            committedTurns.add(turn);
            return turn.session;
          },
          proposalService: committedService,
        );
        await committedRepository.seedConversation(
          'conversation-other',
          'message-seed',
        );
        await committedController.send('question');
        final committedProposal = await _stagePendingProposal(
          committedTurns,
          committedPersistence,
          committedService,
        );
        await _completeTurn(committedTurns, committedController);
        await committedController.approveProposal();
        expect(
          committedController.proposalOutcome,
          AgentWriteProposalOutcome.committed,
        );
        await committedController.openConversation('conversation-other');
        await committedController.openConversation('conversation-1');
        expect(committedController.proposalId, committedProposal.id);
        expect(
          committedController.proposalOutcome,
          AgentWriteProposalOutcome.committed,
        );
      },
    );

    test(
      'superseded and stale outcomes restore accurately when previously '
      'bound',
      () async {
        final supersededRepository = _MemoryRepository();
        final supersededTurns = <_TurnHarness>[];
        final supersededPersistence = _FakeProposalPersistence();
        final supersededService =
            AgentWriteProposalService(supersededPersistence);
        final supersededController = _controller(
          supersededRepository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            supersededTurns.add(turn);
            return turn.session;
          },
          proposalService: supersededService,
        );
        await supersededRepository.seedConversation(
          'conversation-other',
          'message-seed',
        );
        await supersededController.send('question');
        final boundProposal = await _stagePendingProposal(
          supersededTurns,
          supersededPersistence,
          supersededService,
        );
        await _completeTurn(supersededTurns, supersededController);
        // A different payload on the same source turn supersedes the bound
        // proposal before any new event is projected.
        final superseding = (await supersededService.stageProposal(
          admissionRequest: AgentWriteAdmissionRequest(
            sourceConversationId: 'conversation-1',
            sourceMessageId: 'message-1',
            scope: ConversationScope.global(),
            targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
          ),
          proposedAnswer: ContentAnswer(content: _w0Text('second answer')),
        )) as AgentWriteStageResultStaged;
        expect(superseding.proposal.id, isNot(boundProposal.id));
        expect(
          supersededService.proposalById(boundProposal.id).outcome,
          AgentWriteProposalOutcome.superseded,
        );
        await supersededController.openConversation('conversation-other');
        await supersededController.openConversation('conversation-1');
        expect(supersededController.proposalId, boundProposal.id);
        expect(
          supersededController.proposalOutcome,
          AgentWriteProposalOutcome.superseded,
        );
        expect(supersededController.canApproveProposal, isFalse);

        final staleRepository = _MemoryRepository();
        final staleTurns = <_TurnHarness>[];
        final stalePersistence = _FakeProposalPersistence()
          ..commitError = const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        final staleService = AgentWriteProposalService(stalePersistence);
        final staleController = _controller(
          staleRepository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            staleTurns.add(turn);
            return turn.session;
          },
          proposalService: staleService,
        );
        await staleRepository.seedConversation(
          'conversation-other',
          'message-seed',
        );
        await staleController.send('question');
        final staleProposal = await _stagePendingProposal(
          staleTurns,
          stalePersistence,
          staleService,
        );
        await _completeTurn(staleTurns, staleController);
        await staleController.approveProposal();
        expect(
          staleController.proposalOutcome,
          AgentWriteProposalOutcome.stale,
        );
        await staleController.openConversation('conversation-other');
        await staleController.openConversation('conversation-1');
        expect(staleController.proposalId, staleProposal.id);
        expect(
          staleController.proposalOutcome,
          AgentWriteProposalOutcome.stale,
        );
      },
    );

    test(
      'different conversations restore their own exact proposal ids without '
      'collapsing to one per-Conversation rule',
      () async {
        final repository = _MemoryRepository();
        final turns = <_TurnHarness>[];
        final targets = <(String, String)>[];
        final persistence = _FakeProposalPersistence();
        final service = AgentWriteProposalService(persistence);
        final controller = _controller(
          repository,
          start: ({required conversationId, required userMessageId}) {
            targets.add((conversationId, userMessageId));
            final turn = _TurnHarness();
            turns.add(turn);
            return turn.session;
          },
          proposalService: service,
        );

        expect(await controller.send('question in A'), isTrue);
        final proposalA =
            await _stagePendingProposal(turns, persistence, service);
        await _completeTurn(turns, controller);

        await repository.seedConversation(
          'conversation-2',
          'message-seed-2',
        );
        expect(await controller.openConversation('conversation-2'), isTrue);
        expect(await controller.send('question in B'), isTrue);
        final (conversationB, messageB) = targets[1];
        final proposalB = await _stageProposalOn(
          turns[1],
          persistence,
          service,
          conversationId: conversationB,
          messageId: messageB,
        );
        await _completeTurnOn(turns[1], controller);
        expect(proposalB.id, isNot(proposalA.id));
        expect(controller.proposalId, proposalB.id);

        expect(await controller.openConversation('conversation-1'), isTrue);
        expect(controller.proposalId, proposalA.id);
        expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);

        expect(await controller.openConversation('conversation-2'), isTrue);
        expect(controller.proposalId, proposalB.id);
        expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);
      },
    );

    test(
      'different source turns in one conversation remain reachable in '
      'deterministic order',
      () async {
        final repository = _MemoryRepository();
        final turns = <_TurnHarness>[];
        final targets = <(String, String)>[];
        final persistence = _FakeProposalPersistence();
        final service = AgentWriteProposalService(persistence);
        final controller = _controller(
          repository,
          start: ({required conversationId, required userMessageId}) {
            targets.add((conversationId, userMessageId));
            final turn = _TurnHarness();
            turns.add(turn);
            return turn.session;
          },
          proposalService: service,
        );

        expect(await controller.send('first question'), isTrue);
        final proposalA =
            await _stagePendingProposal(turns, persistence, service);
        await _completeTurn(turns, controller);

        expect(await controller.send('second question'), isTrue);
        expect(controller.proposalId, proposalA.id);
        final (conversationId, messageId) = targets[1];
        final proposalB = await _stageProposalOn(
          turns[1],
          persistence,
          service,
          conversationId: conversationId,
          messageId: messageId,
        );
        await _completeTurnOn(turns[1], controller);

        expect(proposalB.id, isNot(proposalA.id));
        expect(controller.proposalId, proposalA.id);
        expect(service.proposalById(proposalA.id).outcome,
            AgentWriteProposalOutcome.pending);
        expect(service.proposalById(proposalB.id).outcome,
            AgentWriteProposalOutcome.pending);

        controller.rejectProposal();

        expect(service.proposalById(proposalA.id).outcome,
            AgentWriteProposalOutcome.rejected);
        expect(controller.proposalId, proposalB.id);
        expect(controller.proposalOutcome, AgentWriteProposalOutcome.pending);
        expect(controller.canApproveProposal, isTrue);
      },
    );

    test(
      'deleting the source conversation drops the binding; a fresh service '
      'restores nothing',
      () async {
        final repository = _MemoryRepository();
        final turns = <_TurnHarness>[];
        final persistence = _FakeProposalPersistence();
        final service = AgentWriteProposalService(persistence);
        final controller = _controller(
          repository,
          start: ({required conversationId, required userMessageId}) {
            final turn = _TurnHarness();
            turns.add(turn);
            return turn.session;
          },
          proposalService: service,
        );
        await controller.send('question');
        await _stagePendingProposal(turns, persistence, service);
        await _completeTurn(turns, controller);
        expect(controller.hasProposalCard, isTrue);

        // Process/service replacement analogue: a fresh controller and a
        // fresh in-memory service know no proposal identity.
        final freshController = _controller(
          repository,
          start: ({required conversationId, required userMessageId}) {
            return _TurnHarness().session;
          },
          proposalService:
              AgentWriteProposalService(_FakeProposalPersistence()),
        );
        await freshController.openConversation('conversation-1');
        expect(freshController.hasProposalCard, isFalse);

        expect(await controller.deleteActiveConversation(), isTrue);
        expect(controller.hasProposalCard, isFalse);
        await controller.openConversation('conversation-1');
        expect(controller.hasProposalCard, isFalse);
      },
    );
  });
}

ConversationController _controller(
  _MemoryRepository repository, {
  required AgentTurnStarter start,
  bool configured = true,
  AgentWriteProposalService? proposalService,
}) {
  final configStore = _ConfigStore(
    configured
        ? const AgentConfigCodec().encode(
            AgentConfig(
              providerKind: AgentProviderKind.deepSeekResponses,
              mainProfileId: 'profile-1',
            ),
          )
        : null,
  );
  return ConversationController(
    ConversationService(
      repository: repository,
      conversationIdFactory: () => 'conversation-1',
      messageIdFactory: repository.nextMessageId,
      clock: repository.tick,
    ),
    agentSettingsService: AgentSettingsService(
      configStore: configStore,
      profileCatalog: _Profiles(),
    ),
    startAgentTurn: start,
    proposalService: proposalService,
  );
}

bool _isUser(ConversationMessage message) =>
    message.role == ConversationMessageRole.user;
bool _isAssistant(ConversationMessage message) =>
    message.role == ConversationMessageRole.assistant;
Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _TurnHarness {
  _TurnHarness({this.cancelCompletes = false});

  final bool cancelCompletes;
  final StreamController<AgentTurnEvent> _events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> _result = Completer<AgentTurnResult>();
  bool cancelled = false;

  late final AgentTurnSession session = AgentTurnSession(
    events: _events.stream,
    result: _result.future,
    cancel: () {
      cancelled = true;
      if (cancelCompletes && !_result.isCompleted) {
        complete(const AgentTurnFailed(AgentTurnFailure.cancelled));
      }
    },
  );

  AgentTurnSession start({
    required String conversationId,
    required String userMessageId,
  }) =>
      session;

  void emit(AgentTurnEvent event) => _events.add(event);

  void complete(AgentTurnResult result) {
    if (_result.isCompleted) return;
    _result.complete(result);
    unawaited(_events.close());
  }
}

final class _FakeProposalPersistence implements AgentWritePersistencePort {
  _FakeProposalPersistence({AgentWriteAdmissionResult? admissionResult})
      : admissionResult = admissionResult ??
            AgentWriteAdmissionGranted(
              AgentWriteAdmittedTarget(
                storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
                bankName: 'w0_u1_synthetic_bank',
                draft: _w0Draft(),
              ),
            );

  AgentWriteAdmissionResult admissionResult;
  Object? commitError;
  Completer<void>? commitBarrier;
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
    final barrier = commitBarrier;
    if (barrier != null) await barrier.future;
    final failure = commitError;
    if (failure != null) throw failure;
  }
}

RichContent _w0Text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

QuestionDraftV2 _w0Draft() {
  return QuestionDraftV2(
    questionId: 'w0_u1_content_q',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: _w0Text('Stem.'),
    explanation: _w0Text('Explanation.'),
  );
}

/// Structured preview mirroring the Application-owned tool contract.
Map<String, Object?> _proposalPreviewMap() {
  return <String, Object?>{
    'bank_name': 'w0_u1_synthetic_bank',
    'stem': <Map<String, Object?>>[
      <String, Object?>{'type': 'text', 'text': 'Stem.'},
    ],
    'options': <Map<String, Object?>>[
      <String, Object?>{
        'label': 'A',
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': 'first'},
        ],
      },
    ],
    'proposed_answer': <String, Object?>{
      'kind': 'content',
      'nodes': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': 'answer'},
      ],
    },
  };
}

Future<AgentWriteProposal> _primeProposal(
  _FakeProposalPersistence persistence,
  AgentWriteProposalService service,
) async {
  final staged = await service.stageProposal(
    admissionRequest: AgentWriteAdmissionRequest(
      sourceConversationId: 'conversation-1',
      sourceMessageId: 'message-1',
      scope: ConversationScope.global(),
      targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
    ),
    proposedAnswer: ContentAnswer(content: _w0Text('answer')),
  );
  return (staged as AgentWriteStageResultStaged).proposal;
}

Future<AgentWriteProposal> _stagePendingProposal(
  List<_TurnHarness> turns,
  _FakeProposalPersistence persistence,
  AgentWriteProposalService service,
) async {
  final proposal = await _primeProposal(persistence, service);
  turns.single.emit(
    AgentTurnProposalStaged(
      proposalId: proposal.id,
      outcome: 'pending',
      preview: _proposalPreviewMap(),
    ),
  );
  await _flush();
  return proposal;
}

Future<AgentWriteProposal> _stageProposalOn(
  _TurnHarness turn,
  _FakeProposalPersistence persistence,
  AgentWriteProposalService service, {
  required String conversationId,
  required String messageId,
}) async {
  final staged = await service.stageProposal(
    admissionRequest: AgentWriteAdmissionRequest(
      sourceConversationId: conversationId,
      sourceMessageId: messageId,
      scope: ConversationScope.global(),
      targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
    ),
    proposedAnswer: ContentAnswer(content: _w0Text('answer')),
  );
  final proposal = (staged as AgentWriteStageResultStaged).proposal;
  turn.emit(
    AgentTurnProposalStaged(
      proposalId: proposal.id,
      outcome: 'pending',
      preview: _proposalPreviewMap(),
    ),
  );
  await _flush();
  return proposal;
}

Future<void> _completeTurn(
  List<_TurnHarness> turns,
  ConversationController controller,
) async {
  turns.single.complete(
    AgentTurnSuccess(
      assistantMessage: ConversationMessage(
        messageId: 'assistant-1',
        conversationId: 'conversation-1',
        sequence: 2,
        role: ConversationMessageRole.assistant,
        content: 'ok',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
      ),
    ),
  );
  await _waitUntil(() => !controller.hasActiveTurn);
}

Future<void> _completeTurnOn(
  _TurnHarness turn,
  ConversationController controller,
) async {
  turn.complete(
    AgentTurnSuccess(
      assistantMessage: ConversationMessage(
        messageId: 'assistant-turn',
        conversationId: controller.activeThread!.conversation.conversationId,
        sequence: 2,
        role: ConversationMessageRole.assistant,
        content: 'ok',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
      ),
    ),
  );
  await _waitUntil(() => !controller.hasActiveTurn);
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await _flush();
  }
  expect(condition(), isTrue);
}

final class _ConfigStore implements AgentConfigStorePort {
  _ConfigStore(this.encoded);

  String? encoded;

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _Profiles implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async =>
      <AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'profile-1',
          displayName: 'Main',
          modelName: 'deepseek-v4-flash',
        ),
      ];
}

final class _MemoryRepository extends Fake
    implements ConversationRepositoryPort {
  Conversation? conversation;
  final Map<String, Conversation> _conversationsById = <String, Conversation>{};
  final List<ConversationMessage> messages = <ConversationMessage>[];
  var _messageCounter = 0;
  var _milliseconds = 1;

  String nextMessageId() => 'message-${++_messageCounter}';
  DateTime tick() =>
      DateTime.fromMillisecondsSinceEpoch(_milliseconds++, isUtc: true);

  Future<void> seedConversation(String conversationId, String messageId) {
    return createWithFirstMessage(
      conversation: Conversation(
        conversationId: conversationId,
        scope: ConversationScope.global(),
        title: 'Synthetic $conversationId',
        createdAt: tick(),
        updatedAt: tick(),
      ),
      firstMessage: ConversationMessage(
        messageId: messageId,
        conversationId: conversationId,
        sequence: 1,
        role: ConversationMessageRole.user,
        content: 'seeded',
        createdAt: tick(),
      ),
      fileIds: const <String>[],
      attachedAt: tick(),
    );
  }

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    _conversationsById[conversation.conversationId] = conversation;
    this.conversation = conversation;
    messages.add(firstMessage);
    return _sliceFor(conversation.conversationId);
  }

  @override
  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) async {
    final current = _conversationsById[conversationId];
    if (current == null) {
      throw const ConversationException(
          ConversationFailure.conversationNotFound);
    }
    final message = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: messages
              .where((message) => message.conversationId == conversationId)
              .length +
          1,
      role: role,
      content: content,
      createdAt: createdAt,
    );
    messages.add(message);
    conversation = current.withUpdatedAt(createdAt);
    _conversationsById[conversationId] = conversation!;
    return AppendMessageResult(conversation: conversation!, message: message);
  }

  ConversationMessage persistAssistant(String content) {
    final conversationId = conversation!.conversationId;
    final message = ConversationMessage(
      messageId: nextMessageId(),
      conversationId: conversationId,
      sequence: messages
              .where((message) => message.conversationId == conversationId)
              .length +
          1,
      role: ConversationMessageRole.assistant,
      content: content,
      createdAt: tick(),
    );
    messages.add(message);
    return message;
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async {
    if (!_conversationsById.containsKey(conversationId)) {
      throw const ConversationException(
        ConversationFailure.conversationNotFound,
      );
    }
    return _sliceFor(conversationId);
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _conversationsById.remove(conversationId);
    messages.removeWhere(
      (message) => message.conversationId == conversationId,
    );
    if (conversation?.conversationId == conversationId) {
      conversation = null;
    }
  }

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      _conversationsById.values.toList();

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) async =>
      const <Conversation>[];

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  ConversationThreadSlice _sliceFor(String conversationId) =>
      ConversationThreadSlice(
        conversation: _conversationsById[conversationId]!,
        messages: messages
            .where((message) => message.conversationId == conversationId)
            .toList(),
        files: const <ConversationFileRef>[],
        hasMoreBefore: false,
        nextBeforeSequence: null,
      );
}
