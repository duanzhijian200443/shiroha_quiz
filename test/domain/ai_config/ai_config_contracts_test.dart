import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/domain/ai_config/shiroha_capability_registry.dart';

void main() {
  test('slot requirements are explicit capability sets', () {
    expect(
      AiCapabilitySlot.textModel.requiredCapabilities,
      <AiModelCapability>{
        AiModelCapability.textInput,
        AiModelCapability.textOutput,
      },
    );
    expect(
      AiCapabilitySlot.imageUnderstanding.requiredCapabilities,
      containsAll(<AiModelCapability>{
        AiModelCapability.textInput,
        AiModelCapability.imageInput,
        AiModelCapability.textOutput,
      }),
    );
    expect(
      AiCapabilitySlot.documentRecognition.requiredCapabilities,
      <AiModelCapability>{
        AiModelCapability.ocr,
        AiModelCapability.textOutput,
      },
    );
  });

  test('capability source priority is frozen', () {
    expect(
      AiCapabilityClaimSource.values.map((source) => source.priority),
      <int>[0, 1, 2, 3],
    );
  });

  test('canonical model ids are case-sensitive and never trimmed', () {
    expect(validateCanonicalModelId('Model-A'), 'Model-A');
    expect(validateCanonicalModelId('model-a'), 'model-a');
    expect(
      () => validateCanonicalModelId(' model-a'),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.invalidInput,
        ),
      ),
    );
  });

  test('official evidence overrides exact registry and user evidence', () {
    final resolved = resolveModelCapabilities(
      providerKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-v4-flash',
      claims: <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'model-ref',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.providerOfficial,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
        AiCapabilityClaim(
          modelRef: 'model-ref',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.userDeclaration,
          support: AiCapabilitySupport.supported,
          assertedAt: 1,
        ),
      ],
    );
    expect(
      resolved[AiModelCapability.textInput],
      AiCapabilitySupport.unsupported,
    );
  });

  test('same-source capability conflict is dataCorrupt', () {
    expect(
      () => resolveModelCapabilities(
        providerKind: AiProviderKind.openAiCompatible,
        canonicalModelId: 'exact-model',
        claims: <AiCapabilityClaim>[
          AiCapabilityClaim(
            modelRef: 'model-ref',
            capability: AiModelCapability.textInput,
            source: AiCapabilityClaimSource.userDeclaration,
            support: AiCapabilitySupport.supported,
            assertedAt: 1,
          ),
          AiCapabilityClaim(
            modelRef: 'model-ref',
            capability: AiModelCapability.textInput,
            source: AiCapabilityClaimSource.userDeclaration,
            support: AiCapabilitySupport.unsupported,
            assertedAt: 2,
          ),
        ],
      ),
      throwsA(
        isA<AiConfigException>().having(
          (error) => error.failure,
          'failure',
          AiConfigFailure.dataCorrupt,
        ),
      ),
    );
  });
}
