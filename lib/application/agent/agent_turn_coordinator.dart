part of 'agent_runtime.dart';

final class AgentTurnCoordinator {
  AgentTurnCoordinator(
      {required ConversationService conversationService,
      required AgentRuntimeConfigResolver configResolver,
      required AgentProviderFactory providerFactory,
      required AgentStudyToolDispatcher toolDispatcher,
      AgentWriteProposalToolDispatcher? proposalDispatcher,
      AgentStudyPlanToolDispatcher? studyPlanDispatcher,
      AgentRetrievalToolDispatcher? retrievalDispatcher,
      AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _limits = limits {
    _finalizer = AgentTurnFinalizer(conversationService, limits);
    final tools = AgentToolExecutor(
        conversationService: conversationService,
        configResolver: configResolver,
        toolDispatcher: toolDispatcher,
        proposalDispatcher: proposalDispatcher,
        studyPlanDispatcher: studyPlanDispatcher,
        retrievalDispatcher: retrievalDispatcher,
        limits: limits);
    _engine = AgentRoundEngine(
        configResolver: configResolver,
        providerFactory: providerFactory,
        tools: tools,
        limits: limits);
  }
  final AgentRuntimeLimits _limits;
  late final AgentTurnFinalizer _finalizer;
  late final AgentRoundEngine _engine;
  final Set<String> _activeConversations = {};
  int _turnRequestSequence = 0;

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
      transcriptReader: () =>
          turn.transcript?.snapshot ?? turn.terminalTranscript,
    );
    unawaited(
      _runTurn(
        turn,
        conversationId: conversationId,
        userMessageId: userMessageId,
        approval: approval,
      ).whenComplete(() {
        turn.transcript?.clear();
        turn.transcript = null;
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
          turn.terminalTranscript = turn.transcript?.snapshot;
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
          turn.terminalTranscript = turn.transcript?.snapshot;
          final failure = _mapFailure(error, turn);
          _logTerminalTurnFailure(turn, error, failure);
          final summary = DiagnosticSummary(
            diagnosticId: turn.correlationId,
            operation: 'agent_turn',
            failure: failure.name,
            providerRounds: turn.policy.providerRounds,
            toolCalls: turn.policy.toolCallsCount,
            lastTool: turn.policy.lastToolName,
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

  Future<AgentTurnResult> _executeTurn(_ActiveTurn turn,
      {required String conversationId,
      required String userMessageId,
      RetrievalEgressApproval? approval}) async {
    final prepared = await _finalizer._prepareTarget(turn,
        conversationId: conversationId, userMessageId: userMessageId);
    if (prepared.existingAssistant case final existing?) {
      return AgentTurnAlreadyCompleted(assistantMessage: existing);
    }
    final resumed = await _finalizer._resumePending(turn, prepared.target);
    if (resumed != null) return AgentTurnSuccess(assistantMessage: resumed);
    final transcript =
        AgentTurnTranscript(targetMessageId: userMessageId, limits: _limits);
    turn.transcript = transcript;
    final finalText = await _engine._run(turn,
        slice: prepared.slice,
        conversationId: conversationId,
        userMessageId: userMessageId,
        approval: approval);
    return _finalizer._finalize(turn, prepared.target, finalText);
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
    if (error is AgentTranscriptException) {
      return switch (error.failure) {
        AgentTranscriptFailure.targetMissing => AgentTurnFailure.invalidTarget,
        AgentTranscriptFailure.minimumContextTooLarge =>
          AgentTurnFailure.historyLimitExceeded,
      };
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
        'providerRounds': turn.policy.providerRounds,
        'toolCalls': turn.policy.toolCallsCount,
        'toolRoundsUsed': turn.policy.toolRoundsUsed,
        'localCallsUsed': turn.policy.localCallsUsed,
        'durationMs': turn.elapsedMilliseconds,
      },
    );
  }

  static bool _isBoundedId(String value) {
    final length = value.runes.length;
    return length >= 1 && length <= 128 && !value.contains("\u0000");
  }
}

final class _ActiveTurn {
  _ActiveTurn({
    required AgentRuntimeLimits limits,
    required this.requestId,
    required this.correlationId,
    required this.traceId,
    required this.mutationLease,
  }) {
    policy = AgentTurnPolicy(limits: limits, cancellation: cancellation.token);
  }

  late final AgentTurnPolicy policy;
  AgentTurnTranscript? transcript;
  AgentTurnTranscriptSnapshot? terminalTranscript;
  final String requestId;

  /// OBS-1 root operation identity of this turn.
  final String correlationId;
  final String traceId;
  final BackupRestoreMutationLease mutationLease;

  final AgentCancellationController cancellation =
      AgentCancellationController();
  final StreamController<AgentTurnEvent> events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> result = Completer<AgentTurnResult>();
  late final Timer timeoutTimer;
  var timedOut = false;
  final StringBuffer visibleText = StringBuffer();

  int get elapsedMilliseconds => policy.elapsedMilliseconds;
  Duration remainingBudget() => policy.remainingBudget();
}

void _emit(_ActiveTurn turn, AgentTurnEvent event) {
  if (turn.events.isClosed) return;
  turn.events.add(event);
}
