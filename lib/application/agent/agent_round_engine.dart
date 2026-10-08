part of 'agent_runtime.dart';

final class AgentRoundEngine {
  AgentRoundEngine(
      {required AgentRuntimeConfigResolver configResolver,
      required AgentProviderFactory providerFactory,
      required AgentToolExecutor tools,
      required AgentRuntimeLimits limits})
      : _configResolver = configResolver,
        _providerFactory = providerFactory,
        _tools = tools,
        _limits = limits;
  final AgentRuntimeConfigResolver _configResolver;
  final AgentProviderFactory _providerFactory;
  final AgentToolExecutor _tools;
  final AgentRuntimeLimits _limits;
  final ProviderRoundGateway _gateway = const ProviderRoundGateway();

  Future<String> _run(_ActiveTurn turn,
      {required ConversationThreadSlice slice,
      required String conversationId,
      required String userMessageId,
      RetrievalEgressApproval? approval}) async {
    final seenCallIds = <String>{};
    final resolved = await _resolveConfig();
    LogWriter.info(
      'Agent configuration resolved',
      module: 'Agent',
      data: const <String, Object?>{'stage': 'config_resolved'},
    );
    _throwIfExpired(turn);
    var currentResolved = resolved;
    var provider = _providerFactory(currentResolved);
    var capabilities = provider.capabilities;
    if (currentResolved.config.webEnabled && !capabilities.nativeWebSearch) {
      throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
    }
    if (!capabilities.functionTools) {
      throw const _TurnFailure(AgentTurnFailure.unsupportedCapability);
    }

    turn.transcript!.initializeHistory(AgentHistoryBuilder(limits: _limits)
        .build(slice: slice, targetMessageId: userMessageId));
    final approvedIds = approval?.approvedFileIds ?? const <String>[];
    final hasRetrievalApproval = approvedIds.isNotEmpty;
    final fileIds = _tools.effectiveFileIds;
    final currentFileIds = fileIds == null || !hasRetrievalApproval
        ? const <String>[]
        : await fileIds(
            scope: slice.conversation.scope,
            conversationFileIds:
                slice.files.map((file) => file.fileId).toList(growable: false),
          );
    final retrievalGrant = hasRetrievalApproval &&
            approvedIds.every(currentFileIds.contains) &&
            fileIds != null
        ? RetrievalEgressGrant(
            agentTurnRequestId: turn.requestId,
            conversationId: conversationId,
            sourceUserMessageId: userMessageId,
            providerProfileId: resolved.profile.profileId,
            approvedFileIds: approvedIds,
          )
        : null;
    final trusted = _AgentToolContext(
        conversationId: conversationId,
        userMessageId: userMessageId,
        scope: slice.conversation.scope,
        providerProfileId: resolved.profile.profileId,
        grant: retrievalGrant);
    final systemPrompt = _tools.buildPrompt(
        scope: slice.conversation.scope,
        files: slice.files,
        grant: retrievalGrant);
    var toolPhaseClosed = false;
    final baseTools = _tools.definitions(retrievalGrant);

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
          serializationAllowed = await _tools
              ._retrievalSerializationAllowed(
                turn,
                conversationId: conversationId,
                userMessageId: userMessageId,
                providerProfileId: resolved.profile.profileId,
                grant: retrievalGrant,
              )
              .timeout(remaining);
        } on TimeoutException {
          throw const _TurnTimeoutException();
        }
        if (!serializationAllowed) {
          for (final callId in retrievalOutputCallIds) {
            turn.transcript!
                .denyRelease(callId, _tools.retrievalAccessDeniedOutput());
          }
          toolOutputs = <AgentFunctionToolOutput>[
            for (final output in toolOutputs)
              AgentFunctionToolOutput(
                callId: output.callId,
                output: retrievalOutputCallIds.contains(output.callId)
                    ? _tools.retrievalAccessDeniedOutput()
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
        messages: turn.transcript!.providerPersistedHistory,
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
      try {
        round = await _runProviderRound(turn, provider, request);
      } catch (error) {
        if (turn.policy._canFallback(
          turn: turn,
          resolved: resolved,
          hasRetrievalApproval: hasRetrievalApproval,
          retrievalGrant: retrievalGrant,
          error: error,
        )) {
          turn.policy.fallbackAttempted = true;
          LogWriter.info(
            'Agent provider fallback attempted',
            module: 'Agent',
            data: <String, Object?>{
              'stage': 'fallback_attempted',
              'fallbackReason': AgentTurnPolicy.fallbackReasonOf(error),
              'providerRound': turn.policy.providerAttempts,
            },
          );
          currentResolved = ResolvedAgentConfig(
            config: resolved.config,
            profile: resolved.fallbackProfile!,
          );
          provider = _providerFactory(currentResolved);
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
      turn.policy.providerRounds++;
      _throwIfCancelled(turn);
      if (round.functionCalls.isEmpty) {
        final finalText = turn.visibleText.toString();
        if (finalText.trim().isEmpty) {
          throw const _TurnFailure(AgentTurnFailure.providerMalformed);
        }
        _throwIfExpired(turn);
        _throwIfCancelled(turn);
        turn.transcript!.recordFinalAssistant(finalText);
        return finalText;
      }

      if (toolPhaseClosed) {
        throw const _TurnFailure(AgentTurnFailure.providerMalformed);
      }

      final continuation = round.continuationState;
      if (continuation == null) {
        throw const _TurnFailure(AgentTurnFailure.providerMalformed);
      }
      for (final call in round.functionCalls) {
        if (!seenCallIds.add(call.callId)) {
          throw const _TurnFailure(AgentTurnFailure.providerMalformed);
        }
      }

      final budgetExhaustedReason =
          turn.policy.rejectBatchReason(round.functionCalls.length);
      if (budgetExhaustedReason != null) {
        toolPhaseClosed = true;
        LogWriter.info(
          'Tool budget exhausted, closing tool phase',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_phase_closed',
            'reason': budgetExhaustedReason,
            'toolRoundsUsed': turn.policy.toolRoundsUsed,
            'localCallsUsed': turn.policy.localCallsUsed,
            'requestedCalls': round.functionCalls.length,
          },
        );
        continuationState = continuation;
        final rejected = <AgentToolGroup>[
          for (final call in round.functionCalls)
            _group(call, _tools._rejectBudget(turn, call, trusted)),
        ];
        turn.transcript!.recordCompletedAssistant(round.visibleText);
        turn.transcript!.recordToolRound(rejected);
        toolOutputs =
            rejected.map((group) => group.result).toList(growable: false);
        retrievalOutputCallIds = const <String>{};
        continue;
      }

      turn.policy.toolRoundsUsed++;

      turn.transcript!.recordCompletedAssistant(round.visibleText);
      final groups = <AgentToolGroup>[];
      final outputs = <AgentFunctionToolOutput>[];
      final nextRetrievalOutputCallIds = <String>{};
      try {
        for (final call in round.functionCalls) {
          _throwIfCancelled(turn);
          _emit(turn, AgentTurnToolCall(callId: call.callId, name: call.name));
          final toolStopwatch = Stopwatch()..start();
          final safeCallId = AgentToolExecutor.safeCallId(call.callId);
          final safeToolName = AgentToolExecutor.safeToolName(call.name);
          LogWriter.info(
            'Tool call started',
            module: 'Agent',
            data: <String, Object?>{
              'stage': 'tool_call_started',
              'toolName': safeToolName,
              'callId': safeCallId,
            },
          );
          final execution = await _tools._execute(turn, call, trusted);
          final dispatch = execution.dispatch;
          final output = dispatch.json;
          final toolStatus = AgentToolExecutor.toolCallStatus(output);
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
          turn.policy.toolCallsCount++;
          turn.policy.lastToolName = safeToolName;
          turn.policy.localCallsUsed++;
          if (dispatch.receipt.status ==
              CapabilityExecutionStatus.outcomeUnknown) {
            turn.transcript!.recordUnresolved(call, dispatch.receipt);
            _throwIfReceiptDeadlineExpired(dispatch.receipt);
            _throwIfExpired(turn);
            _throwIfCancelled(turn);
            throw const _TurnFailure(AgentTurnFailure.internalError);
          }
          groups.add(_group(call, dispatch, execution.egress));
          _throwIfReceiptDeadlineExpired(dispatch.receipt);
          _throwIfExpired(turn);
          _throwIfCancelled(turn);
          outputs.add(
            AgentFunctionToolOutput(callId: call.callId, output: output),
          );
          if (execution.egress != null) {
            nextRetrievalOutputCallIds.add(call.callId);
          }
        }
      } catch (_) {
        turn.transcript!.recordToolRound(groups);
        rethrow;
      }
      turn.transcript!.recordToolRound(groups);
      continuationState = continuation;
      toolOutputs = outputs;
      retrievalOutputCallIds = nextRetrievalOutputCallIds;

      if (turn.policy.toolPhaseShouldClose) {
        toolPhaseClosed = true;
        final budgetExhaustedReason =
            turn.policy.toolRoundsUsed >= _limits.maxToolRounds
                ? 'tool_round_limit_exceeded'
                : 'local_call_limit_exceeded';
        LogWriter.info(
          'Tool budget exhausted, closing tool phase',
          module: 'Agent',
          data: <String, Object?>{
            'stage': 'tool_phase_closed',
            'reason': budgetExhaustedReason,
            'toolRoundsUsed': turn.policy.toolRoundsUsed,
            'localCallsUsed': turn.policy.localCallsUsed,
          },
        );
      }
    }
  }

  /// The Kernel uses the same trusted deadline. Its timer may settle before
  /// Coordinator's timer callback; this evidence still means turn timeout and
  /// never changes the handler's already recorded status/effect.
  void _throwIfReceiptDeadlineExpired(ExecutionReceipt receipt) {
    if (receipt.failure == CapabilityFailure.deadlineExceeded) {
      throw const _TurnTimeoutException();
    }
  }

  AgentToolGroup _group(
          AgentProviderFunctionCall call, AgentToolDispatchResult dispatch,
          [AgentToolEgressMetadata? egress]) =>
      AgentToolGroup(
          call: call,
          result: AgentFunctionToolOutput(
              callId: call.callId, output: dispatch.json),
          receipt: dispatch.receipt,
          egress: egress);

  Future<_ProviderRound> _runProviderRound(
    _ActiveTurn turn,
    AgentProviderPort provider,
    AgentProviderRequest request,
  ) async {
    final gateway = await _gateway.invoke(
      provider: provider,
      request: request,
      cancellationToken: turn.cancellation.token,
      remainingBudget: turn.remainingBudget(),
      providerRound: ++turn.policy.providerAttempts,
      isTurnTimedOut: () => turn.timedOut,
      onText: (text) {
        turn.visibleText.write(text);
        _emit(turn, AgentTurnTextDelta(text));
      },
      onWebSearch: (phase) {
        turn.policy.webProgressEmitted = true;
        _emit(turn, AgentTurnWebSearchEvent(phase));
      },
    );
    final result = gateway.result;
    if (result.failure case final failure?) throw failure;
    return _ProviderRound(
      visibleText: gateway.visibleText,
      functionCalls: result.functionCalls,
      continuationState: result.continuationState,
    );
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
}

final class _ProviderRound {
  const _ProviderRound({
    required this.functionCalls,
    required this.visibleText,
    required this.continuationState,
  });

  final String visibleText;
  final List<AgentProviderFunctionCall> functionCalls;
  final AgentProviderContinuationState? continuationState;
}
