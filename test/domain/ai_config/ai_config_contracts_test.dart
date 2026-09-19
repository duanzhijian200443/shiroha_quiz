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

    final overrideOnNewEntry = resolveModelCapabilities(
      providerKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-flash',
      claims: <AiCapabilityClaim>[
        AiCapabilityClaim(
          modelRef: 'model-ref',
          capability: AiModelCapability.textInput,
          source: AiCapabilityClaimSource.providerOfficial,
          support: AiCapabilitySupport.unsupported,
          assertedAt: 1,
        ),
      ],
    );
    expect(
      overrideOnNewEntry[AiModelCapability.textInput],
      AiCapabilitySupport.unsupported,
    );
  });

  test('exact registry entries carry verified text evidence only', () {
    for (final entry in const <(AiProviderKind, String)>[
      (AiProviderKind.deepseek, 'deepseek-flash'),
      (AiProviderKind.zhipu, 'glm-5.3'),
    ]) {
      final resolved = resolveModelCapabilities(
        providerKind: entry.$1,
        canonicalModelId: entry.$2,
        claims: const <AiCapabilityClaim>[],
      );
      expect(
        resolved[AiModelCapability.textInput],
        AiCapabilitySupport.supported,
        reason: '${entry.$1} / ${entry.$2}',
      );
      expect(
        resolved[AiModelCapability.textOutput],
        AiCapabilitySupport.supported,
        reason: '${entry.$1} / ${entry.$2}',
      );
      expect(
        resolved[AiModelCapability.imageInput],
        AiCapabilitySupport.unknown,
        reason: '${entry.$1} / ${entry.$2} must not declare vision',
      );
      expect(
        resolved[AiModelCapability.ocr],
        AiCapabilitySupport.unknown,
        reason: '${entry.$1} / ${entry.$2} must not declare OCR',
      );
      expect(
        resolved[AiModelCapability.reasoning],
        AiCapabilitySupport.unknown,
        reason: '${entry.$1} / ${entry.$2} must not declare reasoning',
      );
      expect(
        resolved[AiModelCapability.toolCalling],
        AiCapabilitySupport.unknown,
        reason: '${entry.$1} / ${entry.$2} must not declare tool calling',
      );
    }
  });

  test('registry matches are exact in kind and id', () {
    for (final mismatch in const <(AiProviderKind, String)>[
      (AiProviderKind.zhipu, 'deepseek-flash'),
      (AiProviderKind.deepseek, 'glm-5.3'),
      (AiProviderKind.deepseek, 'DeepSeek-Flash'),
      (AiProviderKind.zhipu, 'GLM-5.3'),
      (AiProviderKind.deepseek, 'deepseek-flash-v2'),
      (AiProviderKind.deepseek, 'xdeepseek-flash'),
      (AiProviderKind.zhipu, 'glm-5.3-preview'),
      (AiProviderKind.deepseek, ' deepseek-flash'),
    ]) {
      final resolved = resolveModelCapabilities(
        providerKind: mismatch.$1,
        canonicalModelId: mismatch.$2,
        claims: const <AiCapabilityClaim>[],
      );
      expect(
        resolved[AiModelCapability.textInput],
        AiCapabilitySupport.unknown,
        reason: '${mismatch.$1} / ${mismatch.$2} must not hit the registry',
      );
      expect(
        resolved[AiModelCapability.textOutput],
        AiCapabilitySupport.unknown,
        reason: '${mismatch.$1} / ${mismatch.$2} must not hit the registry',
      );
    }
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
