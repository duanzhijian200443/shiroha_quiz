part of 'agent_runtime.dart';

/// Runtime boundary around R1 settlement, with successful visible text only.
final class ProviderRoundGateway {
  const ProviderRoundGateway();
  Future<({ProviderRoundResult result, String visibleText})> invoke({
    required AgentProviderPort provider,
    required AgentProviderRequest request,
    required AgentCancellationToken cancellationToken,
    required Duration remainingBudget,
    required int providerRound,
    required bool Function() isTurnTimedOut,
    required void Function(String) onText,
    required void Function(AgentProviderWebSearchPhase) onWebSearch,
  }) async {
    final visible = StringBuffer();
    final result = await normalizeProviderRound(
        provider: provider,
        request: request,
        cancellationToken: cancellationToken,
        remainingBudget: remainingBudget,
        providerRound: providerRound,
        isTurnTimedOut: isTurnTimedOut,
        onText: (text) {
          visible.write(text);
          onText(text);
        },
        onWebSearch: onWebSearch);
    return (
      result: result,
      visibleText: result.failure == null ? visible.toString() : ''
    );
  }
}
