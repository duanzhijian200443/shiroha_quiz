/// A0-4 Shiroha Agent runtime: one orchestrated, provider-neutral turn over a
/// persisted C0 User Message.
library;

import 'dart:async';
import 'dart:convert';

import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import '../conversations/conversation_repository.dart';
import '../conversations/conversation_service.dart';
import 'agent_config.dart';
import 'agent_config_service.dart';
import 'agent_history.dart';
import 'agent_provider.dart';
import 'agent_retrieval_tool.dart';
import 'agent_runtime_limits.dart';
import 'agent_study_plan_tool_catalog.dart';
import 'agent_study_plan_tool_dispatcher.dart';
import 'agent_study_tool_catalog.dart';
import 'agent_study_tool_dispatcher.dart';
import 'agent_turn.dart';
import 'agent_write_proposal_tool_catalog.dart';
import 'agent_write_proposal_tool_dispatcher.dart';
import 'shiroha_system_prompt.dart';
import 'retrieval_egress_grant.dart';

/// Minimal provider construction boundary.
///
/// Provider-specific construction (currently only DeepSeek Responses) stays
/// in infrastructure/services/composition root; the Application runtime never
/// imports a concrete Provider.
typedef AgentProviderFactory = AgentProviderPort Function(
    ResolvedAgentConfig resolvedConfig);

/// One-in-flight-per-conversation Agent turn orchestrator.
///
/// The runtime consumes only application seams ([ConversationService],
/// [AgentRuntimeConfigResolver], [AgentStudyToolDispatcher]) and never touches
/// repositories, SQLite, MCP transport, or the Presentation facade.
final class ShirohaAgentRuntime {
  ShirohaAgentRuntime({
    required ConversationService conversationService,
    required AgentRuntimeConfigResolver configResolver,
    required AgentProviderFactory providerFactory,
    required AgentStudyToolDispatcher toolDispatcher,
    AgentWriteProposalToolDispatcher? proposalDispatcher,
    AgentStudyPlanToolDispatcher? studyPlanDispatcher,
    AgentRetrievalToolDispatcher? retrievalDispatcher,
    AgentRuntimeLimits limits = const AgentRuntimeLimits(),
  })  : _conversationService = conversationService,
        _configResolver = configResolver,
        _providerFactory = providerFactory,
        _toolDispatcher = toolDispatcher,
        _proposalDispatcher = proposalDispatcher,
        _studyPlanDispatcher = studyPlanDispatcher,
        _retrievalDispatcher = retrievalDispatcher,
        _limits = limits,
        _systemPrompt = const ShirohaSystemPrompt();

  final ConversationService _conversationService;
  final AgentRuntimeConfigResolver _configResolver;
  final AgentProviderFactory _providerFactory;
  final AgentStudyToolDispatcher _toolDispatcher;
  final AgentWriteProposalToolDispatcher? _proposalDispatcher;
  final AgentStudyPlanToolDispatcher? _studyPlanDispatcher;
  final AgentRetrievalToolDispatcher? _retrievalDispatcher;
  final AgentRuntimeLimits _limits;
  final ShirohaSystemPrompt _systemPrompt;

  final Set<String> _activeConversations = <String>{};
  int _turnRequestSequence = 0;

  /// Transient, in-memory only: final generated text waiting for persistence.
  /// Lost on process restart; v19 has no durable turn state.
  final Map<(String, String), _PendingFinalAssistant> _pendingFinalAssistant =
      <(String, String), _PendingFinalAssistant>{};

  /// Starts one Agent turn bound to an already-persisted User Message.
  ///
  /// Returns synchronously; typed failures (invalid target, already running)
  /// surface through the session result.
  AgentTurnSession startTurn({
    required String conversationId,
    required String userMessageId,
  }) {
    return _startTurn(
        conversationId: conversationId, userMessageId: userMessageId);
  }

  AgentTurnSession startTurnWithRetrieval({
    required String conversationId,
    required String userMessageId,
    required RetrievalEgressApproval approval,
  }) {
    return _startTurn(
        conversationId: conversationId,
        userMessageId: userMessageId,
        approval: approval);
  }

  AgentTurnSession _startTurn({
    required String conversationId,
    required String userMessageId,
    RetrievalEgressApproval? approval,
  }) {
    if (!_isBoundedId(conversationId) || !_isBoundedId(userMessageId)) {
      return _failedSession(AgentTurnFailure.invalidTarget);
    }
    if (!_activeConversations.add(conversationId)) {
      return _failedSession(AgentTurnFailure.alreadyRunning);
    }

    final turn = _ActiveTurn(
      limits: _limits,
      requestId: '${conversationId}_${userMessageId}_${_turnRequestSequence++}',
    );
    turn.timeoutTimer = Timer(_limits.turnTimeout, () {
      turn.timedOut = true;
      turn.cancellation.cancel();
    });
    final session = AgentTurnSession(
      events: turn.events.stream,
      result: turn.result.future,
      cancel: turn.cancellation.cancel,
    );
    unawaited(
      _runTurn(
        turn,
        conversationId: conversationId,
        userMessageId: userMessageId,
        approval: approval,
      ).whenComplete(() {
        _activeConversations.remove(conversationId);
        turn.timeoutTimer.cancel();
        if (!turn.result.isCompleted) {
          turn.result.complete(
            const AgentTurnFailed(AgentTurnFailure.internalError),
          );
        }
        if (!turn.events.isClosed) turn.events.close();
      }),
    );
    return session;
  }

  AgentTurnSession _failedSession(AgentTurnFailure failure) {
    final events = StreamController<AgentTurnEvent>.broadcast();
    final result = Completer<AgentTurnResult>();
    events.add(AgentTurnFailedEvent(failure));
    events.close();
    result.complete(AgentTurnFailed(failure));
    return AgentTurnSession(
      events: events.stream,
      result: result.future,
      cancel: () {},
    );
  }

  Future<void> _runTurn(
    _ActiveTurn turn, {
    required String conversationId,
    required String userMessageId,
    RetrievalEgressApproval? approval,
  }) async {
    try {
      final result = await _executeTurn(
        turn,
        conversationId: conversationId,
        userMessageId: userMessageId,
        approval: approval,
      );
      switch (result) {
        case AgentTurnSuccess(:final assistantMessage):
          _emit(turn, AgentTurnCompleted(assistantMessage));
        case AgentTurnAlreadyCompleted(:final assistantMessage):
          _emit(turn, AgentTurnCompleted(assistantMessage));
        case AgentTurnFailed():
          break;
      }
      turn.result.complete(result);
    } catch (error) {
      final failure = _mapFailure(error, turn);
      _emit(turn, AgentTurnFailedEvent(failure));
      turn.result.complete(AgentTurnFailed(failure));
    }
  }

  Future<AgentTurnResult> _executeTurn(
    _ActiveTurn turn, {
    required String conversationId,
    required String userMessageId,
    RetrievalEgressApproval? approval,
  }) async {
    final key = (conversationId, userMessageId);
    final slice = await _loadSlice(turn, conversationId);
    if (slice.conversation.scope.isUnavailableLearningSpace) {
      throw const _TurnFailure(AgentTurnFailure.scopeUnavailable);
    }
    final target = slice.messages
        .where((message) => message.messageId == userMessageId)
        .firstOrNull;
    if (target == null || target.role != ConversationMessageRole.user) {
      throw const _TurnFailure(AgentTurnFailure.invalidTarget);
    }
    final hasLaterUserMessage = slice.messages.any(
      (message) =>
          message.role == ConversationMessageRole.user &&
          message.sequence > target.sequence,
    );
    if (hasLaterUserMessage) {
      throw const _TurnFailure(AgentTurnFailure.invalidTarget);
    }
    final existingAssistant = slice.messages
        .where(
          (message) =>
              message.role == ConversationMessageRole.assistant &&
              message.sequence > target.sequence,
        )
        .firstOrNull;
    if (existingAssistant != null) {
      return AgentTurnAlreadyCompleted(assistantMessage: existingAssistant);
    }

    // A previous in-process turn generated final text but could not confirm
    // persistence: retry the same final text instead of regenerating.
    final pending = _pendingFinalAssistant[key];
    if (pending != null) {
      final message = await _appendAssistantWithRecovery(
        turn,
        target: target,
        pending: pending,
      );
      _pendingFinalAssistant.remove(key);
      return AgentTurnSuccess(assistantMessage: message);
    }

    final resolved = await _resolveConfig();
    _throwIfExpired(turn);
    var currentResolved = resolved;
    var provider = _providerFactory(currentResolved);
    turn.provider = provider;
    var capabilities = provider.capabilities;
    if (currentResolved.config.webEnabled && !capabilities.nativeWebSearch) {
      throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
    }
    if (!capabilities.functionTools) {
      throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
    }

    final history = AgentHistoryBuilder(
      limits: _limits,
    ).build(slice: slice, targetMessageId: userMessageId);
    final proposalCapabilityEnabled = _proposalDispatcher != null;
    final studyPlanCapabilityEnabled = _studyPlanDispatcher != null;
    final approvedIds = approval?.approvedFileIds ?? const <String>[];
    final hasRetrievalApproval = approvedIds.isNotEmpty;
    final retrievalDispatcher = _retrievalDispatcher;
    final currentFileIds = retrievalDispatcher == null || !hasRetrievalApproval
        ? const <String>[]
        : await retrievalDispatcher.effectiveFileIds(
            scope: slice.conversation.scope,
            conversationFileIds:
                slice.files.map((file) => file.fileId).toList(growable: false),
          );
    final retrievalGrant = hasRetrievalApproval &&
            approvedIds.every(currentFileIds.contains) &&
            _retrievalDispatcher != null
        ? RetrievalEgressGrant(
            agentTurnRequestId: turn.requestId,
            conversationId: conversationId,
            sourceUserMessageId: userMessageId,
            providerProfileId: resolved.profile.profileId,
            approvedFileIds: approvedIds,
          )
        : null;
    final systemPrompt = _systemPrompt.build(
      scope: slice.conversation.scope,
      files: slice.files,
      proposalCapabilityEnabled: proposalCapabilityEnabled,
      studyPlanCapabilityEnabled: studyPlanCapabilityEnabled,
      retrievalCapabilityEnabled: retrievalGrant != null,
      retrievableFileIds:
          retrievalGrant?.approvedFileIds.toSet() ?? const <String>{},
    );
    final tools = <AgentFunctionToolDefinition>[
      ...AgentStudyToolCatalog.definitions,
      if (proposalCapabilityEnabled) AgentWriteProposalToolCatalog.definition,
      if (studyPlanCapabilityEnabled) AgentStudyPlanToolCatalog.definition,
      if (retrievalGrant != null) AgentRetrievalToolCatalog.definition,
    ];

    AgentProviderContinuationState? continuationState;
    var toolOutputs = const <AgentFunctionToolOutput>[];
    var retrievalOutputCallIds = const <String>{};
    while (true) {
      if (retrievalOutputCallIds.isNotEmpty) {
        final remaining = turn.remainingBudget();
        if (remaining <= Duration.zero) {
          throw const _TurnTimeoutException();
        }
        final serializationAllowed = await _retrievalSerializationAllowed(
          turn,
          conversationId: conversationId,
          userMessageId: userMessageId,
          providerProfileId: resolved.profile.profileId,
          grant: retrievalGrant,
        ).timeout(remaining, onTimeout: () => false);
        if (!serializationAllowed) {
          toolOutputs = <AgentFunctionToolOutput>[
            for (final output in toolOutputs)
              AgentFunctionToolOutput(
                callId: output.callId,
                output: retrievalOutputCallIds.contains(output.callId)
                    ? _retrievalAccessDeniedOutput()
                    : output.output,
              ),
          ];
        }
      }
      _throwIfExpired(turn);
      _throwIfCancelled(turn);
      final request = AgentProviderRequest(
        systemPrompt: systemPrompt,
        messages: history.messages,
        tools: tools,
        toolOutputs: toolOutputs,
        continuationState: continuationState,
        enableNativeWebSearch:
            currentResolved.config.webEnabled && capabilities.nativeWebSearch,
        maxOutputTokens: _limits.maxOutputTokens,
        temperature: currentResolved.config.temperature,
        reasoningEffort: currentResolved.config.reasoningEffort,
      );
      final _ProviderRound round;
      try {
        round = await _runProviderRound(turn, request);
      } catch (error) {
        if (_canFallback(
          turn: turn,
          resolved: resolved,
          hasRetrievalApproval: hasRetrievalApproval,
          retrievalGrant: retrievalGrant,
          error: error,
        )) {
          turn.fallbackAttempted = true;
          currentResolved = ResolvedAgentConfig(
            config: resolved.config,
            profile: resolved.fallbackProfile!,
          );
          provider = _providerFactory(currentResolved);
          turn.provider = provider;
          capabilities = provider.capabilities;
          if (currentResolved.config.webEnabled &&
              !capabilities.nativeWebSearch) {
            throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
          }
          if (!capabilities.functionTools) {
            throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
          }
          continuationState = null;
          toolOutputs = const <AgentFunctionToolOutput>[];
          retrievalOutputCallIds = const <String>{};
          continue;
        }
        rethrow;
      }

      if (round.functionCalls.isEmpty) {
        final finalText = turn.visibleText.toString();
        if (finalText.trim().isEmpty) {
          throw const _TurnFailure(AgentTurnFailure.providerMalformed);
        }
        _throwIfExpired(turn);
        _throwIfCancelled(turn);
        final pendingAssistant = _PendingFinalAssistant(
          conversationId: conversationId,
          userMessageId: userMessageId,
          finalText: finalText,
        );
        _pendingFinalAssistant[key] = pendingAssistant;
        try {
          final message = await _appendAssistantWithRecovery(
            turn,
            target: target,
            pending: pendingAssistant,
          );
          _pendingFinalAssistant.remove(key);
          return AgentTurnSuccess(assistantMessage: message);
        } on _TurnFailure catch (error) {
          if (error.failure == AgentTurnFailure.conversationUnavailable ||
              error.failure == AgentTurnFailure.scopeUnavailable) {
            _pendingFinalAssistant.remove(key);
          }
          rethrow;
        }
      }

      turn.toolRoundsUsed++;
      if (turn.toolRoundsUsed > _limits.maxToolRounds) {
        throw const _TurnFailure(AgentTurnFailure.toolLimitExceeded);
      }
      final continuation = round.continuationState;
      if (continuation == null) {
        throw const _TurnFailure(AgentTurnFailure.providerMalformed);
      }
      if (turn.localCallsUsed + round.functionCalls.length >
          _limits.maxLocalCalls) {
        throw const _TurnFailure(AgentTurnFailure.toolLimitExceeded);
      }
      for (final call in round.functionCalls) {
        if (!turn.seenCallIds.add(call.callId)) {
          throw const _TurnFailure(AgentTurnFailure.providerMalformed);
        }
      }

      final outputs = <AgentFunctionToolOutput>[];
      final nextRetrievalOutputCallIds = <String>{};
      for (final call in round.functionCalls) {
        _throwIfCancelled(turn);
        _emit(turn, AgentTurnToolCall(callId: call.callId, name: call.name));
        final output = await _dispatchTool(
          turn,
          call,
          conversationId: conversationId,
          userMessageId: userMessageId,
          scope: slice.conversation.scope,
          providerProfileId: resolved.profile.profileId,
          grant: retrievalGrant,
        );
        outputs.add(
          AgentFunctionToolOutput(callId: call.callId, output: output),
        );
        if (call.name == AgentRetrievalToolCatalog.toolName) {
          nextRetrievalOutputCallIds.add(call.callId);
        }
        turn.localCallsUsed++;
      }
      continuationState = continuation;
      toolOutputs = outputs;
      retrievalOutputCallIds = nextRetrievalOutputCallIds;
    }
  }

  Future<ConversationThreadSlice> _loadSlice(
    _ActiveTurn turn,
    String conversationId,
  ) async {
    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    try {
      return await _conversationService.loadConversation(
        conversationId: conversationId,
        limit: _limits.maxHistoryMessages,
      );
    } on ConversationException catch (error) {
      throw _conversationReadFailure(error.failure);
    }
  }

  Future<ResolvedAgentConfig> _resolveConfig() async {
    try {
      return await _configResolver.resolve();
    } on AgentConfigException catch (error) {
      throw _TurnFailure(switch (error.failure) {
        AgentConfigFailure.invalidInput => AgentTurnFailure.internalError,
        AgentConfigFailure.unconfigured => AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.corruptStoredConfig =>
          AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.profileNotFound =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.profileIncomplete =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.temporarilyUnavailable =>
          AgentTurnFailure.temporarilyUnavailable,
      });
    }
  }

  Future<_ProviderRound> _runProviderRound(
    _ActiveTurn turn,
    AgentProviderRequest request,
  ) async {
    final remaining = turn.remainingBudget();
    if (remaining <= Duration.zero) {
      throw const _TurnTimeoutException();
    }
    final done = Completer<_ProviderRound>();
    unawaited(() async {
      try {
        final calls = <AgentProviderFunctionCall>[];
        AgentProviderContinuationState? completedState;
        var completed = false;
        await for (final event in turn.provider!.stream(
          request,
          turn.cancellation.token,
        )) {
          turn.cancellation.token.throwIfCancelled();
          switch (event) {
            case AgentProviderTextDelta(:final text):
              turn.visibleText.write(text);
              _emit(turn, AgentTurnTextDelta(text));
            case AgentProviderFunctionCall():
              calls.add(event);
            case AgentProviderWebSearchEvent(:final phase):
              turn.webProgressEmitted = true;
              _emit(turn, AgentTurnWebSearchEvent(phase));
            case AgentProviderCompleted(:final continuationState):
              if (completed) {
                throw const AgentProviderException(
                  AgentProviderFailure.malformedResponse,
                );
              }
              completed = true;
              completedState = continuationState;
          }
        }
        if (!completed) {
          throw const AgentProviderException(
            AgentProviderFailure.incompleteResponse,
          );
        }
        done.complete(
          _ProviderRound(
            functionCalls: calls,
            continuationState: completedState,
          ),
        );
      } catch (error) {
        if (!done.isCompleted) done.completeError(error);
      }
    }());
    return done.future.timeout(
      remaining,
      onTimeout: () => throw const _TurnTimeoutException(),
    );
  }

  Future<String> _dispatchTool(
    _ActiveTurn turn,
    AgentProviderFunctionCall call, {
    required String conversationId,
    required String userMessageId,
    required ConversationScope scope,
    required String providerProfileId,
    required RetrievalEgressGrant? grant,
  }) async {
    final remaining = turn.remainingBudget();
    if (remaining <= Duration.zero) {
      throw const _TurnTimeoutException();
    }
    try {
      final dispatcher = _proposalDispatcher;
      final studyPlanDispatcher = _studyPlanDispatcher;
      final retrievalDispatcher = _retrievalDispatcher;
      if (call.name == AgentRetrievalToolCatalog.toolName &&
          retrievalDispatcher != null) {
        final current = await _loadSlice(turn, conversationId);
        final sourceMessage = current.messages
            .where((message) => message.messageId == userMessageId)
            .firstOrNull;
        if (sourceMessage == null ||
            current.messages.any(
              (message) =>
                  message.role == ConversationMessageRole.user &&
                  message.sequence > sourceMessage.sequence,
            )) {
          return jsonEncode(const <String, Object?>{
            'ok': false,
            'error': <String, Object?>{
              'code': 'access_denied',
              'message': 'File content is unavailable.',
              'retryable': false,
            },
          });
        }
        final currentFileIds = await retrievalDispatcher.effectiveFileIds(
          scope: current.conversation.scope,
          conversationFileIds:
              current.files.map((file) => file.fileId).toList(growable: false),
        );
        return await retrievalDispatcher
            .dispatch(
              argumentsJson: call.argumentsJson,
              grant: grant,
              turnRequestId: turn.requestId,
              conversationId: conversationId,
              sourceUserMessageId: userMessageId,
              providerProfileId: providerProfileId,
              currentFileIds: currentFileIds,
              serializationAllowed: () => _retrievalSerializationAllowed(
                turn,
                conversationId: conversationId,
                userMessageId: userMessageId,
                providerProfileId: providerProfileId,
                grant: grant,
              ),
            )
            .timeout(remaining);
      }
      if (call.name == AgentWriteProposalToolCatalog.toolName &&
          dispatcher != null) {
        final output = await dispatcher
            .dispatch(
              AgentWriteProposalToolCall(
                argumentsJson: call.argumentsJson,
                sourceConversationId: conversationId,
                sourceMessageId: userMessageId,
                scope: scope,
              ),
              proposalMutationAllowed: () =>
                  !turn.cancellation.token.isCancelled &&
                  turn.remainingBudget() > Duration.zero,
            )
            .timeout(remaining);
        _maybeEmitProposalStaged(turn, output);
        return output;
      }
      if (call.name == AgentStudyPlanToolCatalog.toolName &&
          studyPlanDispatcher != null) {
        final output = await studyPlanDispatcher
            .dispatch(
              AgentStudyPlanToolCall(
                argumentsJson: call.argumentsJson,
                sourceConversationId: conversationId,
                sourceMessageId: userMessageId,
                scope: scope,
              ),
              lifecycleMutationAllowed: () =>
                  !turn.cancellation.token.isCancelled &&
                  turn.remainingBudget() > Duration.zero,
            )
            .timeout(remaining);
        _maybeEmitStudyPlanDraftStaged(turn, output);
        return output;
      }
      return await _toolDispatcher
          .dispatch(call.name, call.argumentsJson)
          .timeout(remaining);
    } on TimeoutException {
      throw const _TurnTimeoutException();
    } catch (_) {
      // A local tool must never leak an exception to the Provider/UI:
      // unexpected dispatcher failures become the same safe structured
      // internal_error output used by the dispatcher's own failure path.
      return jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'internal_error',
          'message': 'An internal error occurred.',
          'retryable': false,
        },
      });
    }
  }

  Future<bool> _retrievalSerializationAllowed(
    _ActiveTurn turn, {
    required String conversationId,
    required String userMessageId,
    required String providerProfileId,
    required RetrievalEgressGrant? grant,
  }) async {
    if (turn.cancellation.token.isCancelled ||
        turn.remainingBudget() <= Duration.zero ||
        grant == null) {
      return false;
    }
    final retrievalDispatcher = _retrievalDispatcher;
    if (retrievalDispatcher == null) return false;
    try {
      final latest = await _loadSlice(turn, conversationId);
      final sourceMessage = latest.messages
          .where((message) => message.messageId == userMessageId)
          .firstOrNull;
      final hasLaterUserMessage = latest.messages.any(
        (message) =>
            message.role == ConversationMessageRole.user &&
            sourceMessage != null &&
            message.sequence > sourceMessage.sequence,
      );
      if (sourceMessage == null || hasLaterUserMessage) return false;
      final latestFileIds = await retrievalDispatcher.effectiveFileIds(
        scope: latest.conversation.scope,
        conversationFileIds:
            latest.files.map((file) => file.fileId).toList(growable: false),
      );
      final latestConfig = await _resolveConfig();
      if (latestConfig.profile.profileId != providerProfileId) return false;
      return grant.permits(
        turnRequestId: turn.requestId,
        conversationId: conversationId,
        sourceUserMessageId: userMessageId,
        providerProfileId: providerProfileId,
        currentFileIds: latestFileIds,
      );
    } catch (_) {
      return false;
    }
  }

  String _retrievalAccessDeniedOutput() => jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'access_denied',
          'message': 'File content is unavailable.',
          'retryable': false,
        },
      });

  /// Emits a typed proposal-staged event when the proposal tool returned a
  /// successful staging/replay result. Event shaping never fails the turn.
  void _maybeEmitProposalStaged(_ActiveTurn turn, String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return;
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) return;
      final proposalId = result['proposal_id'];
      final outcome = result['outcome'];
      final preview = result['preview'];
      if (proposalId is! String || outcome is! String || preview is! Map) {
        return;
      }
      turn.proposalStaged = true;
      _emit(
        turn,
        AgentTurnProposalStaged(
          proposalId: proposalId,
          outcome: outcome,
          preview: Map<String, Object?>.from(preview),
        ),
      );
    } catch (_) {
      // The tool output is still returned to the Provider unchanged.
    }
  }

  /// Emits a typed study-plan-draft-staged event when the study plan tool returned
  /// a successful staging/replay result. Event shaping never fails the turn.
  void _maybeEmitStudyPlanDraftStaged(_ActiveTurn turn, String output) {
    try {
      // Same runtime authority as the staging lifecycle gate: a cancelled or
      // expired turn must emit ZERO actionable StudyPlan presentation events,
      // even when a semantic replay resolves successfully.
      if (turn.cancellation.token.isCancelled ||
          turn.remainingBudget() <= Duration.zero) {
        return;
      }
      final decoded = jsonDecode(output);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return;
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) return;
      final draftId = result['draft_id'];
      final outcome = result['outcome'];
      final preview = result['preview'];
      if (draftId is! String || outcome is! String || preview is! Map) {
        return;
      }
      turn.studyPlanDraftStaged = true;
      _emit(
        turn,
        AgentTurnStudyPlanDraftStaged(
          draftId: draftId,
          outcome: outcome,
          preview: Map<String, Object?>.from(preview),
        ),
      );
    } catch (_) {}
  }

  Future<ConversationMessage> _appendAssistantWithRecovery(
    _ActiveTurn turn, {
    required ConversationMessage target,
    required _PendingFinalAssistant pending,
  }) async {
    try {
      final result = await _conversationService.appendAssistantMessage(
        conversationId: pending.conversationId,
        content: pending.finalText,
      );
      return result.message;
    } on ConversationException catch (error) {
      switch (error.failure) {
        case ConversationFailure.conversationNotFound:
          throw const _TurnFailure(AgentTurnFailure.conversationUnavailable);
        case ConversationFailure.scopeUnavailable:
        case ConversationFailure.projectNotFound:
          throw const _TurnFailure(AgentTurnFailure.scopeUnavailable);
        case ConversationFailure.invalidInput:
        case ConversationFailure.fileNotFound:
          throw const _TurnFailure(AgentTurnFailure.persistenceFailed);
        case ConversationFailure.idConflict:
        case ConversationFailure.dataCorrupt:
        case ConversationFailure.temporarilyUnavailable:
          return _recoverAmbiguousAppend(
            turn,
            target: target,
            pending: pending,
          );
      }
    }
  }

  /// Ambiguous append recovery: reload and check whether the expected
  /// Assistant row exists; only a confirmed-absent state retries the same
  /// final text. Unconfirmable storage keeps a typed persistence failure.
  Future<ConversationMessage> _recoverAmbiguousAppend(
    _ActiveTurn turn, {
    required ConversationMessage target,
    required _PendingFinalAssistant pending,
  }) async {
    final ConversationThreadSlice slice;
    try {
      slice = await _conversationService.loadConversation(
        conversationId: pending.conversationId,
        limit: _limits.maxHistoryMessages,
      );
    } on ConversationException catch (error) {
      throw switch (error.failure) {
        ConversationFailure.conversationNotFound => const _TurnFailure(
            AgentTurnFailure.conversationUnavailable,
          ),
        ConversationFailure.scopeUnavailable ||
        ConversationFailure.projectNotFound =>
          const _TurnFailure(
            AgentTurnFailure.scopeUnavailable,
          ),
        _ => const _TurnFailure(AgentTurnFailure.persistenceFailed),
      };
    }
    final expected = slice.messages
        .where(
          (message) =>
              message.role == ConversationMessageRole.assistant &&
              message.sequence > target.sequence &&
              message.content == pending.finalText,
        )
        .firstOrNull;
    if (expected != null) return expected;

    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    try {
      final result = await _conversationService.appendAssistantMessage(
        conversationId: pending.conversationId,
        content: pending.finalText,
      );
      return result.message;
    } on ConversationException catch (error) {
      throw switch (error.failure) {
        ConversationFailure.conversationNotFound => const _TurnFailure(
            AgentTurnFailure.conversationUnavailable,
          ),
        ConversationFailure.scopeUnavailable ||
        ConversationFailure.projectNotFound =>
          const _TurnFailure(
            AgentTurnFailure.scopeUnavailable,
          ),
        _ => const _TurnFailure(AgentTurnFailure.persistenceFailed),
      };
    }
  }

  void _emit(_ActiveTurn turn, AgentTurnEvent event) {
    if (turn.events.isClosed) return;
    turn.events.add(event);
  }

  void _throwIfExpired(_ActiveTurn turn) {
    if (turn.remainingBudget() <= Duration.zero) {
      throw const _TurnTimeoutException();
    }
  }

  void _throwIfCancelled(_ActiveTurn turn) {
    turn.cancellation.token.throwIfCancelled();
  }

  _TurnFailure _conversationReadFailure(ConversationFailure failure) {
    return switch (failure) {
      ConversationFailure.invalidInput => const _TurnFailure(
          AgentTurnFailure.invalidTarget,
        ),
      ConversationFailure.conversationNotFound => const _TurnFailure(
          AgentTurnFailure.conversationUnavailable,
        ),
      ConversationFailure.scopeUnavailable ||
      ConversationFailure.projectNotFound =>
        const _TurnFailure(
          AgentTurnFailure.scopeUnavailable,
        ),
      ConversationFailure.temporarilyUnavailable => const _TurnFailure(
          AgentTurnFailure.temporarilyUnavailable,
        ),
      ConversationFailure.fileNotFound ||
      ConversationFailure.idConflict ||
      ConversationFailure.dataCorrupt =>
        const _TurnFailure(
          AgentTurnFailure.internalError,
        ),
    };
  }

  AgentTurnFailure _mapFailure(Object error, _ActiveTurn turn) {
    if (error is _TurnTimeoutException || error is TimeoutException) {
      return AgentTurnFailure.timeout;
    }
    if (error is _TurnFailure) return error.failure;
    if (error is AgentProviderException) {
      if (error.failure == AgentProviderFailure.cancelled) {
        return turn.timedOut
            ? AgentTurnFailure.timeout
            : AgentTurnFailure.cancelled;
      }
      return switch (error.failure) {
        AgentProviderFailure.invalidRequest =>
          AgentTurnFailure.providerMalformed,
        AgentProviderFailure.authentication => AgentTurnFailure.authentication,
        AgentProviderFailure.rateLimited => AgentTurnFailure.rateLimited,
        AgentProviderFailure.temporarilyUnavailable =>
          AgentTurnFailure.temporarilyUnavailable,
        AgentProviderFailure.timeout => AgentTurnFailure.timeout,
        AgentProviderFailure.cancelled => AgentTurnFailure.cancelled,
        AgentProviderFailure.unsupportedCapability =>
          AgentTurnFailure.unsupportedCapability,
        AgentProviderFailure.unsupportedModel =>
          AgentTurnFailure.unsupportedModel,
        AgentProviderFailure.incompleteResponse =>
          AgentTurnFailure.providerMalformed,
        AgentProviderFailure.malformedResponse =>
          AgentTurnFailure.providerMalformed,
        AgentProviderFailure.internalError => AgentTurnFailure.internalError,
      };
    }
    if (error is AgentConfigException) {
      return switch (error.failure) {
        AgentConfigFailure.invalidInput => AgentTurnFailure.internalError,
        AgentConfigFailure.unconfigured => AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.corruptStoredConfig =>
          AgentTurnFailure.agentUnconfigured,
        AgentConfigFailure.profileNotFound =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.profileIncomplete =>
          AgentTurnFailure.profileUnavailable,
        AgentConfigFailure.temporarilyUnavailable =>
          AgentTurnFailure.temporarilyUnavailable,
      };
    }
    if (error is ConversationException) {
      return _conversationReadFailure(error.failure).failure;
    }
    if (error is AgentHistoryException) {
      return switch (error.failure) {
        AgentHistoryFailure.targetMissing => AgentTurnFailure.invalidTarget,
        AgentHistoryFailure.targetTooLarge =>
          AgentTurnFailure.historyLimitExceeded,
      };
    }
    return AgentTurnFailure.internalError;
  }

  bool _canFallback({
    required _ActiveTurn turn,
    required ResolvedAgentConfig resolved,
    required bool hasRetrievalApproval,
    required RetrievalEgressGrant? retrievalGrant,
    required Object error,
  }) {
    if (resolved.fallbackProfile == null ||
        turn.fallbackAttempted ||
        turn.cancellation.token.isCancelled ||
        turn.timedOut ||
        turn.remainingBudget() <= Duration.zero ||
        turn.visibleText.isNotEmpty ||
        turn.webProgressEmitted ||
        turn.localCallsUsed > 0 ||
        turn.toolRoundsUsed > 0 ||
        turn.proposalStaged ||
        turn.studyPlanDraftStaged ||
        hasRetrievalApproval ||
        retrievalGrant != null) {
      return false;
    }
    return _isEligibleProviderFailure(error);
  }

  static bool _isEligibleProviderFailure(Object error) {
    if (error is! AgentProviderException) return false;
    return switch (error.failure) {
      AgentProviderFailure.authentication ||
      AgentProviderFailure.rateLimited ||
      AgentProviderFailure.temporarilyUnavailable ||
      AgentProviderFailure.timeout ||
      AgentProviderFailure.unsupportedModel ||
      AgentProviderFailure.incompleteResponse ||
      AgentProviderFailure.malformedResponse ||
      AgentProviderFailure.internalError =>
        true,
      AgentProviderFailure.cancelled ||
      AgentProviderFailure.invalidRequest ||
      AgentProviderFailure.unsupportedCapability =>
        false,
    };
  }

  static bool _isBoundedId(String value) {
    final length = value.runes.length;
    return length >= 1 && length <= 128 && !value.contains('\u0000');
  }
}

final class _ActiveTurn {
  _ActiveTurn({
    required AgentRuntimeLimits limits,
    required this.requestId,
  }) : _limits = limits {
    _stopwatch.start();
  }

  final AgentRuntimeLimits _limits;
  final String requestId;
  final AgentCancellationController cancellation =
      AgentCancellationController();
  final Stopwatch _stopwatch = Stopwatch();
  final StreamController<AgentTurnEvent> events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> result = Completer<AgentTurnResult>();
  late final Timer timeoutTimer;
  var timedOut = false;
  AgentProviderPort? provider;
  int toolRoundsUsed = 0;
  int localCallsUsed = 0;
  bool fallbackAttempted = false;
  bool webProgressEmitted = false;
  bool proposalStaged = false;
  bool studyPlanDraftStaged = false;
  final Set<String> seenCallIds = <String>{};
  final StringBuffer visibleText = StringBuffer();

  Duration remainingBudget() {
    final elapsed = _stopwatch.elapsed;
    return elapsed >= _limits.turnTimeout
        ? Duration.zero
        : _limits.turnTimeout - elapsed;
  }
}

final class _ProviderRound {
  const _ProviderRound({
    required this.functionCalls,
    required this.continuationState,
  });

  final List<AgentProviderFunctionCall> functionCalls;
  final AgentProviderContinuationState? continuationState;
}

final class _PendingFinalAssistant {
  const _PendingFinalAssistant({
    required this.conversationId,
    required this.userMessageId,
    required this.finalText,
  });

  final String conversationId;
  final String userMessageId;
  final String finalText;
}

final class _TurnFailure implements Exception {
  const _TurnFailure(this.failure);

  final AgentTurnFailure failure;
}

final class _TurnTimeoutException implements Exception {
  const _TurnTimeoutException();
}
