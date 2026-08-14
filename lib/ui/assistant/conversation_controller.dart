import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/agent/agent_config.dart';
import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_turn.dart';
import '../../application/agent/retrieval_egress_grant.dart';
import '../../application/conversations/conversation_repository.dart';
import '../../application/conversations/conversation_service.dart';
import '../../application/safe_write/agent_write_proposal.dart';
import '../../application/safe_write/agent_write_proposal_service.dart';
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
  })  : _agentSettingsService = agentSettingsService,
        _startAgentTurn = startAgentTurn,
        _startRetrievalTurn = startRetrievalTurn,
        _proposalService = proposalService;

  final ConversationService service;
  final AgentSettingsService _agentSettingsService;
  final AgentTurnStarter _startAgentTurn;
  final AgentRetrievalTurnStarter? _startRetrievalTurn;
  final AgentWriteProposalService? _proposalService;

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

  AgentTurnSession? _activeSession;
  StreamSubscription<AgentTurnEvent>? _turnEvents;
  String? _retryConversationId;
  String? _retryUserMessageId;
  int _turnEpoch = 0;
  int _threadRevision = 0;
  bool _disposed = false;

  /// Passive-dismissal Presentation state: one exact proposal identity per
  /// source User turn, grouped by source Conversation. This remains transient
  /// and permits proposals from different source turns to coexist without
  /// hiding an older pending proposal behind a newer turn.
  final Map<String, Map<String, String>> _proposalIdByTurnByConversation =
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
    if (hasActiveTurn) {
      errorMessage = '请先停止当前生成';
      notifyListeners();
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
    if (!isDraft) return;
    draftScope = scope;
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> openConversation(String conversationId) async {
    if (hasActiveTurn) {
      errorMessage = '请先停止当前生成';
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
      case AgentTurnFailed(:final failure):
        _showTurnFailure(failure);
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

  void _showTurnFailure(AgentTurnFailure failure) {
    turnFailure = failure;
    turnPhase = failure == AgentTurnFailure.cancelled
        ? AssistantTurnPhase.cancelled
        : AssistantTurnPhase.failed;
    errorMessage = _agentFailureMessage(failure);
    statusMessage = failure == AgentTurnFailure.cancelled ? '已停止生成' : null;
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

  Future<bool> deleteActiveConversation() async {
    final active = activeThread;
    if (active == null) return false;
    try {
      await service.deleteConversation(active.conversation.conversationId);
      _proposalIdByTurnByConversation.remove(
        active.conversation.conversationId,
      );
      _clearProposal();
      activeThread = null;
      _threadRevision++;
      draftScope = ConversationScope.global();
      draftFileIds.clear();
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
    turnFailure = null;
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
