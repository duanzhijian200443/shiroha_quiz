import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/domain/ai_config/curated_model_definition.dart';
import 'package:shiroha_quiz/domain/ai_config/shiroha_capability_registry.dart';

void main() {
  const zhipuTextIds = <String>[
    'glm-5.3',
    'glm-5.2',
    'glm-5.1',
    'glm-5',
    'glm-5-turbo',
    'glm-4.7',
    'glm-4.7-flashx',
    'glm-4.7-flash',
    'glm-4.6',
    'glm-4.5-air',
    'glm-4.5-airx',
    'glm-4.5-flash',
  ];

  const zhipuMultimodalIds = <String>[
    'glm-5.3-flash',
    'glm-5.3-flashx',
    'glm-5v-turbo',
    'glm-4.6v',
    'glm-4.6v-flashx',
    'glm-4.6v-flash',
    'glm-4.1v-thinking-flashx',
    'glm-4.1v-thinking-flash',
  ];

  Map<AiModelCapability, AiCapabilitySupport> resolve(
    AiProviderKind kind,
    String id,
  ) =>
      resolveModelCapabilities(
        providerKind: kind,
        canonicalModelId: id,
        claims: const <AiCapabilityClaim>[],
      );

  test('zhipu text queue declares text only with explicit vision refusal',
      () async {
    for (final id in zhipuTextIds) {
      final resolved = resolve(AiProviderKind.zhipu, id);
      expect(
          resolved[AiModelCapability.textInput], AiCapabilitySupport.supported,
          reason: id);
      expect(
          resolved[AiModelCapability.textOutput], AiCapabilitySupport.supported,
          reason: id);
      expect(resolved[AiModelCapability.imageInput],
          AiCapabilitySupport.unsupported,
          reason: id);
      expect(resolved[AiModelCapability.ocr], AiCapabilitySupport.unsupported,
          reason: id);
      expect(resolved[AiModelCapability.reasoning], AiCapabilitySupport.unknown,
          reason: '$id must not gain reasoning without evidence');
      expect(
          resolved[AiModelCapability.toolCalling], AiCapabilitySupport.unknown,
          reason: '$id must not gain tool calling without evidence');
      expect(resolved[AiModelCapability.embedding], AiCapabilitySupport.unknown,
          reason: id);
    }
  });

  test('zhipu multimodal queue declares text and image, refuses ocr', () async {
    for (final id in zhipuMultimodalIds) {
      final resolved = resolve(AiProviderKind.zhipu, id);
      expect(
          resolved[AiModelCapability.textInput], AiCapabilitySupport.supported,
          reason: id);
      expect(
          resolved[AiModelCapability.imageInput], AiCapabilitySupport.supported,
          reason: id);
      expect(
          resolved[AiModelCapability.textOutput], AiCapabilitySupport.supported,
          reason: id);
      expect(resolved[AiModelCapability.ocr], AiCapabilitySupport.unsupported,
          reason: id);
      expect(resolved[AiModelCapability.reasoning], AiCapabilitySupport.unknown,
          reason: '$id must not gain reasoning without evidence');
      expect(
          resolved[AiModelCapability.toolCalling], AiCapabilitySupport.unknown,
          reason: '$id must not gain tool calling without evidence');
    }
  });

  test('zhipu ocr queue refuses the chat-based slots', () async {
    final resolved = resolve(AiProviderKind.zhipu, 'glm-ocr');
    expect(resolved[AiModelCapability.ocr], AiCapabilitySupport.supported);
    expect(
        resolved[AiModelCapability.textOutput], AiCapabilitySupport.supported);
    expect(
        resolved[AiModelCapability.textInput], AiCapabilitySupport.unsupported);
    expect(resolved[AiModelCapability.imageInput],
        AiCapabilitySupport.unsupported);
  });

  test('deepseek queue carries the official classification', () async {
    final flash = resolve(AiProviderKind.deepseek, 'deepseek-flash');
    expect(flash[AiModelCapability.textInput], AiCapabilitySupport.supported);
    expect(flash[AiModelCapability.imageInput], AiCapabilitySupport.supported,
        reason: 'official docs classify deepseek-flash (V4.1-Flash) as '
            'multimodal with vision');
    expect(flash[AiModelCapability.textOutput], AiCapabilitySupport.supported);
    expect(flash[AiModelCapability.ocr], AiCapabilitySupport.unsupported);
    expect(flash[AiModelCapability.reasoning], AiCapabilitySupport.unknown,
        reason: 'reasoning stays unannotated without a dedicated package');
    expect(flash[AiModelCapability.toolCalling], AiCapabilitySupport.unknown,
        reason: 'the Agent transport gate is a separate frozen contract');

    final retired = resolve(AiProviderKind.deepseek, 'deepseek-v4-flash');
    expect(retired[AiModelCapability.textInput], AiCapabilitySupport.supported);
    expect(retired[AiModelCapability.imageInput], AiCapabilitySupport.supported,
        reason: 'the retired id is served by the multimodal V4.1-Flash');
    expect(
        retired[AiModelCapability.textOutput], AiCapabilitySupport.supported);
    expect(retired[AiModelCapability.reasoning], AiCapabilitySupport.supported,
        reason: 'Package 2 claims stay preserved');
    expect(
        retired[AiModelCapability.toolCalling], AiCapabilitySupport.supported,
        reason: 'Package 2 claims stay preserved');
    expect(retired[AiModelCapability.ocr], AiCapabilitySupport.unsupported);

    final visionExp =
        resolve(AiProviderKind.deepseek, 'deepseek-v4-flash-vision-exp');
    expect(
        visionExp[AiModelCapability.imageInput], AiCapabilitySupport.supported);
    expect(visionExp[AiModelCapability.ocr], AiCapabilitySupport.unsupported);

    final pro = resolve(AiProviderKind.deepseek, 'deepseek-v4-pro');
    expect(pro[AiModelCapability.textInput], AiCapabilitySupport.supported);
    expect(pro[AiModelCapability.textOutput], AiCapabilitySupport.supported);
    expect(pro[AiModelCapability.imageInput], AiCapabilitySupport.unsupported,
        reason: 'official docs classify deepseek-v4-pro as text-only');
    expect(pro[AiModelCapability.ocr], AiCapabilitySupport.unsupported);
  });

  test('queue matching stays exact in kind and id', () async {
    const misses = <(AiProviderKind, String)>[
      (AiProviderKind.zhipu, 'glm-5.3-extra'),
      (AiProviderKind.zhipu, 'glm-4.5'),
      (AiProviderKind.zhipu, 'glm-4.5v'),
      (AiProviderKind.zhipu, 'GLM-5.3'),
      (AiProviderKind.zhipu, 'glm-ocr-pro'),
      (AiProviderKind.deepseek, 'glm-5.3'),
      (AiProviderKind.openAiCompatible, 'glm-5.3'),
      (AiProviderKind.deepseek, 'deepseek-v4'),
      (AiProviderKind.deepseek, 'deepseek-v4-flash-vision'),
      (AiProviderKind.deepseek, 'deepseek-v4-pro-max'),
      (AiProviderKind.deepseek, 'deepseek-chat'),
      (AiProviderKind.deepseek, 'deepseek-reasoner'),
    ];
    for (final (kind, id) in misses) {
      expect(ShirohaCapabilityRegistry.definitionFor(kind, id), isNull,
          reason: '$kind / $id must not hit the queue');
      expect(resolve(kind, id)[AiModelCapability.textInput],
          AiCapabilitySupport.unknown,
          reason: '$kind / $id must stay unannotated');
    }
    expect(
      ShirohaCapabilityRegistry.definitionFor(
          AiProviderKind.zhipu, 'glm-4.5-air'),
      isNotNull,
      reason: 'glm-4.5-air is an exact hit while glm-4.5 is not',
    );
  });

  test('every curated definition carries an auditable evidence trail',
      () async {
    for (final definition in ShirohaCapabilityRegistry.definitions) {
      expect(
        definition.evidenceDate,
        definition.providerKind == AiProviderKind.deepseek
            ? '2026-09-20'
            : '2026-09-19',
        reason: definition.canonicalModelId,
      );
      expect(definition.evidenceSource, isNotEmpty,
          reason: definition.canonicalModelId);
      expect(definition.capabilities, isNotEmpty,
          reason: definition.canonicalModelId);
    }
    expect(
      ShirohaCapabilityRegistry.definitionFor(AiProviderKind.zhipu, 'glm-5.3')!
          .category,
      AiCuratedModelCategory.text,
    );
    expect(
      ShirohaCapabilityRegistry.definitionFor(
              AiProviderKind.zhipu, 'glm-5.3-flash')!
          .category,
      AiCuratedModelCategory.multimodal,
    );
    expect(
      ShirohaCapabilityRegistry.definitionFor(AiProviderKind.zhipu, 'glm-ocr')!
          .category,
      AiCuratedModelCategory.ocr,
    );
    expect(
      ShirohaCapabilityRegistry.definitionFor(
              AiProviderKind.deepseek, 'deepseek-flash')!
          .category,
      AiCuratedModelCategory.multimodal,
    );
    expect(
      ShirohaCapabilityRegistry.definitionFor(
              AiProviderKind.deepseek, 'deepseek-v4-pro')!
          .category,
      AiCuratedModelCategory.text,
    );
  });

  test('claimsFor stays the resolver-facing unmodifiable view', () async {
    final claims = ShirohaCapabilityRegistry.claimsFor(
      AiProviderKind.zhipu,
      'glm-5.3',
    );
    expect(claims[AiModelCapability.textInput], AiCapabilitySupport.supported);
    expect(
      () => claims[AiModelCapability.textInput] = AiCapabilitySupport.unknown,
      throwsUnsupportedError,
    );
    expect(
      ShirohaCapabilityRegistry.claimsFor(
          AiProviderKind.zhipu, 'no-such-model'),
      isEmpty,
    );
  });
}
