import '../../application/ai_config/ai_config_ports.dart';
import '../../domain/ai_config/ai_config_contracts.dart';
import 'deepseek_responses_transport_contract.dart';

final class DeepSeekAgentModelCompatibilityAdapter
    implements AgentTransportCompatibilityPort {
  const DeepSeekAgentModelCompatibilityAdapter();

  @override
  AgentTransportCompatibilityResult evaluate({
    required String transportProviderKind,
    required AiProviderKind? modelProviderKind,
    required String canonicalModelId,
    required Map<AiModelCapability, AiCapabilitySupport> capabilities,
  }) {
    if (transportProviderKind != 'deepseek_responses' ||
        modelProviderKind != AiProviderKind.deepseek) {
      return const AgentTransportCompatibilityResult.incompatible(
        'transportUnsupportedProvider',
      );
    }
    if (!DeepSeekResponsesTransportContract.supportsModel(canonicalModelId)) {
      return const AgentTransportCompatibilityResult.incompatible(
        'transportUnsupportedModel',
      );
    }
    for (final required in const <AiModelCapability>{
      AiModelCapability.textInput,
      AiModelCapability.textOutput,
      AiModelCapability.toolCalling,
    }) {
      final support = capabilities[required] ?? AiCapabilitySupport.unknown;
      if (support != AiCapabilitySupport.supported) {
        return AgentTransportCompatibilityResult.incompatible(
          support == AiCapabilitySupport.unsupported
              ? 'capabilityUnsupported:${required.storageValue}'
              : 'capabilityUnknown:${required.storageValue}',
        );
      }
    }
    return const AgentTransportCompatibilityResult.compatible();
  }
}
