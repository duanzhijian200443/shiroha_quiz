part of 'agent_runtime.dart';

final class AgentTurnPolicy {
  AgentTurnPolicy({required this.limits, required this.cancellation})
      : deadline = DateTime.now().add(limits.turnTimeout) {
    _stopwatch.start();
  }
  final AgentRuntimeLimits limits;
  final AgentCancellationToken cancellation;
  final DateTime deadline;
  final Stopwatch _stopwatch = Stopwatch();
  int toolRoundsUsed = 0;
  int localCallsUsed = 0;
  int providerRounds = 0;
  int providerAttempts = 0;
  int toolCallsCount = 0;
  String? lastToolName;
  bool fallbackAttempted = false;
  bool webProgressEmitted = false;
  bool proposalStaged = false;
  bool studyPlanDraftStaged = false;
  int get elapsedMilliseconds => _stopwatch.elapsedMilliseconds;
  Duration remainingBudget() => _stopwatch.elapsed >= limits.turnTimeout
      ? Duration.zero
      : limits.turnTimeout - _stopwatch.elapsed;
  String? rejectBatchReason(int requestedCalls) {
    if (toolRoundsUsed >= limits.maxToolRounds) {
      return 'tool_round_limit_exceeded';
    }
    if (localCallsUsed + requestedCalls > limits.maxLocalCalls) {
      return 'local_call_limit_exceeded';
    }
    return null;
  }

  bool get toolPhaseShouldClose =>
      toolRoundsUsed >= limits.maxToolRounds ||
      localCallsUsed >= limits.maxLocalCalls;

  static String fallbackReasonOf(Object error) =>
      error is AgentProviderException ? error.failure.name : 'unknown';

  bool _canFallback({
    required _ActiveTurn turn,
    required ResolvedAgentConfig resolved,
    required bool hasRetrievalApproval,
    required RetrievalEgressGrant? retrievalGrant,
    required Object error,
  }) {
    if (resolved.fallbackProfile == null ||
        turn.policy.fallbackAttempted ||
        turn.cancellation.token.isCancelled ||
        turn.timedOut ||
        turn.remainingBudget() <= Duration.zero ||
        turn.visibleText.isNotEmpty ||
        turn.policy.webProgressEmitted ||
        turn.policy.localCallsUsed > 0 ||
        turn.policy.toolRoundsUsed > 0 ||
        turn.policy.proposalStaged ||
        turn.policy.studyPlanDraftStaged ||
        hasRetrievalApproval ||
        retrievalGrant != null) {
      return false;
    }
    return _isEligibleProviderFailure(error);
  }

  static bool _isEligibleProviderFailure(Object error) {
    if (error is! AgentProviderException || !error.legacyFallbackAllowed) {
      return false;
    }
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
}

void _throwIfExpired(_ActiveTurn turn) {
  if (turn.remainingBudget() <= Duration.zero) {
    throw const _TurnTimeoutException();
  }
}

void _throwIfCancelled(_ActiveTurn turn) {
  turn.cancellation.token.throwIfCancelled();
}

final class _TurnFailure implements Exception {
  const _TurnFailure(this.failure);

  final AgentTurnFailure failure;
}

final class _TurnTimeoutException implements Exception {
  const _TurnTimeoutException();
}
