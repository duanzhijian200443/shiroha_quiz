import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal.dart';
import 'package:shiroha_quiz/application/safe_write/agent_write_proposal_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_draft.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_artifact_cards.dart';
import 'package:shiroha_quiz/ui/assistant/assistant_artifact_controller.dart';

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.dispose());

  test('different source turns retain both kinds and notify the next card',
      () async {
    final first = await f.proposal('user-1');
    final second = await f.proposal('user-2');
    final firstPlan = await f.plan('user-1');
    final secondPlan = await f.plan('user-2');
    expect(f.controller.proposalId, first.id);
    expect(f.controller.studyPlanDraftId, firstPlan.draftId);
    final seen = <(String?, String?)>[];
    f.controller.addListener(() =>
        seen.add((f.controller.proposalId, f.controller.studyPlanDraftId)));
    await f.controller.approveProposal();
    await f.controller.initiateAdoptStudyPlan();
    expect(seen, contains((second.id, firstPlan.draftId)));
    expect(seen, contains((second.id, secondPlan.draftId)));
    expect(f.writes.commits.single.sourceMessageId, 'user-1');
    expect(f.planWrites.adoptions.single, 'user-1');
  });

  test('foreign conversation/message and unknown identities are never bound',
      () async {
    final proposal = await f.proposal('user-other', project: false);
    f.projectProposal(proposal, messageId: 'user-current');
    expect(f.controller.hasProposalCard, isFalse);
    f.projectProposal(proposal, conversationId: 'conversation-other');
    expect(f.controller.hasProposalCard, isFalse);
    f.controller.projectTurnArtifact(
        const AgentTurnProposalStaged(
            proposalId: 'missing', outcome: 'pending', preview: {}),
        conversationId: 'conversation-a',
        userMessageId: 'user-other');
    final plan = await f.plan('user-other', project: false);
    f.projectPlan(plan, messageId: 'user-current');
    expect(f.controller.hasStudyPlanCard, isFalse);
    f.switchTo('conversation-a');
    expect(f.controller.hasProposalCard, isFalse);
    expect(f.controller.hasStudyPlanCard, isFalse);
  });

  test('superseded replay cannot hide the pending proposal or plan', () async {
    final old = await f.proposal('user-1');
    final oldPlan = await f.plan('user-1');
    final revised = await f.proposal('user-1', answer: 'Revised');
    final revisedPlan = await f.plan('user-1', goal: 'Revised');
    f.projectProposal(f.proposals.proposalById(old.id), outcome: 'superseded');
    f.projectPlan(f.plans.draftById(oldPlan.draftId), outcome: 'superseded');
    f.switchTo('conversation-a');
    expect(f.controller.proposalId, revised.id);
    expect(f.controller.studyPlanDraftId, revisedPlan.draftId);
  });

  test('passive dismissal re-reads typed owner outcomes without writes',
      () async {
    final proposal = await f.proposal('user-1');
    final plan = await f.plan('user-1');
    final rejectProposal =
        f.controller.bindProposalAction(f.controller.rejectProposal);
    final rejectPlan =
        f.controller.bindStudyPlanAction(f.controller.rejectStudyPlan);
    f.switchTo('conversation-b');
    expect(f.controller.hasProposalCard, isFalse);
    expect(f.controller.hasStudyPlanCard, isFalse);
    f.proposals.rejectProposal(proposal.id);
    f.plans.rejectDraft(plan.draftId);
    f.switchTo('conversation-a');
    rejectProposal();
    rejectPlan();
    expect(f.controller.proposalId, proposal.id);
    expect(f.controller.proposalOutcome, AgentWriteProposalOutcome.rejected);
    expect(f.controller.studyPlanDraftId, plan.draftId);
    expect(f.controller.studyPlanOutcome, StudyPlanDraftOutcome.rejected);
    expect(f.writes.commits, isEmpty);
    expect(f.planWrites.adoptions, isEmpty);
  });

  test('late approval cannot project into another conversation', () async {
    final proposal = await f.proposal('user-1');
    f.writes.barrier = Completer<void>();
    final approval = f.controller.approveProposal();
    await f.controller.approveProposal();
    f.controller.rejectProposal();
    f.switchTo('conversation-b');
    var notifications = 0;
    f.controller.addListener(() => notifications++);
    f.writes.barrier!.complete();
    await approval;
    expect(notifications, 0);
    expect(f.controller.hasProposalCard, isFalse);
    expect(f.writes.commits, hasLength(1));
    f.switchTo('conversation-a');
    expect(f.controller.proposalId, proposal.id);
    expect(f.controller.proposalOutcome, AgentWriteProposalOutcome.committed);
  });

  test('away-and-back during approval retains busy and refreshes the owner',
      () async {
    await f.proposal('user-1');
    f.writes.barrier = Completer<void>();
    final approval = f.controller.approveProposal();
    f.switchTo('conversation-b');
    f.switchTo('conversation-a');
    expect(f.controller.proposalActionPending, isTrue);
    expect(f.controller.canApproveProposal, isFalse);
    f.writes.barrier!.complete();
    await approval;
    expect(f.controller.proposalActionPending, isFalse);
    expect(f.controller.proposalOutcome, AgentWriteProposalOutcome.committed);
    expect(f.writes.commits, hasLength(1));
  });

  test('deleting a conversation prunes bindings despite late completion',
      () async {
    await f.proposal('user-1');
    await f.plan('user-1');
    f.writes.barrier = Completer<void>();
    final approval = f.controller.approveProposal();
    f.controller.forgetConversation('conversation-a');
    f.switchTo(null);
    f.writes.barrier!.complete();
    await approval;
    f.switchTo('conversation-a');
    expect(f.controller.hasProposalCard, isFalse);
    expect(f.controller.hasStudyPlanCard, isFalse);
  });

  test('late active-plan lookup cannot authorize an away-and-back adoption',
      () async {
    await f.plan('user-1');
    f.planWrites.readBarrier = Completer<ActiveStudyPlan?>();
    final adoption = f.controller.initiateAdoptStudyPlan();
    f.switchTo('conversation-b');
    f.switchTo('conversation-a');
    expect(f.controller.studyPlanActionPending, isTrue);
    await f.controller.initiateAdoptStudyPlan();
    expect(f.planWrites.reads, 1);
    f.planWrites.readBarrier!.complete(null);
    await adoption;
    expect(f.controller.studyPlanActionPending, isFalse);
    expect(f.controller.showReplacementConfirmation, isFalse);
    expect(f.planWrites.adoptions, isEmpty);
  });

  test('a late plan lookup cannot display confirmation on a newer draft',
      () async {
    await f.plan('user-1');
    f.planWrites.readBarrier = Completer<ActiveStudyPlan?>();
    final adoption = f.controller.initiateAdoptStudyPlan();
    final revised = await f.plan('user-1', goal: 'Revised');
    f.planWrites.readBarrier!.complete(_activePlan());
    await adoption;
    expect(f.controller.studyPlanDraftId, revised.draftId);
    expect(f.controller.showReplacementConfirmation, isFalse);
    await f.controller.confirmReplacement();
    expect(f.planWrites.adoptions, isEmpty);
  });

  test('replacement requires a current exact-draft confirmation', () async {
    await f.plan('user-1');
    await f.controller.confirmReplacement();
    expect(f.planWrites.adoptions, isEmpty);
    f.planWrites.active = _activePlan();
    await f.controller.initiateAdoptStudyPlan();
    expect(f.controller.showReplacementConfirmation, isTrue);
    final confirm =
        f.controller.bindStudyPlanAction(f.controller.confirmReplacement);
    f.switchTo('conversation-b');
    f.switchTo('conversation-a');
    confirm();
    await f.controller.confirmReplacement();
    expect(f.planWrites.adoptions, isEmpty);
    await f.controller.initiateAdoptStudyPlan();
    await f.controller.confirmReplacement();
    expect(f.planWrites.expectedActivePlanIds, ['active-plan']);
    expect(f.planWrites.replacements, [true]);
  });

  test(
      'an old confirmation cannot authorize a newer observation of the same draft',
      () async {
    await f.plan('user-1');
    f.planWrites.active = _activePlan();
    await f.controller.initiateAdoptStudyPlan();
    final oldConfirm =
        f.controller.bindReplacementAction(f.controller.confirmReplacement);
    final oldCancel =
        f.controller.bindReplacementAction(f.controller.cancelReplacement);
    f.controller.cancelReplacement();
    await f.controller.initiateAdoptStudyPlan();
    oldConfirm();
    oldCancel();
    expect(f.controller.showReplacementConfirmation, isTrue);
    expect(f.planWrites.adoptions, isEmpty);
    await f.controller.confirmReplacement();
    expect(f.planWrites.adoptions, hasLength(1));
  });

  test('late adoption failure cannot overwrite the next draft', () async {
    await f.plan('user-1');
    f.planWrites.adoptBarrier = Completer<StudyPlanPersistenceCommitResult>();
    final adoption = f.controller.initiateAdoptStudyPlan();
    await f.planWrites.adoptionStarted.future;
    final next = await f.plan('user-2');
    f.planWrites.adoptBarrier!
        .complete(const StudyPlanPersistenceCommitStaleScope());
    await adoption;
    expect(f.controller.studyPlanDraftId, next.draftId);
    expect(f.controller.studyPlanActionMessage, isNull);
    expect(f.controller.canAdoptStudyPlan, isTrue);
    expect(f.planWrites.adoptions, hasLength(1));
  });

  test('move/turn guards also protect direct compatibility action calls',
      () async {
    await f.proposal('user-1');
    await f.plan('user-1');
    f.turnActive = true;
    await f.controller.approveProposal();
    await f.controller.initiateAdoptStudyPlan();
    expect(f.writes.commits, isEmpty);
    expect(f.planWrites.reads, 0);
    f.turnActive = false;
    f.moving = true;
    await f.controller.approveProposal();
    await f.controller.initiateAdoptStudyPlan();
    f.controller.rejectProposal();
    f.controller.rejectStudyPlan();
    expect(f.controller.proposalOutcome, AgentWriteProposalOutcome.pending);
    expect(f.controller.studyPlanOutcome, StudyPlanDraftOutcome.pending);
    expect(f.writes.commits, isEmpty);
    expect(f.planWrites.reads, 0);
  });

  test('dispose refuses old callbacks and ignores both late async results',
      () async {
    await f.proposal('user-1');
    await f.plan('user-1');
    f.writes.barrier = Completer<void>();
    f.planWrites.readBarrier = Completer<ActiveStudyPlan?>();
    final reject = f.controller.bindProposalAction(f.controller.rejectProposal);
    final approval = f.controller.approveProposal();
    final adoption = f.controller.initiateAdoptStudyPlan();
    var notifications = 0;
    f.controller.addListener(() => notifications++);
    f.dispose();
    reject();
    await f.controller.approveProposal();
    await f.controller.initiateAdoptStudyPlan();
    f.controller.rejectStudyPlan();
    f.writes.barrier!.complete();
    f.planWrites.readBarrier!.complete(null);
    await Future.wait([approval, adoption]);
    expect(notifications, 0);
    expect(f.writes.commits, hasLength(1));
    expect(f.planWrites.adoptions, isEmpty);
  });

  test('an explicit empty module composition exposes no artifact actions',
      () async {
    final disabled = f.newController(contributions: []);
    addTearDown(disabled.dispose);
    final proposal = await f.proposal('user-1');
    disabled.projectTurnArtifact(
        AgentTurnProposalStaged(
            proposalId: proposal.id, outcome: 'pending', preview: {}),
        conversationId: 'conversation-a',
        userMessageId: 'user-1');
    disabled.restoreConversation('conversation-a');
    expect(disabled.hasProposalCard, isFalse);
    expect(disabled.canApproveProposal, isFalse);
    expect(disabled.canAdoptStudyPlan, isFalse);
    expect(f.writes.commits, isEmpty);
  });

  testWidgets('retained card buttons cannot approve/reject a replacement card',
      (tester) async {
    await f.proposal('user-1');
    await f.plan('user-1');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AssistantArtifactCards(controller: f.controller)))));
    final approve = tester
        .widget<FilledButton>(find.byKey(const ValueKey('w0-proposal-approve')))
        .onPressed!;
    final reject = tester
        .widget<OutlinedButton>(
            find.byKey(const ValueKey('study-plan-draft-reject')))
        .onPressed!;
    final revised = await f.proposal('user-1', answer: 'Revised');
    final revisedPlan = await f.plan('user-1', goal: 'Revised');
    approve();
    reject();
    await tester.pump();
    expect(f.proposals.proposalById(revised.id).outcome,
        AgentWriteProposalOutcome.pending);
    expect(f.plans.draftById(revisedPlan.draftId).outcome,
        StudyPlanDraftOutcome.pending);
    expect(f.writes.commits, isEmpty);
    expect(f.planWrites.adoptions, isEmpty);
  });

  testWidgets('card rebuild reuses binding and removal has no business effect',
      (tester) async {
    final proposal = await f.proposal('user-1');
    final plan = await f.plan('user-1');
    Widget page() => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AssistantArtifactCards(controller: f.controller))));
    await tester.pumpWidget(page());
    expect(find.byKey(const ValueKey('w0-proposal-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('study-plan-draft-card')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    expect(f.controller.proposalId, proposal.id);
    expect(f.controller.studyPlanDraftId, plan.draftId);
    expect(f.writes.commits, isEmpty);
    expect(f.planWrites.adoptions, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _Fixture {
  final writes = _WritePort();
  final planWrites = _PlanPort();
  late final proposals = AgentWriteProposalService(writes);
  late final plans = StudyPlanDraftService(
      planningPort: _PlanningPort(),
      draftIdFactory: () => 'draft-${++_draftId}',
      clock: () => DateTime.utc(2026));
  late final commands = StudyPlanCommandService(
      draftService: plans,
      persistencePort: planWrites,
      planIdFactory: () => 'adopted-${++_planId}',
      clock: () => DateTime.utc(2026));
  String? conversationId = 'conversation-a';
  bool turnActive = false, moving = false, disposed = false;
  int _draftId = 0, _planId = 0;
  late final controller = newController();

  AssistantArtifactController newController(
          {List<ModuleUiContribution>? contributions}) =>
      AssistantArtifactController(
          proposalService: proposals,
          studyPlanDraftService: plans,
          studyPlanCommandService: commands,
          conversationId: () => conversationId,
          hasActiveTurn: () => turnActive,
          isMovingConversation: () => moving,
          contributions: contributions);

  void switchTo(String? id) {
    conversationId = id;
    controller.clearPresentation();
    if (id != null) controller.restoreConversation(id);
  }

  Future<AgentWriteProposal> proposal(String messageId,
      {String answer = 'Answer', bool project = true}) async {
    final staged = await proposals.stageProposal(
            admissionRequest: AgentWriteAdmissionRequest(
                sourceConversationId: conversationId!,
                sourceMessageId: messageId,
                scope: ConversationScope.global(),
                targetStorageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b'),
            proposedAnswer:
                ContentAnswer(content: RichContent(nodes: [TextNode(answer)])))
        as AgentWriteStageResultStaged;
    if (project) projectProposal(staged.proposal);
    return staged.proposal;
  }

  void projectProposal(AgentWriteProposal proposal,
          {String? conversationId,
          String? messageId,
          String outcome = 'pending'}) =>
      controller.projectTurnArtifact(
          AgentTurnProposalStaged(
              proposalId: proposal.id,
              outcome: outcome,
              preview: const {'bank_name': 'Synthetic'}),
          conversationId: conversationId ?? proposal.sourceConversationId,
          userMessageId: messageId ?? proposal.sourceMessageId);

  Future<StudyPlanDraft> plan(String messageId,
      {String? goal, bool project = true}) async {
    final staged = await plans.stage(
        sourceConversationId: conversationId!,
        sourceMessageId: messageId,
        sourceScope: ConversationScope.global(),
        bankName: 'Synthetic',
        goal: goal) as StudyPlanStageResultStaged;
    if (project) projectPlan(staged.draft);
    return staged.draft;
  }

  void projectPlan(StudyPlanDraft draft,
          {String? messageId, String outcome = 'pending'}) =>
      controller.projectTurnArtifact(
          AgentTurnStudyPlanDraftStaged(
              draftId: draft.draftId,
              outcome: outcome,
              preview: const {'bank_name': 'Synthetic'}),
          conversationId: draft.sourceConversationId,
          userMessageId: messageId ?? draft.sourceMessageId);

  void dispose() {
    if (disposed) return;
    disposed = true;
    controller.dispose();
  }
}

class _WritePort implements AgentWritePersistencePort {
  final commits = <AgentWriteCommitRequest>[];
  Completer<void>? barrier;
  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
          AgentWriteAdmissionRequest request) async =>
      AgentWriteAdmissionGranted(AgentWriteAdmittedTarget(
          storageId: request.targetStorageId,
          bankName: 'Synthetic',
          draft: QuestionDraftV2(
              questionId: 'question',
              kind: QuestionKind.shortAnswer,
              stem: RichContent(nodes: const [TextNode('Stem')]))));
  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commits.add(request);
    if (barrier != null) await barrier!.future;
  }
}

class _PlanningPort implements StudyPlanPlanningPort {
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext(
          {required ConversationScope sourceScope,
          required String bankName,
          required DateTime now}) async =>
      StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
          bankName: bankName,
          questionCount: 10,
          masteredCount: 1,
          dueCount: 2,
          weakCount: 3,
          newCount: 4));
}

class _PlanPort implements StudyPlanPersistencePort {
  ActiveStudyPlan? active;
  Completer<ActiveStudyPlan?>? readBarrier;
  Completer<StudyPlanPersistenceCommitResult>? adoptBarrier;
  final adoptionStarted = Completer<void>();
  int reads = 0;
  final adoptions = <String?>[],
      expectedActivePlanIds = <String?>[],
      replacements = <bool>[];
  @override
  Future<ActiveStudyPlan?> loadActivePlan() async {
    reads++;
    return readBarrier == null ? active : await readBarrier!.future;
  }

  @override
  Future<StudyPlanPersistenceCommitResult> commitAdoption(
      {required String planId,
      required String bankName,
      String? goal,
      required int dailyTarget,
      required StudyPlanPriority priority,
      int? horizonDays,
      String? sourceConversationId,
      String? sourceUserMessageId,
      required ConversationScope sourceScope,
      required DateTime adoptedAt,
      String? expectedActivePlanId,
      required bool replacementConfirmed}) async {
    adoptions.add(sourceUserMessageId);
    expectedActivePlanIds.add(expectedActivePlanId);
    replacements.add(replacementConfirmed);
    if (!adoptionStarted.isCompleted) adoptionStarted.complete();
    if (adoptBarrier != null) return adoptBarrier!.future;
    return StudyPlanPersistenceCommitSuccess(ActiveStudyPlan(
        planId: planId,
        bankName: bankName,
        dailyTarget: dailyTarget,
        priority: priority,
        adoptedAt: adoptedAt));
  }

  @override
  Future<StudyPlanPersistenceStopResult> stopActivePlan(
          {required String expectedPlanId}) async =>
      const StudyPlanPersistenceStopSuccess();
}

ActiveStudyPlan _activePlan() => ActiveStudyPlan(
    planId: 'active-plan',
    bankName: 'Synthetic',
    dailyTarget: 10,
    priority: StudyPlanPriority.balanced,
    adoptedAt: DateTime.utc(2026));
