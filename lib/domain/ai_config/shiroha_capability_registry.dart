import 'ai_config_contracts.dart';
import 'curated_model_definition.dart';

/// Exact-key curated capability queue: the code authority for capabilities
/// Shiroha has verified against official documentation or an owned production
/// transport contract. Never infer capabilities from model name fragments,
/// prefixes, suffixes, or display labels; entries without official evidence
/// stay absent, which resolves to `unknown`. Queue presence never creates
/// catalog presence.
abstract final class ShirohaCapabilityRegistry {
  static const Map<AiModelCapability, AiCapabilitySupport> _textCapabilities = {
    AiModelCapability.textInput: AiCapabilitySupport.supported,
    AiModelCapability.textOutput: AiCapabilitySupport.supported,
    AiModelCapability.imageInput: AiCapabilitySupport.unsupported,
    AiModelCapability.ocr: AiCapabilitySupport.unsupported,
  };

  static const Map<AiModelCapability, AiCapabilitySupport>
      _multimodalCapabilities = {
    AiModelCapability.textInput: AiCapabilitySupport.supported,
    AiModelCapability.imageInput: AiCapabilitySupport.supported,
    AiModelCapability.textOutput: AiCapabilitySupport.supported,
    AiModelCapability.ocr: AiCapabilitySupport.unsupported,
  };

  static const Map<AiModelCapability, AiCapabilitySupport> _ocrCapabilities = {
    AiModelCapability.ocr: AiCapabilitySupport.supported,
    AiModelCapability.textOutput: AiCapabilitySupport.supported,
    AiModelCapability.textInput: AiCapabilitySupport.unsupported,
    AiModelCapability.imageInput: AiCapabilitySupport.unsupported,
  };

  static const String _zhipuOverview =
      'docs.bigmodel.cn/cn/guide/start/model-overview';

  static const Map<(AiProviderKind, String), CuratedModelDefinition>
      _definitions = {
    (AiProviderKind.deepseek, 'deepseek-v4-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-v4-flash',
      category: AiCuratedModelCategory.text,
      capabilities: {
        AiModelCapability.textInput: AiCapabilitySupport.supported,
        AiModelCapability.textOutput: AiCapabilitySupport.supported,
        AiModelCapability.reasoning: AiCapabilitySupport.supported,
        AiModelCapability.toolCalling: AiCapabilitySupport.supported,
      },
      evidenceDate: '2026-09-19',
      evidenceSource: 'api-docs.deepseek.com',
    ),
    (AiProviderKind.deepseek, 'deepseek-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.deepseek,
      canonicalModelId: 'deepseek-flash',
      category: AiCuratedModelCategory.text,
      capabilities: {
        AiModelCapability.textInput: AiCapabilitySupport.supported,
        AiModelCapability.textOutput: AiCapabilitySupport.supported,
      },
      evidenceDate: '2026-09-19',
      evidenceSource: 'api-docs.deepseek.com',
    ),
    (AiProviderKind.zhipu, 'glm-5.3'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5.3',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/text/glm-5.3.md',
    ),
    (AiProviderKind.zhipu, 'glm-5.2'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5.2',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-5.1'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5.1',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-5'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-5-turbo'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5-turbo',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.7'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.7',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.7-flashx'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.7-flashx',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.7-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.7-flash',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.6'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.6',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.5-air'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.5-air',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.5-airx'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.5-airx',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-4.5-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.5-flash',
      category: AiCuratedModelCategory.text,
      capabilities: _textCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: _zhipuOverview,
    ),
    (AiProviderKind.zhipu, 'glm-5.3-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5.3-flash',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash.md',
    ),
    (AiProviderKind.zhipu, 'glm-5.3-flashx'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5.3-flashx',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash.md',
    ),
    (AiProviderKind.zhipu, 'glm-5v-turbo'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-5v-turbo',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-5v-turbo.md',
    ),
    (AiProviderKind.zhipu, 'glm-4.6v'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.6v',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-4.6v.md',
    ),
    (AiProviderKind.zhipu, 'glm-4.6v-flashx'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.6v-flashx',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-4.6v.md',
    ),
    (AiProviderKind.zhipu, 'glm-4.6v-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.6v-flash',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-4.6v.md',
    ),
    (AiProviderKind.zhipu, 'glm-4.1v-thinking-flashx'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.1v-thinking-flashx',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource:
          'docs.bigmodel.cn/cn/guide/models/vlm/glm-4.1v-thinking.md',
    ),
    (AiProviderKind.zhipu, 'glm-4.1v-thinking-flash'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-4.1v-thinking-flash',
      category: AiCuratedModelCategory.multimodal,
      capabilities: _multimodalCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource:
          'docs.bigmodel.cn/cn/guide/models/vlm/glm-4.1v-thinking.md',
    ),
    (AiProviderKind.zhipu, 'glm-ocr'): CuratedModelDefinition(
      providerKind: AiProviderKind.zhipu,
      canonicalModelId: 'glm-ocr',
      category: AiCuratedModelCategory.ocr,
      capabilities: _ocrCapabilities,
      evidenceDate: '2026-09-19',
      evidenceSource: 'docs.bigmodel.cn/cn/guide/models/vlm/glm-ocr.md',
    ),
  };

  static Iterable<CuratedModelDefinition> get definitions =>
      _definitions.values;

  static CuratedModelDefinition? definitionFor(
    AiProviderKind providerKind,
    String canonicalModelId,
  ) =>
      _definitions[(providerKind, canonicalModelId)];

  static Map<AiModelCapability, AiCapabilitySupport> claimsFor(
    AiProviderKind providerKind,
    String canonicalModelId,
  ) {
    final definition = _definitions[(providerKind, canonicalModelId)];
    return definition == null
        ? const {}
        : Map.unmodifiable(definition.capabilities);
  }
}

Map<AiModelCapability, AiCapabilitySupport> resolveModelCapabilities({
  required AiProviderKind providerKind,
  required String canonicalModelId,
  required List<AiCapabilityClaim> claims,
}) {
  final curated = ShirohaCapabilityRegistry.claimsFor(
    providerKind,
    canonicalModelId,
  );
  final resolved = <AiModelCapability, AiCapabilitySupport>{};
  for (final capability in AiModelCapability.values) {
    AiCapabilitySupport? selected;
    for (final source in AiCapabilityClaimSource.values) {
      final values = claims
          .where(
            (claim) => claim.capability == capability && claim.source == source,
          )
          .map((claim) => claim.support)
          .toSet();
      if (source == AiCapabilityClaimSource.shirohaRegistry) {
        final curatedValue = curated[capability];
        if (curatedValue != null) values.add(curatedValue);
      }
      if (values.length > 1) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      if (values.isNotEmpty) {
        selected = values.single;
        break;
      }
    }
    resolved[capability] = selected ?? AiCapabilitySupport.unknown;
  }
  return Map.unmodifiable(resolved);
}
