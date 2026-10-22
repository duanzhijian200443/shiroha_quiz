import 'package:flutter/foundation.dart';

import '../../application/agent/agent_turn.dart';
import '../../application/modules/assistant_artifact_contributions.dart';
import '../../application/modules/module_composition.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_draft_service.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../../domain/content/content_node.dart';
import '../../domain/question/question_draft_v2.dart';

/// Sole owner of transient Assistant artifact presentation and source bindings.
/// Application services retain all proposal/draft transitions and formal writes.
/// The workspace-owned ConversationController forwards its compatibility API here.
final class AssistantArtifactController extends ChangeNotifier {
  AssistantArtifactController({
    AgentWriteProposalService? proposalService,
    StudyPlanDraftService? studyPlanDraftService,
    StudyPlanCommandService? studyPlanCommandService,
    required String? Function() conversationId,
    required bool Function() hasActiveTurn,
    required bool Function() isMovingConversation,
    Iterable<ModuleUiContribution>? contributions,
  })  : _proposalService = proposalService,
        _studyPlanDraftService = studyPlanDraftService,
        _studyPlanCommandService = studyPlanCommandService,
        _conversationId = conversationId,
        _hasActiveTurn = hasActiveTurn,
        _isMovingConversation = isMovingConversation,
        contributions = List.unmodifiable(
            contributions ?? retainedAssistantArtifactContributions);

  final AgentWriteProposalService? _proposalService;
  final StudyPlanDraftService? _studyPlanDraftService;
  final StudyPlanCommandService? _studyPlanCommandService;
  final String? Function() _conversationId;
  final bool Function() _hasActiveTurn;
  final bool Function() _isMovingConversation;
  final List<ModuleUiContribution> contributions;
  bool _disposed = false;
  int _presentationEpoch = 0;
  final Set<String> _proposalOperations = {};
  final Set<String> _studyPlanOperations = {};
  String? _replacementDraftId;
  int? _replacementEpoch;
  Object? _replacementToken;

  /// Captures the displayed identity, including an away-and-back navigation.
  /// A retained callback may never act on a later card at the same slot.
  VoidCallback bindProposalAction(VoidCallback action) {
    final id = proposalId;
    final epoch = _presentationEpoch;
    return () {
      if (id != null && _currentProposal(id, epoch)) action();
    };
  }

  VoidCallback bindStudyPlanAction(VoidCallback action) {
    final id = studyPlanDraftId;
    final epoch = _presentationEpoch;
    return () {
      if (id != null && _currentStudyPlan(id, epoch)) action();
    };
  }

  VoidCallback bindReplacementAction(VoidCallback action) {
    final token = _replacementToken;
    final bound = bindStudyPlanAction(action);
    return () {
      if (token != null && identical(token, _replacementToken)) bound();
    };
  }

  bool _currentProposal(String id, int epoch) =>
      !_disposed && _presentationEpoch == epoch && proposalId == id;
  bool _currentStudyPlan(String id, int epoch) =>
      !_disposed && _presentationEpoch == epoch && studyPlanDraftId == id;

  bool _proposalSourceCurrent(String id) {
    try {
      return _proposalService?.proposalById(id).sourceConversationId ==
              _conversationId() &&
          _conversationId() != null;
    } catch (_) {
      return false;
    }
  }

  bool _studyPlanSourceCurrent(String id) {
    try {
      return _studyPlanDraftService?.draftById(id).sourceConversationId ==
              _conversationId() &&
          _conversationId() != null;
    } catch (_) {
      return false;
    }
  }

  void _clearReplacement() {
    _replacementDraftId = null;
    _replacementEpoch = null;
    _replacementToken = null;
    pendingReplacementActivePlan = null;
    showReplacementConfirmation = false;
  }

  void _settleProposal(String id, int epoch) {
    _proposalOperations.remove(id);
    if (_disposed || proposalId != id) return;
    if (_presentationEpoch != epoch) {
      final conversationId = _conversationId();
      if (conversationId != null) _restoreProposalBinding(conversationId);
    } else {
      proposalActionPending = false;
    }
    notifyListeners();
  }

  void _settleStudyPlan(String id, int epoch) {
    _studyPlanOperations.remove(id);
    if (_disposed || studyPlanDraftId != id) return;
    if (_presentationEpoch != epoch) {
      final conversationId = _conversationId();
      if (conversationId != null) _restoreStudyPlanDraftBinding(conversationId);
    } else {
      studyPlanActionPending = false;
    }
    notifyListeners();
  }

  bool presents(String key) => contributions.any(
      (item) => item.slot == ModuleUiSlot.assistantArtifact && item.key == key);

  // Lifecycle hooks are batched with the owning conversation notification.
  void clearPresentation() {
    _presentationEpoch++;
    _clearProposal();
    _clearStudyPlanDraft();
  }

  void restoreConversation(String conversationId) {
    _restoreProposalBinding(conversationId);
    _restoreStudyPlanDraftBinding(conversationId);
  }

  void forgetConversation(String conversationId) {
    _proposalIdByTurnByConversation.remove(conversationId);
    _studyPlanDraftIdByTurnByConversation.remove(conversationId);
  }

  void projectTurnArtifact(
    AgentTurnEvent event, {
    required String conversationId,
    required String userMessageId,
  }) {
    if (_disposed || _conversationId() != conversationId) return;
    switch (event) {
      case AgentTurnProposalStaged(
          :final proposalId,
          :final outcome,
          :final preview
        ):
        if (!presents(missingAnswerArtifactUi.key)) return;
        final service = _proposalService;
        if (service != null) {
          try {
            final proposal = service.proposalById(proposalId);
            if (proposal.sourceConversationId != conversationId ||
                proposal.sourceMessageId != userMessageId) {
              return;
            }
          } catch (_) {
            return;
          }
        }
        _projectStagedProposal(
            proposalId: proposalId,
            outcome: _proposalOutcomeOf(outcome),
            preview: preview);
      case AgentTurnStudyPlanDraftStaged(
          :final draftId,
          :final outcome,
          :final preview
        ):
        if (!presents(studyPlanArtifactUi.key)) return;
        final parsed = _studyPlanOutcomeOf(outcome);
        if (parsed == null) return;
        final service = _studyPlanDraftService;
        if (service != null) {
          try {
            final draft = service.draftById(draftId);
            if (draft.sourceConversationId != conversationId ||
                draft.sourceMessageId != userMessageId) {
              return;
            }
          } catch (_) {
            return;
          }
        }
        _projectStagedStudyPlanDraft(
            draftId: draftId, outcome: parsed, preview: preview);
      default:
        return;
    }
  }

  String? proposalId;
  AgentWriteProposalOutcome? proposalOutcome;
  Map<String, Object?> proposalPreview = const <String, Object?>{};
  bool proposalActionPending = false;
  String? proposalActionMessage;

  String? studyPlanDraftId;
  StudyPlanDraftOutcome? studyPlanOutcome;
  Map<String, Object?> studyPlanPreview = const <String, Object?>{};
  bool studyPlanActionPending = false;
  String? studyPlanActionMessage;
  ActiveStudyPlan? pendingReplacementActivePlan;
  bool showReplacementConfirmation = false;

  /// Passive-dismissal Presentation state: one exact proposal identity per
  /// source User turn, grouped by source Conversation. This remains transient
  /// and permits proposals from different source turns to coexist without
  /// hiding an older pending proposal behind a newer turn.
  final Map<String, Map<String, String>> _proposalIdByTurnByConversation =
      <String, Map<String, String>>{};
  final Map<String, Map<String, String>> _studyPlanDraftIdByTurnByConversation =
      <String, Map<String, String>>{};

  bool get hasProposalCard => proposalId != null && proposalOutcome != null;
  bool get canApproveProposal =>
      !_disposed &&
      presents(missingAnswerArtifactUi.key) &&
      proposalOutcome == AgentWriteProposalOutcome.pending &&
      !_hasActiveTurn() &&
      !proposalActionPending &&
      !_isMovingConversation();
  bool get canRejectProposal =>
      !_disposed &&
      presents(missingAnswerArtifactUi.key) &&
      proposalOutcome == AgentWriteProposalOutcome.pending &&
      !proposalActionPending &&
      !_isMovingConversation();

  bool get hasStudyPlanCard =>
      studyPlanDraftId != null && studyPlanOutcome != null;

  bool get canAdoptStudyPlan =>
      !_disposed &&
      presents(studyPlanArtifactUi.key) &&
      studyPlanOutcome == StudyPlanDraftOutcome.pending &&
      !_hasActiveTurn() &&
      !studyPlanActionPending &&
      !_isMovingConversation();

  bool get canRejectStudyPlan =>
      !_disposed &&
      presents(studyPlanArtifactUi.key) &&
      studyPlanOutcome == StudyPlanDraftOutcome.pending &&
      !studyPlanActionPending &&
      !_isMovingConversation();

  String? get studyPlanStatusText => switch (studyPlanOutcome) {
        null => null,
        StudyPlanDraftOutcome.pending => null,
        StudyPlanDraftOutcome.committing => '正在采用计划…',
        StudyPlanDraftOutcome.committed => '已采用该计划',
        StudyPlanDraftOutcome.rejected => '已不采用该计划',
        StudyPlanDraftOutcome.superseded => '该计划草案已被新方案替代',
      };

  /// Fixed safe user-facing text for the proposal lifecycle outcome.
  String? get proposalStatusText => switch (proposalOutcome) {
        null => null,
        AgentWriteProposalOutcome.pending => null,
        AgentWriteProposalOutcome.committing =>
          '\u6b63\u5728\u5199\u5165\u2026',
        AgentWriteProposalOutcome.committed => '\u5df2\u5199\u5165\u7b54\u6848',
        AgentWriteProposalOutcome.rejected =>
          '\u5df2\u62d2\u7edd\u8be5\u63d0\u6848',
        AgentWriteProposalOutcome.superseded =>
          '\u8be5\u63d0\u6848\u5df2\u88ab\u65b0\u63d0\u6848\u66ff\u4ee3',
        AgentWriteProposalOutcome.stale =>
          '\u9898\u76ee\u5df2\u53d8\u5316\uff0c\u63d0\u6848\u5df2\u5931\u6548',
        AgentWriteProposalOutcome.invalid => '\u8be5\u63d0\u6848\u65e0\u6548',
        AgentWriteProposalOutcome.unknownOutcome =>
          '\u5199\u5165\u7ed3\u679c\u6682\u65e0\u6cd5\u786e\u8ba4\uff0c'
              '\u8bf7\u5237\u65b0\u540e\u67e5\u770b',
      };

  /// Approves the current proposal. Only the proposal identity leaves the
  /// Presentation layer; the outcome is projected from the Application
  /// service result.
  Future<void> approveProposal() async {
    final service = _proposalService;
    final id = proposalId;
    if (service == null ||
        id == null ||
        !canApproveProposal ||
        !_proposalSourceCurrent(id) ||
        !_proposalOperations.add(id)) {
      return;
    }
    final epoch = _presentationEpoch;
    proposalActionPending = true;
    proposalActionMessage = null;
    notifyListeners();
    try {
      final updated = await service.approveProposal(id);
      if (_currentProposal(id, epoch)) {
        _setProposal(
          proposalId: updated.id,
          outcome: updated.outcome,
          preview: _previewMapOf(updated.preview),
        );
        _showNextPendingProposalAfter(updated);
        if (proposalId != id) notifyListeners();
      }
    } catch (_) {
      if (_currentProposal(id, epoch)) {
        proposalActionMessage =
            '\u64cd\u4f5c\u5931\u8d25\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5';
      }
    } finally {
      _settleProposal(id, epoch);
    }
  }

  /// Rejects the current proposal with zero formal writes.
  void rejectProposal() {
    final service = _proposalService;
    final id = proposalId;
    if (service == null ||
        id == null ||
        !canRejectProposal ||
        !_proposalSourceCurrent(id) ||
        _proposalOperations.contains(id)) {
      return;
    }
    proposalActionPending = true;
    proposalActionMessage = null;
    notifyListeners();
    try {
      final updated = service.rejectProposal(id);
      _setProposal(
        proposalId: updated.id,
        outcome: updated.outcome,
        preview: _previewMapOf(updated.preview),
      );
      _showNextPendingProposalAfter(updated);
    } catch (_) {
      proposalActionMessage =
          '\u64cd\u4f5c\u5931\u8d25\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5';
    } finally {
      proposalActionPending = false;
      notifyListeners();
    }
  }

  void _clearProposal() {
    proposalId = null;
    proposalOutcome = null;
    proposalPreview = const <String, Object?>{};
    proposalActionPending = false;
    proposalActionMessage = null;
  }

  void _clearStudyPlanDraft() {
    studyPlanDraftId = null;
    studyPlanOutcome = null;
    studyPlanPreview = const <String, Object?>{};
    studyPlanActionPending = false;
    studyPlanActionMessage = null;
    _clearReplacement();
  }

  void _setStudyPlanDraft({
    required String draftId,
    required StudyPlanDraftOutcome outcome,
    required Map<String, Object?> preview,
  }) {
    studyPlanDraftId = draftId;
    studyPlanOutcome = outcome;
    studyPlanPreview = Map<String, Object?>.unmodifiable(preview);
    studyPlanActionPending = _studyPlanOperations.contains(draftId);
    studyPlanActionMessage = null;
    _clearReplacement();
    _bindStudyPlanDraftIdentity(draftId);
  }

  void _projectStagedStudyPlanDraft({
    required String draftId,
    required StudyPlanDraftOutcome outcome,
    required Map<String, Object?> preview,
  }) {
    _bindStudyPlanDraftIdentity(draftId);
    final currentId = studyPlanDraftId;
    final service = _studyPlanDraftService;
    if (currentId != null && service != null) {
      try {
        final current = service.draftById(currentId);
        if (current.sourceConversationId == _conversationId() &&
            current.outcome == StudyPlanDraftOutcome.pending) {
          return;
        }
      } catch (_) {}
    }
    _setStudyPlanDraft(
      draftId: draftId,
      outcome: outcome,
      preview: preview,
    );
  }

  void _bindStudyPlanDraftIdentity(String draftId) {
    final service = _studyPlanDraftService;
    if (service == null) return;
    try {
      final draft = service.draftById(draftId);
      final byTurn = _studyPlanDraftIdByTurnByConversation.putIfAbsent(
        draft.sourceConversationId,
        () => <String, String>{},
      );
      final boundId = byTurn[draft.sourceMessageId];
      if (boundId != null && boundId != draft.draftId) {
        try {
          final bound = service.draftById(boundId);
          if (bound.outcome == StudyPlanDraftOutcome.pending) {
            return;
          }
        } catch (_) {}
      }
      byTurn[draft.sourceMessageId] = draft.draftId;
    } catch (_) {}
  }

  void _restoreStudyPlanDraftBinding(String conversationId) {
    final service = _studyPlanDraftService;
    final byTurn = _studyPlanDraftIdByTurnByConversation[conversationId];
    if (!presents(studyPlanArtifactUi.key) ||
        service == null ||
        byTurn == null ||
        byTurn.isEmpty) {
      _clearStudyPlanDraft();
      return;
    }
    final available = <StudyPlanDraft>[];
    for (final entry in byTurn.entries.toList()) {
      try {
        final draft = service.draftById(entry.value);
        if (draft.sourceConversationId != conversationId ||
            draft.sourceMessageId != entry.key) {
          byTurn.remove(entry.key);
        } else {
          available.add(draft);
        }
      } catch (_) {
        byTurn.remove(entry.key);
      }
    }
    if (available.isEmpty) {
      _studyPlanDraftIdByTurnByConversation.remove(conversationId);
      _clearStudyPlanDraft();
      return;
    }
    final draft = available.firstWhere(
      (candidate) => candidate.outcome == StudyPlanDraftOutcome.pending,
      orElse: () => available.last,
    );
    _setStudyPlanDraft(
      draftId: draft.draftId,
      outcome: draft.outcome,
      preview: _studyPlanPreviewMapOf(draft.preview),
    );
  }

  void _showNextPendingStudyPlanAfter(StudyPlanDraft current) {
    if (current.outcome == StudyPlanDraftOutcome.pending ||
        current.outcome == StudyPlanDraftOutcome.committing) {
      return;
    }
    final service = _studyPlanDraftService;
    final byTurn =
        _studyPlanDraftIdByTurnByConversation[current.sourceConversationId];
    if (service == null || byTurn == null) return;
    for (final draftId in byTurn.values) {
      if (draftId == current.draftId) continue;
      try {
        final draft = service.draftById(draftId);
        if (draft.outcome == StudyPlanDraftOutcome.pending) {
          _setStudyPlanDraft(
            draftId: draft.draftId,
            outcome: draft.outcome,
            preview: _studyPlanPreviewMapOf(draft.preview),
          );
          return;
        }
      } catch (_) {}
    }
  }

  StudyPlanDraftOutcome? _studyPlanOutcomeOf(String value) {
    return switch (value) {
      'pending' => StudyPlanDraftOutcome.pending,
      'committing' => StudyPlanDraftOutcome.committing,
      'committed' => StudyPlanDraftOutcome.committed,
      'rejected' => StudyPlanDraftOutcome.rejected,
      'superseded' => StudyPlanDraftOutcome.superseded,
      _ => null,
    };
  }

  Map<String, Object?> _studyPlanPreviewMapOf(StudyPlanPreview preview) {
    return <String, Object?>{
      'bank_name': preview.bankName,
      if (preview.goal != null) 'goal': preview.goal,
      'daily_target': preview.dailyTarget,
      'priority': preview.priority.canonicalCode,
      if (preview.horizonDays != null) 'horizon_days': preview.horizonDays,
      'question_count': preview.questionCount,
      'mastered_count': preview.masteredCount,
      'due_count': preview.dueCount,
      'weak_count': preview.weakCount,
      'new_count': preview.newCount,
      'estimated_days': preview.estimatedDays,
    };
  }

  /// Initiates adoption of the current StudyPlan proposal.
  /// If an ActiveStudyPlan already exists, prompts for replacement confirmation.
  Future<void> initiateAdoptStudyPlan() async {
    final cmd = _studyPlanCommandService;
    final id = studyPlanDraftId;
    if (cmd == null ||
        id == null ||
        !canAdoptStudyPlan ||
        !_studyPlanSourceCurrent(id) ||
        !_studyPlanOperations.add(id)) {
      return;
    }
    final epoch = _presentationEpoch;
    studyPlanActionPending = true;
    studyPlanActionMessage = null;
    _clearReplacement();
    notifyListeners();
    var adoptWithoutReplacement = false;
    try {
      final activePlan = await cmd.loadActivePlan();
      if (_currentStudyPlan(id, epoch)) {
        if (activePlan != null) {
          pendingReplacementActivePlan = activePlan;
          showReplacementConfirmation = true;
          _replacementDraftId = id;
          _replacementEpoch = epoch;
          _replacementToken = Object();
        } else {
          adoptWithoutReplacement = true;
        }
      }
    } catch (_) {
      if (_currentStudyPlan(id, epoch)) {
        studyPlanActionMessage = '操作失败，请稍后重试';
      }
    } finally {
      _settleStudyPlan(id, epoch);
    }
    if (adoptWithoutReplacement && _currentStudyPlan(id, epoch)) {
      await _performAdoptStudyPlan(
          expectedActivePlanId: null, replacementConfirmed: false);
    }
  }

  /// Confirms only the draft and active plan observed in this presentation.
  Future<void> confirmReplacement() async {
    final id = _replacementDraftId;
    final epoch = _replacementEpoch;
    if (id == null ||
        epoch == null ||
        !_currentStudyPlan(id, epoch) ||
        !showReplacementConfirmation ||
        pendingReplacementActivePlan == null ||
        !canAdoptStudyPlan) {
      return;
    }
    final expectedId = pendingReplacementActivePlan!.planId;
    _clearReplacement();
    await _performAdoptStudyPlan(
        expectedActivePlanId: expectedId, replacementConfirmed: true);
  }

  void cancelReplacement() {
    if (_disposed) return;
    _clearReplacement();
    notifyListeners();
  }

  Future<void> _performAdoptStudyPlan({
    String? expectedActivePlanId,
    required bool replacementConfirmed,
  }) async {
    final cmd = _studyPlanCommandService;
    final draftService = _studyPlanDraftService;
    final id = studyPlanDraftId;
    if (cmd == null ||
        draftService == null ||
        id == null ||
        !canAdoptStudyPlan ||
        !_studyPlanSourceCurrent(id) ||
        !_studyPlanOperations.add(id)) {
      return;
    }
    final epoch = _presentationEpoch;
    studyPlanActionPending = true;
    studyPlanActionMessage = null;
    notifyListeners();
    try {
      final result = await cmd.adoptDraft(
        draftId: id,
        expectedActivePlanId: expectedActivePlanId,
        replacementConfirmed: replacementConfirmed,
      );
      if (_currentStudyPlan(id, epoch)) {
        switch (result) {
          case StudyPlanAdoptResultSuccess():
            final updated = draftService.draftById(id);
            _setStudyPlanDraft(
              draftId: updated.draftId,
              outcome: updated.outcome,
              preview: _studyPlanPreviewMapOf(updated.preview),
            );
            _showNextPendingStudyPlanAfter(updated);
            if (studyPlanDraftId != id) notifyListeners();
          case StudyPlanAdoptResultAlreadyActive():
            studyPlanActionMessage = '已有生效中的学习计划，请确认是否替换。';
          case StudyPlanAdoptResultStaleActivePlan():
            studyPlanActionMessage = '当前计划状态已变化，请重新确认。';
          case StudyPlanAdoptResultStaleScope() ||
                StudyPlanAdoptResultTargetUnavailable() ||
                StudyPlanAdoptResultInvalidPlan() ||
                StudyPlanAdoptResultSuperseded() ||
                StudyPlanAdoptResultRejected() ||
                StudyPlanAdoptResultCommitted() ||
                StudyPlanAdoptResultBusy() ||
                StudyPlanAdoptResultFailed():
            studyPlanActionMessage = '采用计划失败，请稍后重试。';
        }
      }
    } catch (_) {
      if (_currentStudyPlan(id, epoch)) {
        studyPlanActionMessage = '操作失败，请稍后重试。';
      }
    } finally {
      _settleStudyPlan(id, epoch);
    }
  }

  /// Rejects the current StudyPlan proposal with zero formal writes.
  void rejectStudyPlan() {
    final draftService = _studyPlanDraftService;
    final id = studyPlanDraftId;
    if (draftService == null ||
        id == null ||
        !canRejectStudyPlan ||
        !_studyPlanSourceCurrent(id) ||
        _studyPlanOperations.contains(id)) {
      return;
    }
    studyPlanActionPending = true;
    studyPlanActionMessage = null;
    notifyListeners();
    try {
      final updated = draftService.rejectDraft(id);
      _setStudyPlanDraft(
        draftId: updated.draftId,
        outcome: updated.outcome,
        preview: _studyPlanPreviewMapOf(updated.preview),
      );
      _showNextPendingStudyPlanAfter(updated);
    } catch (_) {
      studyPlanActionMessage = '操作失败，请稍后重试。';
    } finally {
      studyPlanActionPending = false;
      notifyListeners();
    }
  }

  void _setProposal({
    required String proposalId,
    required AgentWriteProposalOutcome outcome,
    required Map<String, Object?> preview,
  }) {
    this.proposalId = proposalId;
    proposalOutcome = outcome;
    proposalPreview = Map<String, Object?>.unmodifiable(preview);
    proposalActionPending = _proposalOperations.contains(proposalId);
    proposalActionMessage = null;
    _bindProposalIdentity(proposalId);
  }

  void _projectStagedProposal({
    required String proposalId,
    required AgentWriteProposalOutcome outcome,
    required Map<String, Object?> preview,
  }) {
    _bindProposalIdentity(proposalId);
    final currentId = this.proposalId;
    final service = _proposalService;
    if (currentId != null && service != null) {
      try {
        final current = service.proposalById(currentId);
        if (current.sourceConversationId == _conversationId() &&
            current.outcome == AgentWriteProposalOutcome.pending) {
          return;
        }
      } catch (_) {
        // Fall through and project the newly staged proposal.
      }
    }
    _setProposal(
      proposalId: proposalId,
      outcome: outcome,
      preview: preview,
    );
  }

  void _bindProposalIdentity(String proposalId) {
    final service = _proposalService;
    if (service == null) return;
    try {
      final proposal = service.proposalById(proposalId);
      final byTurn = _proposalIdByTurnByConversation.putIfAbsent(
        proposal.sourceConversationId,
        () => <String, String>{},
      );
      final boundId = byTurn[proposal.sourceMessageId];
      if (boundId != null && boundId != proposal.id) {
        try {
          final bound = service.proposalById(boundId);
          if (bound.outcome == AgentWriteProposalOutcome.pending) {
            return;
          }
        } catch (_) {
          // A missing transient binding may be replaced by the known proposal.
        }
      }
      byTurn[proposal.sourceMessageId] = proposal.id;
    } catch (_) {
      // Unknown transient identities cannot be restored and are not retained.
    }
  }

  /// Passive-dismissal restoration: re-reads the current Application
  /// proposal outcome/preview for the exact identity previously projected
  /// for [conversationId]. Reject/superseded/stale/committed outcomes restore
  /// accurately when previously bound; an unknown identity (for example a
  /// fresh in-memory service after a process restart) restores nothing.
  /// Switching itself never approves, rejects or commits a proposal.
  void _restoreProposalBinding(String conversationId) {
    final service = _proposalService;
    final byTurn = _proposalIdByTurnByConversation[conversationId];
    if (!presents(missingAnswerArtifactUi.key) ||
        service == null ||
        byTurn == null ||
        byTurn.isEmpty) {
      _clearProposal();
      return;
    }
    final available = <AgentWriteProposal>[];
    for (final entry in byTurn.entries.toList()) {
      try {
        final proposal = service.proposalById(entry.value);
        if (proposal.sourceConversationId != conversationId ||
            proposal.sourceMessageId != entry.key) {
          byTurn.remove(entry.key);
        } else {
          available.add(proposal);
        }
      } catch (_) {
        byTurn.remove(entry.key);
      }
    }
    if (available.isEmpty) {
      _proposalIdByTurnByConversation.remove(conversationId);
      _clearProposal();
      return;
    }
    final proposal = available.firstWhere(
      (candidate) => candidate.outcome == AgentWriteProposalOutcome.pending,
      orElse: () => available.last,
    );
    _setProposal(
      proposalId: proposal.id,
      outcome: proposal.outcome,
      preview: _previewMapOf(proposal.preview),
    );
  }

  void _showNextPendingProposalAfter(AgentWriteProposal current) {
    if (current.outcome == AgentWriteProposalOutcome.pending ||
        current.outcome == AgentWriteProposalOutcome.committing) {
      return;
    }
    final service = _proposalService;
    final byTurn =
        _proposalIdByTurnByConversation[current.sourceConversationId];
    if (service == null || byTurn == null) return;
    for (final proposalId in byTurn.values) {
      if (proposalId == current.id) continue;
      try {
        final proposal = service.proposalById(proposalId);
        if (proposal.outcome == AgentWriteProposalOutcome.pending) {
          _setProposal(
            proposalId: proposal.id,
            outcome: proposal.outcome,
            preview: _previewMapOf(proposal.preview),
          );
          return;
        }
      } catch (_) {
        // Missing transient identities are pruned on the next restoration.
      }
    }
  }

  /// Maps the stable tool-contract outcome string onto the application
  /// outcome. Unknown strings fail safe as invalid.
  AgentWriteProposalOutcome _proposalOutcomeOf(String value) {
    return switch (value) {
      'pending' => AgentWriteProposalOutcome.pending,
      'committing' => AgentWriteProposalOutcome.committing,
      'committed' => AgentWriteProposalOutcome.committed,
      'rejected' => AgentWriteProposalOutcome.rejected,
      'superseded' => AgentWriteProposalOutcome.superseded,
      'stale' => AgentWriteProposalOutcome.stale,
      'invalid' => AgentWriteProposalOutcome.invalid,
      'unknown_outcome' => AgentWriteProposalOutcome.unknownOutcome,
      _ => AgentWriteProposalOutcome.invalid,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _presentationEpoch++;
    super.dispose();
  }
}

/// Projects the Application-owned preview back onto the structured tool
/// contract shape consumed by the proposal card (`bank_name`/stem/options/
/// proposed_answer). Used only for passive-dismissal restoration.
Map<String, Object?> _previewMapOf(AgentWriteProposalPreview preview) {
  return <String, Object?>{
    'bank_name': preview.bankName,
    'stem': <Map<String, Object?>>[
      for (final node in preview.stem.nodes) _previewNodeOf(node),
    ],
    'options': <Map<String, Object?>>[
      for (final option in preview.options)
        <String, Object?>{
          'label': option.label,
          'content': <Map<String, Object?>>[
            for (final node in option.content.nodes) _previewNodeOf(node),
          ],
        },
    ],
    'proposed_answer': _previewAnswerOf(
      preview.proposedAnswer,
      preview.options,
    ),
  };
}

Map<String, Object?> _previewNodeOf(ContentNode node) {
  return switch (node) {
    TextNode(:final text) => <String, Object?>{'type': 'text', 'text': text},
    InlineMathNode(:final latex) => <String, Object?>{
        'type': 'inline_math',
        'latex': latex,
      },
    BlockMathNode(:final latex) => <String, Object?>{
        'type': 'block_math',
        'latex': latex,
      },
    ImageNode() || TableNode() => <String, Object?>{'type': 'unsupported'},
    RawFallbackNode() => <String, Object?>{'type': 'unsupported'},
  };
}

Map<String, Object?> _previewAnswerOf(
  QuestionAnswer answer,
  List<QuestionOption> options,
) {
  return switch (answer) {
    ChoiceAnswer(:final optionIds) => <String, Object?>{
        'kind': 'choice',
        'labels': <String>[
          for (final optionId in optionIds) _previewLabelOf(optionId, options),
        ],
      },
    ContentAnswer(:final content) => <String, Object?>{
        'kind': 'content',
        'nodes': <Map<String, Object?>>[
          for (final node in content.nodes) _previewNodeOf(node),
        ],
      },
  };
}

String _previewLabelOf(String optionId, List<QuestionOption> options) {
  for (final option in options) {
    if (option.optionId == optionId) return option.label;
  }
  return optionId;
}
