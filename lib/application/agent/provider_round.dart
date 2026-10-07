import 'dart:async';

import '../../core/observability/log_writer.dart';
import 'agent_provider.dart';

enum ProviderRoundOutcome {
  completed,
  toolCallsRequested,
  incomplete,
  failed,
  cancelled
}

/// One settled round. Failed calls are counted for diagnostics, never executable.
final class ProviderRoundResult {
  ProviderRoundResult({
    required this.outcome,
    this.failure,
    List<AgentProviderFunctionCall> functionCalls = const [],
    this.continuationState,
  }) : functionCalls = List.unmodifiable(functionCalls);

  final ProviderRoundOutcome outcome;
  final AgentProviderException? failure;
  final List<AgentProviderFunctionCall> functionCalls;
  final AgentProviderContinuationState? continuationState;
}

/// Protocol-neutral settlement; the caller keeps turn policy and persistence.
Future<ProviderRoundResult> normalizeProviderRound({
  required AgentProviderPort provider,
  required AgentProviderRequest request,
  required AgentCancellationToken cancellationToken,
  required Duration remainingBudget,
  required int providerRound,
  required void Function(String) onText,
  required void Function(AgentProviderWebSearchPhase) onWebSearch,
  required bool Function() isTurnTimedOut,
}) async {
  final stopwatch = Stopwatch()..start();
  final adapterIdentity = provider.capabilities.adapterIdentity.name;
  final done = Completer<ProviderRoundResult>();
  final calls = <AgentProviderFunctionCall>[];
  AgentProviderContinuationState? state;
  AgentProviderException? terminalFailure;
  var terminalSeen = false;
  var visibleCharacterCount = 0;
  StreamSubscription<AgentProviderEvent>? subscription;

  void finish(ProviderRoundResult result) {
    if (!done.isCompleted) done.complete(result);
  }

  void fail(AgentProviderException error) {
    terminalSeen = terminalSeen || error.terminalSeen;
    finish(ProviderRoundResult(
      outcome: error.failure == AgentProviderFailure.cancelled
          ? ProviderRoundOutcome.cancelled
          : error.safeCode?.boundary == ProviderFailureBoundary.incomplete
              ? ProviderRoundOutcome.incomplete
              : ProviderRoundOutcome.failed,
      failure: error,
    ));
  }

  void stopForCancellation() {
    fail(isTurnTimedOut()
        ? const AgentProviderException.detailed(
            ProviderFailureCode.streamTimeout,
            legacyFailure: AgentProviderFailure.timeout,
          )
        : const AgentProviderException(AgentProviderFailure.cancelled));
  }

  LogWriter.info('Provider round started', module: 'Agent', data: {
    'stage': 'provider_round_started',
    'providerRound': providerRound,
  });
  final timer = Timer(remainingBudget, () {
    fail(const AgentProviderException.detailed(
      ProviderFailureCode.streamTimeout,
      legacyFailure: AgentProviderFailure.timeout,
    ));
  });
  unawaited(cancellationToken.whenCancelled.then((_) {
    if (!done.isCompleted) stopForCancellation();
  }));

  try {
    if (cancellationToken.isCancelled) {
      stopForCancellation();
    } else if (remainingBudget <= Duration.zero) {
      fail(const AgentProviderException.detailed(
        ProviderFailureCode.streamTimeout,
        legacyFailure: AgentProviderFailure.timeout,
      ));
    } else {
      subscription =
          provider.stream(request, cancellationToken).listen((event) {
        if (done.isCompleted) return;
        try {
          cancellationToken.throwIfCancelled();
          if (terminalSeen) {
            throw AgentProviderException.detailed(
              event is AgentProviderCompleted ||
                      event is AgentProviderFailureTerminal
                  ? ProviderFailureCode.duplicateTerminal
                  : ProviderFailureCode.malformedEvent,
              terminalSeen: true,
            );
          }
          switch (event) {
            case AgentProviderTextDelta(:final text):
              visibleCharacterCount += text.runes.length;
              onText(text);
            case AgentProviderFunctionCall():
              calls.add(event);
            case AgentProviderWebSearchEvent(:final phase):
              onWebSearch(phase);
            case AgentProviderCompleted(:final continuationState):
              terminalSeen = true;
              state = continuationState;
            case AgentProviderFailureTerminal(:final failure):
              terminalSeen = true;
              terminalFailure = failure;
          }
        } catch (error) {
          if (error is AgentProviderException) {
            fail(error);
          } else {
            fail(_untypedFailure(error));
          }
        }
      }, onError: (Object error) {
        if (done.isCompleted) return;
        if (cancellationToken.isCancelled) {
          stopForCancellation();
        } else {
          fail(
              error is AgentProviderException ? error : _untypedFailure(error));
        }
      }, onDone: () {
        if (done.isCompleted) return;
        if (cancellationToken.isCancelled) {
          stopForCancellation();
        } else if (terminalFailure case final failure?) {
          fail(failure);
        } else if (!terminalSeen) {
          fail(const AgentProviderException.detailed(
            ProviderFailureCode.cleanEofWithoutTerminal,
            legacyFailure: AgentProviderFailure.incompleteResponse,
          ));
        } else {
          finish(ProviderRoundResult(
            outcome: calls.isEmpty
                ? ProviderRoundOutcome.completed
                : ProviderRoundOutcome.toolCallsRequested,
            functionCalls: calls,
            continuationState: state,
          ));
        }
      });
    }
  } catch (error) {
    fail(error is AgentProviderException ? error : _untypedFailure(error));
  }

  final result = await done.future;
  timer.cancel();
  // A broken adapter may never finish cancellation; settlement must not wait on it.
  final activeSubscription = subscription;
  if (activeSubscription != null) {
    unawaited(activeSubscription.cancel().catchError((Object _) {}));
  }
  final code = result.failure?.safeCode;
  LogWriter.info('Provider round completed', module: 'Agent', data: {
    'stage': 'provider_round_completed',
    'providerRound': providerRound,
    'adapterIdentity': adapterIdentity,
    'outcome': result.outcome.name,
    if (code != null) 'failureBoundary': code.boundary.code,
    if (code != null) 'failureCode': code.code,
    'durationMs': stopwatch.elapsedMilliseconds,
    'terminalSeen': terminalSeen,
    'completeCallCount': calls.length,
    'functionCallCount': calls.length,
    'visibleCharacterCount': visibleCharacterCount,
    'status': result.failure == null ? 'success' : result.outcome.name,
  });
  return result;
}

AgentProviderException _untypedFailure(Object error) =>
    error is TimeoutException
        ? const AgentProviderException.detailed(
            ProviderFailureCode.streamTimeout,
            legacyFailure: AgentProviderFailure.timeout,
            legacyFallbackAllowed: false)
        : const AgentProviderException.detailed(
            ProviderFailureCode.adapterInternalError,
            legacyFallbackAllowed: false);
