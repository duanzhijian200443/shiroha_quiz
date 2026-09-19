import 'ai_config_contracts.dart';

/// Product-facing classification of a curated model. Code metadata only:
/// it never reaches persistence, never creates catalog presence, and never
/// influences model-origin authority.
enum AiCuratedModelCategory { text, vision, multimodal, ocr }

/// One exact-key entry of the Shiroha curated capability queue, carrying the
/// official evidence trail required to keep the capability claims auditable.
final class CuratedModelDefinition {
  const CuratedModelDefinition({
    required this.providerKind,
    required this.canonicalModelId,
    required this.category,
    required this.capabilities,
    required this.evidenceDate,
    required this.evidenceSource,
  });

  final AiProviderKind providerKind;
  final String canonicalModelId;
  final AiCuratedModelCategory category;
  final Map<AiModelCapability, AiCapabilitySupport> capabilities;

  /// ISO-8601 date (YYYY-MM-DD) of the official-evidence review.
  final String evidenceDate;

  /// Official documentation identifier backing every capability in
  /// [capabilities]. Entries without official evidence must not exist.
  final String evidenceSource;
}
