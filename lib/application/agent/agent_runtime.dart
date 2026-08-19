/// A0-4 Shiroha Agent runtime: one orchestrated, provider-neutral turn over a
/// persisted C0 User Message.
library;

import 'dart:async';
import 'dart:convert';

import '../../core/observability/diagnostic_summary.dart';
import '../../core/observability/log_writer.dart';
import '../../core/observability/trace_context.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import '../backup/backup_restore_gate.dart';
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
    final lease = BackupRestoreMutationGate.instance.acquireMutationLease();
    if (!_activeConversations.add(conversationId)) {
      lease.release();
      return _failedSession(AgentTurnFailure.alreadyRunning);
    }

    final turn = _ActiveTurn(
      limits: _limits,
      requestId: '${conversationId}_${userMessageId}_${_turnRequestSequence++}',
      correlationId: TraceContext.createCorrelationId(),
      traceId: TraceContext.createTraceId(),
      mutationLease: lease,
    );
    turn.timeoutTimer = Timer(_limits.turnTimeout, () {
      turn.timedOut = true;
      turn.cancellation.cancel();
    });
    final session = AgentTurnSession(
      events: turn.events.stream,
      result: turn.result.future,
      cancel: turn.cancellation.cancel,
      diagnosticId: turn.correlationId,
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
        turn.mutationLease.release();
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
    // OBS-1 (P3-1): a pre-run rejection (invalidTarget/alreadyRunning) never
    // enters the turn pipeline, so it has no trace and must not expose a
    // diagnostic id that cannot be correlated to any log.
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
    // OBS-1: every production turn runs as a root operation inside its own
    // trace zone. Provider rounds, tool calls, fallback, RAG retrieval and
    // terminal events then carry the same correlation/trace automatically.
    await TraceContext.run(
      correlationId: turn.correlationId,
      traceId: turn.traceId,
      operationKind: TraceOperationKind.agentTurn,
      action: () async {
        LogWriter.info(
          'Agent turn started',
          module: 'Agent',
          data: const <String, Object?>{'stage': 'turn_started'},
        );
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
          _completeTurnResult(turn, result);
          LogWriter.info(
            'Agent turn completed',
            module: 'Agent',
            data: <String, Object?>{
              'stage': 'turn_completed',
              'status': 'success',
              'durationMs': turn.elapsedMilliseconds,
            },
          );
        } catch (error) {
          final failure = _mapFailure(error, turn);
          _logTerminalTurnFailure(turn, error, failure);
          final summary = DiagnosticSummary(
            diagnosticId: turn.correlationId,
            operation: 'agent_turn',
            failure: failure.name,
            providerRounds: turn.providerRounds,
            toolCalls: turn.toolCallsCount,
            lastTool: turn.lastToolName,
            durationMs: turn.elapsedMilliseconds,
          );
          _emit(turn, AgentTurnFailedEvent(failure));
          _completeTurnResult(
            turn,
            AgentTurnFailed(failure, summary: summary),
          );
        }
      },
    );
  }

  void _completeTurnResult(_ActiveTurn turn, AgentTurnResult result) {
    turn.mutationLease.release();
    if (!turn.result.isCompleted) turn.result.complete(result);
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
    LogWriter.info(
      'Agent configuration resolved',
      module: 'Agent',
      data: const <String, Object?>{'stage': 'config_resolved'},
    );
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
    var toolPhaseClosed = false;
    final baseTools = <AgentFunctionToolDefinition>[
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
        final bool serializationAllowed;
        try {
          serializationAllowed = await _retrievalSerializationAllowed(
            turn,
            conversationId: conversationId,
            userMessageId: userMessageId,
            providerProfileId: resolved.profile.profileId,
            grant: retrievalGrant,
          ).timeout(remaining);
        } on TimeoutException {
          throw const _TurnTimeoutException();
        }
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
      final currentTools =
          toolPhaseClosed ? const <AgentFunctionToolDefinition>[] : baseTools;
      final request = AgentProviderRequest(
        systemPrompt: systemPrompt,
        messages: history.messages,
        tools: currentTools,
        toolOutputs: toolOutputs,
        continuationState: continuationState,
        enableNativeWebSearch: !toolPhaseClosed &&
            currentResolved.config.webEnabled &&
            capabilities.nativeWebSearch,
        maxOutputTokens: _limits.maxOutputTokens,
        temperature: currentResolved.config.temperature,
        reasoningEffort: currentResolved.config.reasoningEffort,
      );
      final _ProviderRound round;
      final roundStopwatch = Stopwatch()..start();
      LogWriter.info(
        'Provider round started',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'provider_round_started',
          'providerRound': turn.providerRounds + 1,
        },
      );
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
          LogWriter.info(
            'Agent provider fallback attempted',
            module: 'Agent',
            data: <String, Object?>{
              'stage': 'fallback_attempted',
              'fallbackReason': _fallbackReasonOf(error),
              'providerRound': turn.providerRounds + 1,
            },
          );
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
      turn.providerRounds++;
      LogWriter.info(
        'Provider round completed',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'provider_round_completed',
          'providerRound': turn.providerRounds,
          'functionCallCount': round.functionCalls.length,
          'status': 'success',
          'durationMs': roundStopwatch.elapsedMilliseconds,
        },
      );

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

      if (toolPhaseClosed) {
        throw const _TurnFailure(AgentTurnFailure.providerMalformed);
      }

      final continuation = round.continuationState;
      if (continuation == null) {
        throw const _TurnFailure(AgentTurnFailure.providerMalformed);
      }
      for (final call in round.functionCalls) {
        if (!turn.seenCallIds.add(call.callId)) {
          throw const _TurnFailure(AgentTurnFailure.providerMalformed);
        }
      }

      final toolRoundBudgetExhausted =
          turn.toolRoundsUsed >= _limits.maxToolRounds;
      final localCallBudgetExhausted =
          turn.localCallsUsed + round.functionCalls.length >
              _limits.maxLocalCalls;

      if (toolRoundBudgetExhausted || localCallBudgetExhausted) {
        toolPhaseClosed = true;
        final budgetExhaustedReason = toolRoundBudgetExhausted
            ? 'tool_round_limit_exceeded'
            : 'local_call_limit_exceeded';
        LogWriter.info(
          'Tool budget exhausted, closing tool phase',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_phase_closed',
            'reason': budgetExhaustedReason,
            'toolRoundsUsed': turn.toolRoundsUsed,
            'localCallsUsed': turn.localCallsUsed,
            'requestedCalls': round.functionCalls.length,
          },
        );
        continuationState = continuation;
        toolOutputs = <AgentFunctionToolOutput>[
          for (final call in round.functionCalls)
            AgentFunctionToolOutput(
              callId: call.callId,
              output: _toolBudgetInsufficientOutput(),
            ),
        ];
        retrievalOutputCallIds = const <String>{};
        continue;
      }

      turn.toolRoundsUsed++;

      final outputs = <AgentFunctionToolOutput>[];
      final nextRetrievalOutputCallIds = <String>{};
      for (final call in round.functionCalls) {
        _throwIfCancelled(turn);
        _emit(turn, AgentTurnToolCall(callId: call.callId, name: call.name));
        final toolStopwatch = Stopwatch()..start();
        final safeCallId = _safeCallId(call.callId);
        final safeToolName = _safeToolName(call.name);
        LogWriter.info(
          'Tool call started',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_call_started',
            'toolName': safeToolName,
            'callId': safeCallId,
          },
        );
        final output = await _dispatchTool(
          turn,
          call,
          conversationId: conversationId,
          userMessageId: userMessageId,
          scope: slice.conversation.scope,
          providerProfileId: resolved.profile.profileId,
          grant: retrievalGrant,
        );
        final toolStatus = _toolCallStatus(output);
        LogWriter.info(
          'Tool call completed',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_call_completed',
            'toolName': safeToolName,
            'callId': safeCallId,
            ...toolStatus,
            'durationMs': toolStopwatch.elapsedMilliseconds,
          },
        );
        turn.toolCallsCount++;
        turn.lastToolName = safeToolName;
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

      if (turn.toolRoundsUsed >= _limits.maxToolRounds ||
          turn.localCallsUsed >= _limits.maxLocalCalls) {
        toolPhaseClosed = true;
        final budgetExhaustedReason =
            turn.toolRoundsUsed >= _limits.maxToolRounds
                ? 'tool_round_limit_exceeded'
                : 'local_call_limit_exceeded';
        LogWriter.info(
          'Tool budget exhausted, closing tool phase',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_phase_closed',
            'reason': budgetExhaustedReason,
            'toolRoundsUsed': turn.toolRoundsUsed,
            'localCallsUsed': turn.localCallsUsed,
          },
        );
      }
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
        return _dispatchRetrievalWithTrace(
          turn: turn,
          argumentsJson: call.argumentsJson,
          grant: grant,
          conversationId: conversationId,
          sourceUserMessageId: userMessageId,
          providerProfileId: providerProfileId,
          currentFileIds: currentFileIds,
          remaining: remaining,
        );
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

  /// OBS-1: the actual RAG retrieval runs as a child trace of the current
  /// Agent turn (same correlation, new trace, parent = Agent trace) and logs
  /// only structural counts and fixed status/failure codes. Retrieval
  /// authorization stays untouched: the grant, per-turn approval and
  /// serialization gate run inside the wrapped action unchanged. Logging is
  /// best effort and never changes the retrieval outcome.
  Future<String> _dispatchRetrievalWithTrace({
    required _ActiveTurn turn,
    required String argumentsJson,
    required RetrievalEgressGrant? grant,
    required String conversationId,
    required String sourceUserMessageId,
    required String providerProfileId,
    required List<String> currentFileIds,
    required Duration remaining,
  }) async {
    final retrievalDispatcher = _retrievalDispatcher!;
    final stopwatch = Stopwatch()..start();
    final requestedCounts = _retrievalRequestCounts(argumentsJson);
    return TraceContext.runOperation(
      operationKind: TraceOperationKind.ragRetrieval,
      action: () async {
        try {
          final output = await retrievalDispatcher
              .dispatch(
                argumentsJson: argumentsJson,
                grant: grant,
                turnRequestId: turn.requestId,
                conversationId: conversationId,
                sourceUserMessageId: sourceUserMessageId,
                providerProfileId: providerProfileId,
                currentFileIds: currentFileIds,
                serializationAllowed: () => _retrievalSerializationAllowed(
                  turn,
                  conversationId: conversationId,
                  userMessageId: sourceUserMessageId,
                  providerProfileId: providerProfileId,
                  grant: grant,
                ),
              )
              .timeout(remaining);
          final outcome = _retrievalOutcome(output);
          LogWriter.info(
            'Agent file retrieval completed',
            module: 'Retrieval',
            data: <String, Object?>{
              'stage': 'retrieval_completed',
              'requestedFileCount': requestedCounts?.requested,
              'effectiveFileCount': currentFileIds.length,
              if (requestedCounts?.limit != null)
                'limit': requestedCounts!.limit,
              'hitCount': outcome.hitCount,
              'issueCount': outcome.issueCount,
              'status': outcome.status,
              if (outcome.failureCode != null)
                'failureCode': outcome.failureCode,
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          return output;
        } catch (error) {
          LogWriter.error(
            'Agent file retrieval failed',
            module: 'Retrieval',
            data: <String, Object?>{
              'stage': 'retrieval_completed',
              'requestedFileCount': requestedCounts?.requested,
              'effectiveFileCount': currentFileIds.length,
              if (requestedCounts?.limit != null)
                'limit': requestedCounts!.limit,
              'status': 'failed',
              'errorType': error.runtimeType.toString(),
              'durationMs': stopwatch.elapsedMilliseconds,
            },
          );
          rethrow;
        }
      },
    );
  }

  /// Counts only; never decodes retrieval content.
  ({int requested, int? limit})? _retrievalRequestCounts(
    String argumentsJson,
  ) {
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map || decoded['file_ids'] is! List) return null;
      final limit = decoded['limit'];
      return (
        requested: (decoded['file_ids'] as List).length,
        limit: limit is int ? limit : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Extracts counts and fixed codes from the structured tool output only.
  ({
    String status,
    int? hitCount,
    int? issueCount,
    String? failureCode,
  }) _retrievalOutcome(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['ok'] == true && decoded['result'] is Map) {
        final result = decoded['result'] as Map;
        final hits = result['hits'];
        final issues = result['issues'];
        return (
          status: 'success',
          hitCount: hits is List ? hits.length : null,
          issueCount: issues is List ? issues.length : null,
          failureCode: null,
        );
      }
      if (decoded is Map && decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code'];
        return (
          status: 'failed',
          hitCount: null,
          issueCount: null,
          failureCode: code is String ? code : null,
        );
      }
    } catch (_) {}
    return (
      status: 'failed',
      hitCount: null,
      issueCount: null,
      failureCode: null
    );
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

  String _toolBudgetInsufficientOutput() => jsonEncode(const <String, Object?>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'tool_budget_insufficient',
          'message': 'The requested tool batch exceeds the remaining tool budget. '
              'Use the information already available and provide the best bounded answer.',
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
      LogWriter.info(
        'Agent proposal staged',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'proposal_staged',
          'outcome': outcome,
        },
      );
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
      LogWriter.info(
        'Agent study plan draft staged',
        module: 'Agent',
        data: <String, Object?>{
          'stage': 'study_plan_draft_staged',
          'studyPlanOutcome': outcome,
        },
      );
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

  /// OBS-1 best-effort terminal event: one structured record for
  /// `turn_failed` / `turn_cancelled` / `turn_timeout` carrying only
  /// fixed categories and counters. Never includes error bodies or stacks.
  void _logTerminalTurnFailure(
    _ActiveTurn turn,
    Object error,
    AgentTurnFailure failure,
  ) {
    final stage = switch (failure) {
      AgentTurnFailure.timeout => 'turn_timeout',
      AgentTurnFailure.cancelled => 'turn_cancelled',
      _ => 'turn_failed',
    };
    final failureCode = failure.name;
    LogWriter.error(
      switch (failure) {
        AgentTurnFailure.timeout => 'Agent turn timed out',
        AgentTurnFailure.cancelled => 'Agent turn cancelled',
        _ => 'Agent turn failed',
      },
      module: 'Agent',
      data: <String, Object?>{
        'stage': stage,
        'status': 'failed',
        'failure': failure.name,
        'failureCode': failureCode,
        'providerRounds': turn.providerRounds,
        'toolCalls': turn.toolCallsCount,
        'toolRoundsUsed': turn.toolRoundsUsed,
        'localCallsUsed': turn.localCallsUsed,
        'durationMs': turn.elapsedMilliseconds,
      },
    );
  }

  /// Fixed safe fallback category derived from the provider failure taxonomy.
  static String _fallbackReasonOf(Object error) {
    if (error is AgentProviderException) return error.failure.name;
    return 'unknown';
  }

  /// Registered local tool names. Anything else is provider-controlled and
  /// must never be logged as-is.
  static final Set<String> _registeredToolNames = <String>{
    ...AgentStudyToolCatalog.toolNames,
    AgentRetrievalToolCatalog.toolName,
    AgentWriteProposalToolCatalog.toolName,
    AgentStudyPlanToolCatalog.toolName,
  };

  /// Normalizes a provider-supplied tool name: known registered names keep
  /// their canonical form; anything else becomes the fixed safe token.
  static String _safeToolName(String name) =>
      _registeredToolNames.contains(name) ? name : 'unknown_tool';

  /// Strict opaque provider call token. Anything else (embedded user text,
  /// punctuation, unbounded length) is normalized to the fixed safe token.
  static final RegExp _opaqueCallIdPattern = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');

  static String _safeCallId(String callId) =>
      _opaqueCallIdPattern.hasMatch(callId) ? callId : 'invalid_call_id';

  /// Fixed status/code derived from the structured tool output only; never
  /// logs tool arguments or result bodies.
  static Map<String, Object?> _toolCallStatus(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['ok'] == true) {
        return const <String, Object?>{'status': 'success'};
      }
      if (decoded is Map && decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code'];
        return <String, Object?>{
          'status': 'failed',
          if (code is String && code.isNotEmpty) 'failureCode': code,
        };
      }
    } catch (_) {}
    return const <String, Object?>{'status': 'failed'};
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
    required this.correlationId,
    required this.traceId,
    required this.mutationLease,
  }) : _limits = limits {
    _stopwatch.start();
  }

  final AgentRuntimeLimits _limits;
  final String requestId;

  /// OBS-1 root operation identity of this turn.
  final String correlationId;
  final String traceId;
  final BackupRestoreMutationLease mutationLease;

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
  int providerRounds = 0;
  int toolCallsCount = 0;
  String? lastToolName;
  bool fallbackAttempted = false;
  bool webProgressEmitted = false;
  bool proposalStaged = false;
  bool studyPlanDraftStaged = false;
  final Set<String> seenCallIds = <String>{};
  final StringBuffer visibleText = StringBuffer();

  int get elapsedMilliseconds => _stopwatch.elapsedMilliseconds;

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
