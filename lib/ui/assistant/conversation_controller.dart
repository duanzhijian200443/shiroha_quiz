import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/agent/agent_config.dart';
import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_turn.dart';
import '../../core/observability/diagnostic_summary.dart';
import '../../application/agent/retrieval_egress_grant.dart';
import '../../application/conversations/conversation_repository.dart';
import '../../application/conversations/conversation_service.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_draft_service.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_draft.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../../domain/content/content_node.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import '../../domain/question/question_draft_v2.dart';

const String conversationReadSafeError = '暂时无法读取对话，请稍后重试';
const String conversationWriteSafeError = '暂时无法保存对话，请稍后重试';

enum AssistantTurnPhase {
  idle,
  thinking,
  searchingWeb,
  usingLocalTool,
  streaming,
  saving,
  failed,
  cancelled,
}

final class ConversationController extends ChangeNotifier {
  ConversationController(
    this.service, {
    required AgentSettingsService agentSettingsService,
    required AgentTurnStarter startAgentTurn,
    AgentRetrievalTurnStarter? startRetrievalTurn,
    AgentWriteProposalService? proposalService,
    StudyPlanDraftService? studyPlanDraftService,
    StudyPlanCommandService? studyPlanCommandService,
  })  : _agentSettingsService = agentSettingsService,
        _startAgentTurn = startAgentTurn,
        _startRetrievalTurn = startRetrievalTurn,
        _proposalService = proposalService,
        _studyPlanDraftService = studyPlanDraftService,
        _studyPlanCommandService = studyPlanCommandService;

  final ConversationService service;
  final AgentSettingsService _agentSettingsService;
  final AgentTurnStarter _startAgentTurn;
  final AgentRetrievalTurnStarter? _startRetrievalTurn;
  final AgentWriteProposalService? _proposalService;
  final StudyPlanDraftService? _studyPlanDraftService;
  final StudyPlanCommandService? _studyPlanCommandService;

  List<Conversation> recent = const <Conversation>[];
  List<ConversationFileRef> attachableFiles = const <ConversationFileRef>[];
  final Map<String, List<Conversation>> projectConversations =
      <String, List<Conversation>>{};
  final Set<String> loadingProjectIds = <String>{};
  final Set<String> draftFileIds = <String>{};
  bool retrievalApprovedForNextTurn = false;

  ConversationThreadSlice? activeThread;
  ConversationScope draftScope = ConversationScope.global();
  bool isLoading = false;
  bool isSending = false;
  bool isLoadingOlder = false;
  bool isRefreshingAttachableFiles = false;
  bool isMovingConversation = false;
  String? errorMessage;
  String? statusMessage;

  AssistantTurnPhase turnPhase = AssistantTurnPhase.idle;
  String transientAssistantText = '';
  AgentTurnFailure? turnFailure;
  String? activeToolName;
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

  AgentTurnSession? _activeSession;
  StreamSubscription<AgentTurnEvent>? _turnEvents;
  String? _retryConversationId;
  String? _retryUserMessageId;
  String? _activeDiagnosticId;
  int _turnEpoch = 0;
  int _threadRevision = 0;
  bool _disposed = false;

  /// OBS-1 safe diagnostic snapshot of the last failed turn; null otherwise.
  /// Never contains message content, tool payloads, RAG passages, provider
  /// bodies, paths or stacks.
  DiagnosticSummary? turnDiagnostic;

  String? get turnDiagnosticId => turnDiagnostic?.diagnosticId;

  String? get diagnosticCopyText => turnDiagnostic == null
      ? null
      : DiagnosticSummaryFormatter.format(turnDiagnostic!);

  /// Passive-dismissal Presentation state: one exact proposal identity per
  /// source User turn, grouped by source Conversation. This remains transient
  /// and permits proposals from different source turns to coexist without
  /// hiding an older pending proposal behind a newer turn.
  final Map<String, Map<String, String>> _proposalIdByTurnByConversation =
      <String, Map<String, String>>{};
  final Map<String, Map<String, String>> _studyPlanDraftIdByTurnByConversation =
      <String, Map<String, String>>{};

  ConversationScope get currentScope =>
      activeThread?.conversation.scope ?? draftScope;

  bool get isDraft => activeThread == null;
  bool get hasActiveTurn => _activeSession != null;
  bool get canRetry =>
      !hasActiveTurn &&
      _retryConversationId != null &&
      _retryUserMessageId != null &&
      activeThread?.conversation.conversationId == _retryConversationId;

  bool get needsAgentSettings =>
      turnFailure == AgentTurnFailure.agentUnconfigured ||
      turnFailure == AgentTurnFailure.profileUnavailable;

  bool get hasProposalCard => proposalId != null && proposalOutcome != null;
  bool get canApproveProposal =>
      proposalOutcome == AgentWriteProposalOutcome.pending &&
      !hasActiveTurn &&
      !proposalActionPending;
  bool get canRejectProposal =>
      proposalOutcome == AgentWriteProposalOutcome.pending &&
      !proposalActionPending;

  bool get hasStudyPlanCard =>
      studyPlanDraftId != null && studyPlanOutcome != null;

  bool get canAdoptStudyPlan =>
      studyPlanOutcome == StudyPlanDraftOutcome.pending &&
      !hasActiveTurn &&
      !studyPlanActionPending;

  bool get canRejectStudyPlan =>
      studyPlanOutcome == StudyPlanDraftOutcome.pending &&
      !studyPlanActionPending;

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

  String? get turnStatusMessage => switch (turnPhase) {
        AssistantTurnPhase.idle => statusMessage,
        AssistantTurnPhase.thinking => 'Shiroha 正在思考…',
        AssistantTurnPhase.searchingWeb => '正在搜索网页…',
        AssistantTurnPhase.usingLocalTool => _toolStatus(activeToolName),
        AssistantTurnPhase.streaming => 'Shiroha 正在回复…',
        AssistantTurnPhase.saving => '正在保存回复…',
        AssistantTurnPhase.failed =>
          turnFailure == null ? '生成失败，请重试' : _agentFailureMessage(turnFailure!),
        AssistantTurnPhase.cancelled => '已停止生成',
      };

  List<ConversationFileRef> get selectedFiles {
    final active = activeThread;
    if (active != null) return active.files;
    final selected = draftFileIds;
    return attachableFiles
        .where((file) => selected.contains(file.fileId))
        .toList(growable: false);
  }

  Future<void> load() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final values = await Future.wait<Object>(<Future<Object>>[
        service.listRecentConversations(),
        service.listAttachableFiles(),
      ]);
      recent = values[0] as List<Conversation>;
      attachableFiles = values[1] as List<ConversationFileRef>;
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> refreshAttachableFiles() async {
    if (isRefreshingAttachableFiles) return false;
    isRefreshingAttachableFiles = true;
    errorMessage = null;
    notifyListeners();
    try {
      attachableFiles = await service.listAttachableFiles();
      return true;
    } catch (_) {
      errorMessage = conversationReadSafeError;
      return false;
    } finally {
      isRefreshingAttachableFiles = false;
      if (!_disposed) notifyListeners();
    }
  }

  void startNew({ConversationScope? scope}) {
    if (hasActiveTurn || isMovingConversation) {
      if (hasActiveTurn) {
        errorMessage = '请先停止当前生成';
        notifyListeners();
      }
      return;
    }
    activeThread = null;
    _threadRevision++;
    draftScope = scope ?? ConversationScope.global();
    draftFileIds.clear();
    retrievalApprovedForNextTurn = false;
    _clearTurnPresentation(clearRetry: true);
    errorMessage = null;
    statusMessage = null;
    notifyListeners();
  }

  void selectDraftScope(ConversationScope scope) {
    if (!isDraft || isMovingConversation) return;
    draftScope = scope;
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> moveActiveConversation(ConversationScope targetScope) async {
    final active = activeThread;
    if (active == null) {
      return false;
    }
    if (hasActiveTurn || isSending) {
      errorMessage = '请先停止当前生成';
      notifyListeners();
      return false;
    }
    if (proposalActionPending ||
        studyPlanActionPending ||
        isMovingConversation) {
      return false;
    }
    if (targetScope.isUnavailableLearningSpace) {
      errorMessage = '目标学习空间不可用';
      notifyListeners();
      return false;
    }

    final targetConversationId = active.conversation.conversationId;
    final oldScope = active.conversation.scope;
    if (oldScope == targetScope) {
      return true;
    }

    isMovingConversation = true;
    errorMessage = null;
    notifyListeners();

    final MoveConversationResult result;
    try {
      result = await service.moveConversation(
        conversationId: targetConversationId,
        targetScope: targetScope,
      );
    } on ConversationException catch (e) {
      isMovingConversation = false;
      errorMessage = switch (e.failure) {
        ConversationFailure.projectNotFound => '目标学习空间已不存在，请刷新后重试',
        ConversationFailure.conversationNotFound => '该对话已不存在',
        ConversationFailure.scopeUnavailable => '目标学习空间不可用',
        ConversationFailure.temporarilyUnavailable => '暂时无法移动对话，请稍后重试',
        _ => conversationWriteSafeError,
      };
      notifyListeners();
      return false;
    } catch (_) {
      isMovingConversation = false;
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }

    if (!result.moved) {
      isMovingConversation = false;
      notifyListeners();
      return true;
    }

    if (activeThread?.conversation.conversationId == targetConversationId) {
      activeThread = ConversationThreadSlice(
        conversation: result.conversation,
        messages: activeThread!.messages,
        files: activeThread!.files,
        hasMoreBefore: activeThread!.hasMoreBefore,
        nextBeforeSequence: activeThread!.nextBeforeSequence,
      );
      _threadRevision++;
    }

    _retryConversationId = null;
    _retryUserMessageId = null;
    retrievalApprovedForNextTurn = false;

    // Phase B — best-effort projection refresh
    try {
      recent = await service.listRecentConversations();

      if (oldScope.kind == ConversationScopeKind.learningSpace &&
          oldScope.projectId != null) {
        if (projectConversations.containsKey(oldScope.projectId)) {
          projectConversations[oldScope.projectId!] =
              await service.listConversationsForProject(
            projectId: oldScope.projectId!,
          );
        }
      }
      if (targetScope.kind == ConversationScopeKind.learningSpace &&
          targetScope.projectId != null) {
        if (projectConversations.containsKey(targetScope.projectId)) {
          projectConversations[targetScope.projectId!] =
              await service.listConversationsForProject(
            projectId: targetScope.projectId!,
          );
        }
      }
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      isMovingConversation = false;
      notifyListeners();
    }

    return true;
  }

  Future<bool> openConversation(String conversationId) async {
    if (hasActiveTurn || isMovingConversation) {
      errorMessage = isMovingConversation ? '请等待对话移动完成' : '请先停止当前生成';
      notifyListeners();
      return false;
    }
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      activeThread = await service.loadConversation(
        conversationId: conversationId,
      );
      _threadRevision++;
      draftFileIds.clear();
      retrievalApprovedForNextTurn = false;
      _clearTurnPresentation(clearRetry: true);
      _restoreProposalBinding(conversationId);
      _restoreStudyPlanDraftBinding(conversationId);
      statusMessage = null;
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeReadError(error.failure);
      return false;
    } catch (_) {
      errorMessage = conversationReadSafeError;
      return false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> send(String content) async {
    if (isSending || hasActiveTurn) {
      errorMessage = _agentFailureMessage(AgentTurnFailure.alreadyRunning);
      notifyListeners();
      return false;
    }
    if (isMovingConversation) {
      errorMessage = '请等待对话移动完成';
      notifyListeners();
      return false;
    }
    isSending = true;
    errorMessage = null;
    statusMessage = null;
    turnFailure = null;
    notifyListeners();

    final configurationFailure = await _loadConfigurationFailure();
    if (configurationFailure != null) {
      _showTurnFailure(configurationFailure);
      isSending = false;
      notifyListeners();
      return false;
    }

    final approvedFileIds = retrievalApprovedForNextTurn
        ? selectedFiles.map((file) => file.fileId).toList(growable: false)
        : const <String>[];
    retrievalApprovedForNextTurn = false;
    late final ConversationMessage target;
    late final String conversationId;
    try {
      final active = activeThread;
      if (active == null) {
        final created = await service.startWithUserMessage(
          scope: draftScope,
          content: content,
          fileIds: draftFileIds,
        );
        activeThread = created;
        conversationId = created.conversation.conversationId;
        target = created.messages.last;
        draftFileIds.clear();
      } else {
        final appended = await service.appendUserMessage(
          conversationId: active.conversation.conversationId,
          content: content,
        );
        conversationId = active.conversation.conversationId;
        target = appended.message;
        activeThread = ConversationThreadSlice(
          conversation: appended.conversation,
          messages: <ConversationMessage>[...active.messages, target],
          files: active.files,
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      }
      _threadRevision++;
    } on ConversationException catch (error) {
      isSending = false;
      errorMessage = _safeWriteError(error.failure);
      notifyListeners();
      return false;
    } catch (_) {
      isSending = false;
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }

    _retryConversationId = conversationId;
    _retryUserMessageId = target.messageId;
    try {
      _beginTurn(
        conversationId: conversationId,
        userMessageId: target.messageId,
        approvedFileIds: approvedFileIds,
      );
    } catch (_) {
      isSending = false;
      _showTurnFailure(AgentTurnFailure.internalError);
    }
    try {
      await _refreshLists();
    } catch (_) {
      errorMessage = conversationReadSafeError;
    }
    notifyListeners();
    return true;
  }

  Future<bool> retryLastTurn() async {
    if (isMovingConversation) {
      return false;
    }
    final conversationId = _retryConversationId;
    final userMessageId = _retryUserMessageId;
    if (!canRetry || conversationId == null || userMessageId == null) {
      return false;
    }
    isSending = true;
    errorMessage = null;
    statusMessage = null;
    transientAssistantText = '';
    turnFailure = null;
    notifyListeners();
    final configurationFailure = await _loadConfigurationFailure();
    if (configurationFailure != null) {
      isSending = false;
      _showTurnFailure(configurationFailure);
      notifyListeners();
      return false;
    }
    try {
      _beginTurn(conversationId: conversationId, userMessageId: userMessageId);
      return true;
    } catch (_) {
      isSending = false;
      _showTurnFailure(AgentTurnFailure.internalError);
      notifyListeners();
      return false;
    }
  }

  void cancelActiveTurn() {
    final session = _activeSession;
    if (session == null) return;
    session.cancel();
    statusMessage = '正在停止生成…';
    notifyListeners();
  }

  void _beginTurn({
    required String conversationId,
    required String userMessageId,
    List<String> approvedFileIds = const <String>[],
  }) {
    final epoch = ++_turnEpoch;
    transientAssistantText = '';
    activeToolName = null;
    _restoreProposalBinding(conversationId);
    _restoreStudyPlanDraftBinding(conversationId);
    turnFailure = null;
    turnPhase = AssistantTurnPhase.thinking;
    final retrievalStarter = _startRetrievalTurn;
    final session = approvedFileIds.isNotEmpty && retrievalStarter != null
        ? retrievalStarter(
            conversationId: conversationId,
            userMessageId: userMessageId,
            approval: RetrievalEgressApproval(approvedFileIds),
          )
        : _startAgentTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          );
    // OBS-1: the diagnostic id is stable from turn creation onward; the
    // Presentation never invents its own id.
    _activeDiagnosticId = session.diagnosticId;
    _activeSession = session;
    _turnEvents = session.events.listen(
      (event) => _projectTurnEvent(event, session, epoch),
      onError: (_) {},
    );
    unawaited(_awaitTurnResult(session, epoch));
    notifyListeners();
  }

  void _projectTurnEvent(
    AgentTurnEvent event,
    AgentTurnSession session,
    int epoch,
  ) {
    if (_activeSession != session || _turnEpoch != epoch || _disposed) return;
    switch (event) {
      case AgentTurnTextDelta(:final text):
        transientAssistantText += text;
        turnPhase = AssistantTurnPhase.streaming;
      case AgentTurnWebSearchEvent(:final isSearching):
        turnPhase = isSearching
            ? AssistantTurnPhase.searchingWeb
            : transientAssistantText.isEmpty
                ? AssistantTurnPhase.thinking
                : AssistantTurnPhase.streaming;
      case AgentTurnToolCall(:final name):
        activeToolName = name;
        turnPhase = AssistantTurnPhase.usingLocalTool;
      case AgentTurnProposalStaged(
          :final proposalId,
          :final outcome,
          :final preview,
        ):
        _projectStagedProposal(
          proposalId: proposalId,
          outcome: _proposalOutcomeOf(outcome),
          preview: preview,
        );
        break;
      case AgentTurnStudyPlanDraftStaged(
          :final draftId,
          :final outcome,
          :final preview,
        ):
        // Unknown staged outcomes fail closed: no card is projected and no
        // actionable adoption state is created.
        final parsedOutcome = _studyPlanOutcomeOf(outcome);
        if (parsedOutcome != null) {
          _projectStagedStudyPlanDraft(
            draftId: draftId,
            outcome: parsedOutcome,
            preview: preview,
          );
        }
        break;
      case AgentTurnCompleted() || AgentTurnFailedEvent():
        return;
    }
    notifyListeners();
  }

  Future<void> _awaitTurnResult(AgentTurnSession session, int epoch) async {
    AgentTurnResult result;
    try {
      result = await session.result;
    } catch (_) {
      result = const AgentTurnFailed(AgentTurnFailure.internalError);
    }
    if (_activeSession != session || _turnEpoch != epoch) return;
    await _turnEvents?.cancel();
    _turnEvents = null;
    _activeSession = null;
    isSending = false;

    switch (result) {
      case AgentTurnSuccess(:final assistantMessage) ||
            AgentTurnAlreadyCompleted(:final assistantMessage):
        turnPhase = AssistantTurnPhase.saving;
        if (!_disposed) notifyListeners();
        _showPersistedAssistant(assistantMessage);
        transientAssistantText = '';
        activeToolName = null;
        turnFailure = null;
        turnPhase = AssistantTurnPhase.idle;
        statusMessage = null;
        try {
          await _refreshLists();
        } catch (_) {
          errorMessage = conversationReadSafeError;
        }
      case AgentTurnFailed(:final failure, :final summary):
        _showTurnFailure(failure, summary: summary);
    }
    if (!_disposed) notifyListeners();
  }

  void _showPersistedAssistant(ConversationMessage message) {
    final active = activeThread;
    if (active == null ||
        active.conversation.conversationId != message.conversationId ||
        active.messages.any(
          (candidate) => candidate.messageId == message.messageId,
        )) {
      return;
    }
    final messages = <ConversationMessage>[...active.messages, message]
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    activeThread = ConversationThreadSlice(
      conversation: active.conversation,
      messages: messages,
      files: active.files,
      hasMoreBefore: active.hasMoreBefore,
      nextBeforeSequence: active.nextBeforeSequence,
    );
    _threadRevision++;
  }

  void _showTurnFailure(AgentTurnFailure failure,
      {DiagnosticSummary? summary}) {
    turnFailure = failure;
    turnPhase = failure == AgentTurnFailure.cancelled
        ? AssistantTurnPhase.cancelled
        : AssistantTurnPhase.failed;
    errorMessage = _agentFailureMessage(failure);
    statusMessage = failure == AgentTurnFailure.cancelled ? '已停止生成' : null;
    final diagnosticId = _activeDiagnosticId;
    turnDiagnostic = summary ??
        (diagnosticId == null
            ? null
            : DiagnosticSummary(
                diagnosticId: diagnosticId,
                operation: 'agent_turn',
                failure: failure.name,
              ));
  }

  Future<AgentTurnFailure?> _loadConfigurationFailure() async {
    try {
      final snapshot = await _agentSettingsService.load();
      return switch (snapshot.state) {
        AgentSettingsState.ready => null,
        AgentSettingsState.unconfigured => AgentTurnFailure.agentUnconfigured,
        AgentSettingsState.profileUnavailable =>
          AgentTurnFailure.profileUnavailable,
      };
    } on AgentConfigException catch (error) {
      return switch (error.failure) {
        AgentConfigFailure.unconfigured ||
        AgentConfigFailure.corruptStoredConfig =>
          AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.profileNotFound ||
        AgentConfigFailure.profileIncomplete =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.temporarilyUnavailable =>
          AgentTurnFailure.temporarilyUnavailable,
        AgentConfigFailure.invalidInput => AgentTurnFailure.internalError,
      };
    } catch (_) {
      return AgentTurnFailure.temporarilyUnavailable;
    }
  }

  Future<void> loadOlderMessages() async {
    final active = activeThread;
    final before = active?.nextBeforeSequence;
    if (active == null || !active.hasMoreBefore || before == null) return;
    final conversationId = active.conversation.conversationId;
    final revision = _threadRevision;
    isLoadingOlder = true;
    errorMessage = null;
    notifyListeners();
    try {
      final older = await service.loadConversation(
        conversationId: conversationId,
        beforeSequence: before,
      );
      final current = activeThread;
      if (current == null ||
          current.conversation.conversationId != conversationId ||
          _threadRevision != revision) {
        return;
      }
      activeThread = ConversationThreadSlice(
        conversation: older.conversation,
        messages: <ConversationMessage>[...older.messages, ...current.messages],
        files: older.files,
        hasMoreBefore: older.hasMoreBefore,
        nextBeforeSequence: older.nextBeforeSequence,
      );
      _threadRevision++;
    } on ConversationException catch (error) {
      errorMessage = _safeReadError(error.failure);
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      isLoadingOlder = false;
      notifyListeners();
    }
  }

  Future<bool> toggleFile(String fileId) async {
    if (isMovingConversation) return false;
    retrievalApprovedForNextTurn = false;
    if (isDraft) {
      if (!draftFileIds.add(fileId)) draftFileIds.remove(fileId);
      errorMessage = null;
      notifyListeners();
      return true;
    }
    final active = activeThread!;
    final exists = active.files.any((file) => file.fileId == fileId);
    try {
      if (exists) {
        final result = await service.detachFile(
          conversationId: active.conversation.conversationId,
          fileId: fileId,
        );
        activeThread = ConversationThreadSlice(
          conversation: result.conversation,
          messages: active.messages,
          files: active.files
              .where((file) => file.fileId != fileId)
              .toList(growable: false),
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      } else {
        final result = await service.attachFile(
          conversationId: active.conversation.conversationId,
          fileId: fileId,
        );
        activeThread = ConversationThreadSlice(
          conversation: result.conversation,
          messages: active.messages,
          files: <ConversationFileRef>[...active.files, result.file],
          hasMoreBefore: active.hasMoreBefore,
          nextBeforeSequence: active.nextBeforeSequence,
        );
      }
      _threadRevision++;
      errorMessage = null;
      await _refreshLists();
      notifyListeners();
      return true;
    } on ConversationException catch (error) {
      errorMessage = _safeWriteError(error.failure);
      notifyListeners();
      return false;
    } catch (_) {
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }
  }

  void setRetrievalApproval(bool approved) {
    retrievalApprovedForNextTurn = approved && selectedFiles.isNotEmpty;
    notifyListeners();
  }

  /// Approves the current proposal. Only the proposal identity leaves the
  /// Presentation layer; the outcome is projected from the Application
  /// service result.
  Future<void> approveProposal() async {
    final service = _proposalService;
    final id = proposalId;
    if (service == null ||
        id == null ||
        proposalOutcome != AgentWriteProposalOutcome.pending ||
        proposalActionPending) {
      return;
    }
    proposalActionPending = true;
    proposalActionMessage = null;
    notifyListeners();
    var shouldNotify = false;
    try {
      final updated = await service.approveProposal(id);
      if (!_disposed && proposalId == id) {
        _setProposal(
          proposalId: updated.id,
          outcome: updated.outcome,
          preview: _previewMapOf(updated.preview),
        );
        _showNextPendingProposalAfter(updated);
        shouldNotify = true;
      }
    } catch (_) {
      if (!_disposed && proposalId == id) {
        proposalActionMessage =
            '\u64cd\u4f5c\u5931\u8d25\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5';
        shouldNotify = true;
      }
    } finally {
      if (!_disposed && proposalId == id) {
        proposalActionPending = false;
        shouldNotify = true;
      }
      if (!_disposed && shouldNotify) {
        notifyListeners();
      }
    }
  }

  /// Rejects the current proposal with zero formal writes.
  void rejectProposal() {
    final service = _proposalService;
    final id = proposalId;
    if (service == null ||
        id == null ||
        proposalOutcome != AgentWriteProposalOutcome.pending ||
        proposalActionPending) {
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

  Future<bool> deleteConversation(String conversationId) async {
    if (hasActiveTurn || isSending) {
      errorMessage = '请先停止当前生成';
      notifyListeners();
      return false;
    }
    if (isMovingConversation) {
      errorMessage = '请等待对话移动完成';
      notifyListeners();
      return false;
    }

    try {
      await service.deleteConversation(conversationId);
    } on ConversationException catch (error) {
      errorMessage = _safeWriteError(error.failure);
      notifyListeners();
      return false;
    } catch (_) {
      errorMessage = conversationWriteSafeError;
      notifyListeners();
      return false;
    }

    _proposalIdByTurnByConversation.remove(conversationId);
    _studyPlanDraftIdByTurnByConversation.remove(conversationId);
    if (_retryConversationId == conversationId) {
      _retryConversationId = null;
      _retryUserMessageId = null;
    }
    if (activeThread?.conversation.conversationId == conversationId) {
      _clearProposal();
      _clearStudyPlanDraft();
      activeThread = null;
      _threadRevision++;
      draftScope = ConversationScope.global();
      draftFileIds.clear();
      retrievalApprovedForNextTurn = false;
    }

    try {
      await _refreshLists();
    } catch (_) {
      errorMessage = conversationReadSafeError;
    }
    notifyListeners();
    return true;
  }

  Future<bool> deleteActiveConversation() async {
    final active = activeThread;
    if (active == null) return false;
    return deleteConversation(active.conversation.conversationId);
  }

  Future<void> loadProjectConversations(String projectId) async {
    if (!loadingProjectIds.add(projectId)) return;
    notifyListeners();
    try {
      projectConversations[projectId] =
          await service.listConversationsForProject(projectId: projectId);
    } catch (_) {
      errorMessage = conversationReadSafeError;
    } finally {
      loadingProjectIds.remove(projectId);
      notifyListeners();
    }
  }

  Future<void> refreshAfterProjectDeleted(String projectId) async {
    projectConversations.remove(projectId);
    final active = activeThread;
    await _refreshLists();
    if (active?.conversation.scope.projectId == projectId) {
      await openConversation(active!.conversation.conversationId);
    }
    notifyListeners();
  }

  Future<void> _refreshLists() async {
    recent = await service.listRecentConversations();
    for (final projectId in projectConversations.keys.toList()) {
      projectConversations[projectId] =
          await service.listConversationsForProject(projectId: projectId);
    }
  }

  void _clearTurnPresentation({required bool clearRetry}) {
    transientAssistantText = '';
    activeToolName = null;
    _clearProposal();
    _clearStudyPlanDraft();
    turnFailure = null;
    turnDiagnostic = null;
    _activeDiagnosticId = null;
    turnPhase = AssistantTurnPhase.idle;
    if (clearRetry) {
      _retryConversationId = null;
      _retryUserMessageId = null;
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
    pendingReplacementActivePlan = null;
    showReplacementConfirmation = false;
  }

  void _setStudyPlanDraft({
    required String draftId,
    required StudyPlanDraftOutcome outcome,
    required Map<String, Object?> preview,
  }) {
    studyPlanDraftId = draftId;
    studyPlanOutcome = outcome;
    studyPlanPreview = Map<String, Object?>.unmodifiable(preview);
    studyPlanActionPending = false;
    studyPlanActionMessage = null;
    showReplacementConfirmation = false;
    pendingReplacementActivePlan = null;
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
        if (current.sourceConversationId ==
                activeThread?.conversation.conversationId &&
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
    if (service == null || byTurn == null || byTurn.isEmpty) {
      _clearStudyPlanDraft();
      return;
    }
    final available = <StudyPlanDraft>[];
    for (final entry in byTurn.entries.toList()) {
      try {
        available.add(service.draftById(entry.value));
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
        studyPlanOutcome != StudyPlanDraftOutcome.pending ||
        studyPlanActionPending) {
      return;
    }
    studyPlanActionPending = true;
    studyPlanActionMessage = null;
    notifyListeners();
    try {
      final activePlan = await cmd.loadActivePlan();
      if (!_disposed && studyPlanDraftId == id) {
        if (activePlan != null) {
          pendingReplacementActivePlan = activePlan;
          showReplacementConfirmation = true;
          studyPlanActionPending = false;
          notifyListeners();
        } else {
          studyPlanActionPending = false;
          await _performAdoptStudyPlan(
            expectedActivePlanId: null,
            replacementConfirmed: false,
          );
        }
      }
    } catch (_) {
      if (!_disposed && studyPlanDraftId == id) {
        studyPlanActionMessage = '操作失败，请稍后重试';
        studyPlanActionPending = false;
        notifyListeners();
      }
    }
  }

  /// Confirms replacement of the existing active plan with this proposal draft.
  Future<void> confirmReplacement() async {
    final expectedId = pendingReplacementActivePlan?.planId;
    showReplacementConfirmation = false;
    pendingReplacementActivePlan = null;
    await _performAdoptStudyPlan(
      expectedActivePlanId: expectedId,
      replacementConfirmed: true,
    );
  }

  /// Cancels replacement confirmation dialog/banner.
  void cancelReplacement() {
    pendingReplacementActivePlan = null;
    showReplacementConfirmation = false;
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
        studyPlanOutcome != StudyPlanDraftOutcome.pending ||
        studyPlanActionPending) {
      return;
    }
    studyPlanActionPending = true;
    studyPlanActionMessage = null;
    notifyListeners();
    var shouldNotify = false;
    try {
      final result = await cmd.adoptDraft(
        draftId: id,
        expectedActivePlanId: expectedActivePlanId,
        replacementConfirmed: replacementConfirmed,
      );
      if (!_disposed && studyPlanDraftId == id) {
        switch (result) {
          case StudyPlanAdoptResultSuccess():
            final updated = draftService.draftById(id);
            _setStudyPlanDraft(
              draftId: updated.draftId,
              outcome: updated.outcome,
              preview: _studyPlanPreviewMapOf(updated.preview),
            );
            _showNextPendingStudyPlanAfter(updated);
            shouldNotify = true;
          case StudyPlanAdoptResultAlreadyActive():
            studyPlanActionMessage = '已有生效中的学习计划，请确认是否替换。';
            shouldNotify = true;
          case StudyPlanAdoptResultStaleActivePlan():
            studyPlanActionMessage = '当前计划状态已变化，请重新确认。';
            shouldNotify = true;
          case StudyPlanAdoptResultStaleScope() ||
                StudyPlanAdoptResultTargetUnavailable() ||
                StudyPlanAdoptResultInvalidPlan() ||
                StudyPlanAdoptResultSuperseded() ||
                StudyPlanAdoptResultRejected() ||
                StudyPlanAdoptResultCommitted() ||
                StudyPlanAdoptResultBusy() ||
                StudyPlanAdoptResultFailed():
            studyPlanActionMessage = '采用计划失败，请稍后重试。';
            shouldNotify = true;
        }
      }
    } catch (_) {
      if (!_disposed && studyPlanDraftId == id) {
        studyPlanActionMessage = '操作失败，请稍后重试。';
        shouldNotify = true;
      }
    } finally {
      if (!_disposed && studyPlanDraftId == id) {
        studyPlanActionPending = false;
        shouldNotify = true;
      }
      if (!_disposed && shouldNotify) {
        notifyListeners();
      }
    }
  }

  /// Rejects the current StudyPlan proposal with zero formal writes.
  void rejectStudyPlan() {
    final draftService = _studyPlanDraftService;
    final id = studyPlanDraftId;
    if (draftService == null ||
        id == null ||
        studyPlanOutcome != StudyPlanDraftOutcome.pending ||
        studyPlanActionPending) {
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
    proposalActionPending = false;
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
        if (current.sourceConversationId ==
                activeThread?.conversation.conversationId &&
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
    if (service == null || byTurn == null || byTurn.isEmpty) {
      _clearProposal();
      return;
    }
    final available = <AgentWriteProposal>[];
    for (final entry in byTurn.entries.toList()) {
      try {
        available.add(service.proposalById(entry.value));
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
    _activeSession?.cancel();
    unawaited(_turnEvents?.cancel());
    super.dispose();
  }

  String _safeReadError(ConversationFailure failure) {
    return switch (failure) {
      ConversationFailure.conversationNotFound => '对话已不存在',
      ConversationFailure.scopeUnavailable => '原学习空间已删除',
      _ => conversationReadSafeError,
    };
  }

  String _safeWriteError(ConversationFailure failure) {
    return switch (failure) {
      ConversationFailure.invalidInput => '消息内容不能为空',
      ConversationFailure.conversationNotFound => '对话已不存在',
      ConversationFailure.projectNotFound => '学习空间已不存在，请重新选择范围',
      ConversationFailure.fileNotFound => '文件已不存在，请刷新后重试',
      ConversationFailure.scopeUnavailable => '原学习空间已删除，请新建对话',
      _ => conversationWriteSafeError,
    };
  }
}

String _agentFailureMessage(AgentTurnFailure failure) {
  return switch (failure) {
    AgentTurnFailure.invalidTarget => '无法确认要回复的消息，请重新打开对话',
    AgentTurnFailure.alreadyRunning => 'Shiroha 正在回复当前对话',
    AgentTurnFailure.conversationUnavailable => '对话已删除，回复未保存',
    AgentTurnFailure.scopeUnavailable => '学习空间已删除，无法保存回复',
    AgentTurnFailure.agentUnconfigured => '请先在“我的”中配置 Shiroha Agent',
    AgentTurnFailure.profileUnavailable => 'Shiroha Agent 的主模型配置不可用',
    AgentTurnFailure.unsupportedModel ||
    AgentTurnFailure.unsupportedCapability =>
      '当前模型暂不支持 Shiroha Agent',
    AgentTurnFailure.authentication => 'API 认证失败，请检查模型配置',
    AgentTurnFailure.rateLimited => '请求过于频繁，请稍后重试',
    AgentTurnFailure.temporarilyUnavailable => '服务暂时不可用，请稍后重试',
    AgentTurnFailure.timeout => '生成超时，请重试',
    AgentTurnFailure.cancelled => '已停止生成',
    AgentTurnFailure.toolLimitExceeded => '学习工具调用达到限制，请简化问题后重试',
    AgentTurnFailure.historyLimitExceeded => '当前消息过长，无法生成回复',
    AgentTurnFailure.providerMalformed => '模型返回异常，请重试',
    AgentTurnFailure.persistenceFailed => '保存回复失败，请重试',
    AgentTurnFailure.internalError => '生成失败，请稍后重试',
  };
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

String _toolStatus(String? toolName) {
  return switch (toolName) {
    'search_questions' => '正在搜索题目…',
    'get_study_overview' || 'get_due_review_summary' => '正在读取学习概览…',
    'list_question_banks' => '正在读取题库…',
    'get_question_detail' => '正在读取题目详情…',
    'get_weak_questions' => '正在查询薄弱题目…',
    _ => '正在查询学习数据…',
  };
}
