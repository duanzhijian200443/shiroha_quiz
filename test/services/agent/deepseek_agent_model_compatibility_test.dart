import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/services/agent/deepseek_agent_model_compatibility_adapter.dart';

void main() {
  const compatibility = DeepSeekAgentModelCompatibilityAdapter();

  Map<AiModelCapability, AiCapabilitySupport> agentClaims() => const {
        AiModelCapability.textInput: AiCapabilitySupport.supported,
        AiModelCapability.textOutput: AiCapabilitySupport.supported,
        AiModelCapability.toolCalling: AiCapabilitySupport.supported,
      };

  test('transport accepts the official current exact model ids', () {
    for (final currentModelId in const <String>[
      'deepseek-flash',
      'deepseek-v4-pro',
    ]) {
      expect(
        compatibility
            .evaluate(
              transportProviderKind: 'deepseek_responses',
              modelProviderKind: AiProviderKind.deepseek,
              canonicalModelId: currentModelId,
              capabilities: agentClaims(),
            )
            .compatible,
        isTrue,
        reason: currentModelId,
      );
    }
    // Retired alias: legacy compatibility for historical bindings only.
    expect(
      compatibility
          .evaluate(
            transportProviderKind: 'deepseek_responses',
            modelProviderKind: AiProviderKind.deepseek,
            canonicalModelId: 'deepseek-v4-flash',
            capabilities: agentClaims(),
          )
          .compatible,
      isTrue,
    );
  });

  test('near-matches and unknown ids never inherit eligibility', () {
    for (final nearMatch in const <String>[
      'deepseek-flash-extra',
      'deepseek-flashx',
      'deepseek-chat',
      'deepseek-v4-pro-max',
    ]) {
      final rejected = compatibility.evaluate(
        transportProviderKind: 'deepseek_responses',
        modelProviderKind: AiProviderKind.deepseek,
        canonicalModelId: nearMatch,
        capabilities: agentClaims(),
      );
      expect(rejected.compatible, isFalse, reason: nearMatch);
      expect(
        rejected.reasonCode,
        'transportUnsupportedModel',
        reason: nearMatch,
      );
    }
  });

  test('unknown or unsupported tool calling fails closed', () {
    // Missing required evidence reports the first unknown required capability.
    final unknownToolCalling = compatibility.evaluate(
      transportProviderKind: 'deepseek_responses',
      modelProviderKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-flash',
      capabilities: const {},
    );
    expect(unknownToolCalling.compatible, isFalse);
    expect(unknownToolCalling.reasonCode, 'capabilityUnknown:textInput');

    final unknownToolCallingOnly = compatibility.evaluate(
      transportProviderKind: 'deepseek_responses',
      modelProviderKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-flash',
      capabilities: const {
        AiModelCapability.textInput: AiCapabilitySupport.supported,
        AiModelCapability.textOutput: AiCapabilitySupport.supported,
      },
    );
    expect(unknownToolCallingOnly.compatible, isFalse);
    expect(unknownToolCallingOnly.reasonCode, 'capabilityUnknown:toolCalling');

    final unsupportedToolCalling = compatibility.evaluate(
      transportProviderKind: 'deepseek_responses',
      modelProviderKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-flash',
      capabilities: const {
        AiModelCapability.textInput: AiCapabilitySupport.supported,
        AiModelCapability.textOutput: AiCapabilitySupport.supported,
        AiModelCapability.toolCalling: AiCapabilitySupport.unsupported,
      },
    );
    expect(unsupportedToolCalling.compatible, isFalse);
    expect(
      unsupportedToolCalling.reasonCode,
      'capabilityUnsupported:toolCalling',
    );
  });

  test('wrong provider transport is rejected', () {
    final wrongProvider = compatibility.evaluate(
      transportProviderKind: 'deepseek_responses',
      modelProviderKind: AiProviderKind.openAiCompatible,
      canonicalModelId: 'deepseek-flash',
      capabilities: agentClaims(),
    );
    expect(wrongProvider.compatible, isFalse);
    expect(wrongProvider.reasonCode, 'transportUnsupportedProvider');
  });

  test('settings expose incompatible model before runtime and reject save',
      () async {
    final store = _ConfigStore();
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: _Catalog(<AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'supported',
          displayName: 'Supported',
          modelName: 'deepseek-v4-flash',
          modelProviderKind: AiProviderKind.deepseek,
          capabilities: const {
            AiModelCapability.textInput: AiCapabilitySupport.supported,
            AiModelCapability.textOutput: AiCapabilitySupport.supported,
            AiModelCapability.toolCalling: AiCapabilitySupport.supported,
          },
        ),
        AgentProfileSummary(
          profileId: 'unsupported',
          displayName: 'Unsupported',
          modelName: 'deepseek-flash',
          modelProviderKind: AiProviderKind.deepseek,
        ),
      ]),
      transportCompatibility: compatibility,
    );

    final snapshot = await service.load();
    expect(snapshot.availableProfiles.single.profileId, 'supported');
    expect(snapshot.incompatibleProfiles.single.profileId, 'unsupported');
    expect(
      snapshot.incompatibilityReasons['unsupported'],
      'capabilityUnknown:textInput',
    );

    await expectLater(
      service.save(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'unsupported',
        ),
      ),
      throwsA(
        isA<AgentConfigException>().having(
          (error) => error.failure,
          'failure',
          AgentConfigFailure.profileNotFound,
        ),
      ),
    );
    expect(store.encoded, isNull);
  });

  test('runtime resolver drops an incompatible stored fallback', () async {
    final store = _ConfigStore()
      ..encoded = const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'supported',
          fallbackProfileId: 'unsupported',
        ),
      );
    final resolver = AgentRuntimeConfigResolver(
      configStore: store,
      profileResolver: _ProfileResolver(<String, AgentProviderProfile>{
        'supported': AgentProviderProfile(
          profileId: 'supported',
          apiKey: 'secret',
          baseUrl: 'https://api.deepseek.com',
          modelName: 'deepseek-v4-flash',
          modelProviderKind: AiProviderKind.deepseek,
          capabilities: const {
            AiModelCapability.textInput: AiCapabilitySupport.supported,
            AiModelCapability.textOutput: AiCapabilitySupport.supported,
            AiModelCapability.toolCalling: AiCapabilitySupport.supported,
          },
        ),
        'unsupported': AgentProviderProfile(
          profileId: 'unsupported',
          apiKey: 'secret',
          baseUrl: 'https://api.deepseek.com',
          modelName: 'deepseek-flash',
          modelProviderKind: AiProviderKind.deepseek,
        ),
      }),
      transportCompatibility: compatibility,
    );

    final resolved = await resolver.resolve();
    expect(resolved.profile.profileId, 'supported');
    expect(resolved.fallbackProfile, isNull);
  });
}

final class _Catalog implements AgentProfileCatalogPort {
  const _Catalog(this.profiles);
  final List<AgentProfileSummary> profiles;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async => profiles;
}

final class _ConfigStore implements AgentConfigStorePort {
  String? encoded;

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _ProfileResolver implements AgentProviderProfileResolverPort {
  const _ProfileResolver(this.profiles);

  final Map<String, AgentProviderProfile> profiles;

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async =>
      profiles[profileId];
}
