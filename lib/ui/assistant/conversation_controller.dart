import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/agent/agent_config.dart';
import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_turn.dart';
import '../../core/observability/diagnostic_summary.dart';
import '../../application/agent/retrieval_egress_grant.dart';
import '../../application/conversations/conversation_repository.dart';
import '../../application/conversations/conversation_service.dart';
import '../../application/modules/module_composition.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
import '../../application/study_plan/study_plan_command_service.dart';
import '../../application/study_plan/study_plan_draft_service.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../../domain/study_plan/study_plan_values.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import 'assistant_artifact_controller.dart';

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
    Iterable<ModuleUiContribution>? artifactContributions,
  })  : _agentSettingsService = agentSettingsService,
        _startAgentTurn = startAgentTurn,
        _startRetrievalTurn = startRetrievalTurn {
    artifacts = AssistantArtifactController(
      proposalService: proposalService,
      studyPlanDraftService: studyPlanDraftService,
      studyPlanCommandService: studyPlanCommandService,
      conversationId: () => activeThread?.conversation.conversationId,
      hasActiveTurn: () => hasActiveTurn,
      isMovingConversation: () => isMovingConversation,
      contributions: artifactContributions,
    )..addListener(_handleArtifactsChanged);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _handleArtifactsChanged() {
    if (!_disposed) notifyListeners();
  }

  final ConversationService service;
  final AgentSettingsService _agentSettingsService;
  final AgentTurnStarter _startAgentTurn;
  final AgentRetrievalTurnStarter? _startRetrievalTurn;

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
  late final AssistantArtifactController artifacts;

  String? get proposalId => artifacts.proposalId;
  set proposalId(String? value) => artifacts.proposalId = value;
  AgentWriteProposalOutcome? get proposalOutcome => artifacts.proposalOutcome;
  set proposalOutcome(AgentWriteProposalOutcome? value) =>
      artifacts.proposalOutcome = value;
  Map<String, Object?> get proposalPreview => artifacts.proposalPreview;
  set proposalPreview(Map<String, Object?> value) =>
      artifacts.proposalPreview = value;
  bool get proposalActionPending => artifacts.proposalActionPending;
  set proposalActionPending(bool value) =>
      artifacts.proposalActionPending = value;
  String? get proposalActionMessage => artifacts.proposalActionMessage;
  set proposalActionMessage(String? value) =>
      artifacts.proposalActionMessage = value;
  String? get studyPlanDraftId => artifacts.studyPlanDraftId;
  set studyPlanDraftId(String? value) => artifacts.studyPlanDraftId = value;
  StudyPlanDraftOutcome? get studyPlanOutcome => artifacts.studyPlanOutcome;
  set studyPlanOutcome(StudyPlanDraftOutcome? value) =>
      artifacts.studyPlanOutcome = value;
  Map<String, Object?> get studyPlanPreview => artifacts.studyPlanPreview;
  set studyPlanPreview(Map<String, Object?> value) =>
      artifacts.studyPlanPreview = value;
  bool get studyPlanActionPending => artifacts.studyPlanActionPending;
  set studyPlanActionPending(bool value) =>
      artifacts.studyPlanActionPending = value;
  String? get studyPlanActionMessage => artifacts.studyPlanActionMessage;
  set studyPlanActionMessage(String? value) =>
      artifacts.studyPlanActionMessage = value;
  ActiveStudyPlan? get pendingReplacementActivePlan =>
      artifacts.pendingReplacementActivePlan;
  set pendingReplacementActivePlan(ActiveStudyPlan? value) =>
      artifacts.pendingReplacementActivePlan = value;
  bool get showReplacementConfirmation => artifacts.showReplacementConfirmation;
  set showReplacementConfirmation(bool value) =>
      artifacts.showReplacementConfirmation = value;

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

  bool get hasProposalCard => artifacts.hasProposalCard;
  bool get canApproveProposal => artifacts.canApproveProposal;
  bool get canRejectProposal => artifacts.canRejectProposal;
  bool get hasStudyPlanCard => artifacts.hasStudyPlanCard;
  bool get canAdoptStudyPlan => artifacts.canAdoptStudyPlan;
  bool get canRejectStudyPlan => artifacts.canRejectStudyPlan;
  String? get studyPlanStatusText => artifacts.studyPlanStatusText;
  String? get proposalStatusText => artifacts.proposalStatusText;

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
      artifacts.restoreConversation(conversationId);
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
    artifacts.restoreConversation(conversationId);
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
      (event) => _projectTurnEvent(
          event, session, epoch, conversationId, userMessageId),
      onError: (_) {},
    );
    unawaited(_awaitTurnResult(session, epoch));
    notifyListeners();
  }

  void _projectTurnEvent(
    AgentTurnEvent event,
    AgentTurnSession session,
    int epoch,
    String conversationId,
    String userMessageId,
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
      case AgentTurnProposalStaged() || AgentTurnStudyPlanDraftStaged():
        artifacts.projectTurnArtifact(event,
            conversationId: conversationId, userMessageId: userMessageId);
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
    final candidate = summary ??
        (diagnosticId == null
            ? null
            : DiagnosticSummary(
                diagnosticId: diagnosticId,
                operation: 'agent_turn',
                failure: failure.name,
              ));
    // OBS-1: only a strictly valid correlation id may surface the diagnostic
    // number and the copy affordance.
    turnDiagnostic = candidate != null &&
            DiagnosticSummaryFormatter.isValidDiagnosticId(
              candidate.diagnosticId,
            )
        ? candidate
        : null;
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

  Future<void> approveProposal() => artifacts.approveProposal();
  void rejectProposal() => artifacts.rejectProposal();
  Future<void> initiateAdoptStudyPlan() => artifacts.initiateAdoptStudyPlan();
  Future<void> confirmReplacement() => artifacts.confirmReplacement();
  void cancelReplacement() => artifacts.cancelReplacement();
  void rejectStudyPlan() => artifacts.rejectStudyPlan();

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

    artifacts.forgetConversation(conversationId);
    if (_retryConversationId == conversationId) {
      _retryConversationId = null;
      _retryUserMessageId = null;
    }
    if (activeThread?.conversation.conversationId == conversationId) {
      artifacts.clearPresentation();
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
    artifacts.clearPresentation();
    turnFailure = null;
    turnDiagnostic = null;
    _activeDiagnosticId = null;
    turnPhase = AssistantTurnPhase.idle;
    if (clearRetry) {
      _retryConversationId = null;
      _retryUserMessageId = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    artifacts.removeListener(_handleArtifactsChanged);
    artifacts.dispose();
    _turnEpoch++;
    _activeSession?.cancel();
    _activeSession = null;
    unawaited(_turnEvents?.cancel());
    _turnEvents = null;
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
