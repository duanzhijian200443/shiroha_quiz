enum AiProviderKind {
  deepseek('deepseek'),
  zhipu('zhipu'),
  gemini('gemini'),
  openAiCompatible('openai_compatible');

  const AiProviderKind(this.storageValue);

  final String storageValue;

  static AiProviderKind parse(Object? value) => switch (value) {
        'deepseek' => AiProviderKind.deepseek,
        'zhipu' => AiProviderKind.zhipu,
        'gemini' => AiProviderKind.gemini,
        'openai_compatible' => AiProviderKind.openAiCompatible,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      };
}

enum AiProviderState {
  ready('ready'),
  legacyIncomplete('legacy_incomplete');

  const AiProviderState(this.storageValue);
  final String storageValue;

  static AiProviderState parse(Object? value) => switch (value) {
        'ready' => AiProviderState.ready,
        'legacy_incomplete' => AiProviderState.legacyIncomplete,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      };
}

enum AiOperationStatus {
  never('never'),
  succeeded('succeeded'),
  failed('failed');

  const AiOperationStatus(this.storageValue);
  final String storageValue;

  static AiOperationStatus parse(Object? value) => switch (value) {
        'never' => AiOperationStatus.never,
        'succeeded' => AiOperationStatus.succeeded,
        'failed' => AiOperationStatus.failed,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      };
}

enum AiModelAvailability {
  available('available'),
  unavailable('unavailable');

  const AiModelAvailability(this.storageValue);
  final String storageValue;

  static AiModelAvailability parse(Object? value) => switch (value) {
        'available' => AiModelAvailability.available,
        'unavailable' => AiModelAvailability.unavailable,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      };
}

enum AiModelCapability {
  textInput('textInput'),
  imageInput('imageInput'),
  textOutput('textOutput'),
  reasoning('reasoning'),
  toolCalling('toolCalling'),
  ocr('ocr'),
  embedding('embedding');

  const AiModelCapability(this.storageValue);
  final String storageValue;

  static AiModelCapability parse(Object? value) {
    return values.where((item) => item.storageValue == value).firstOrNull ??
        (throw const AiConfigException(AiConfigFailure.dataCorrupt));
  }
}

enum AiCapabilityClaimSource {
  providerOfficial('providerOfficial', 0),
  shirohaRegistry('shirohaRegistry', 1),
  userDeclaration('userDeclaration', 2),
  capabilityProbe('capabilityProbe', 3);

  const AiCapabilityClaimSource(this.storageValue, this.priority);
  final String storageValue;
  final int priority;

  static AiCapabilityClaimSource parse(Object? value) {
    return values.where((item) => item.storageValue == value).firstOrNull ??
        (throw const AiConfigException(AiConfigFailure.dataCorrupt));
  }
}

enum AiCapabilitySupport {
  supported('supported'),
  unsupported('unsupported'),
  unknown('unknown');

  const AiCapabilitySupport(this.storageValue);
  final String storageValue;
}

enum AiCapabilitySlot {
  textModel('textModel'),
  imageUnderstanding('imageUnderstanding'),
  documentRecognition('documentRecognition');

  const AiCapabilitySlot(this.storageValue);
  final String storageValue;

  static AiCapabilitySlot parse(Object? value) {
    return values.where((item) => item.storageValue == value).firstOrNull ??
        (throw const AiConfigException(AiConfigFailure.dataCorrupt));
  }

  Set<AiModelCapability> get requiredCapabilities => switch (this) {
        AiCapabilitySlot.textModel => const {
            AiModelCapability.textInput,
            AiModelCapability.textOutput,
          },
        AiCapabilitySlot.imageUnderstanding => const {
            AiModelCapability.textInput,
            AiModelCapability.imageInput,
            AiModelCapability.textOutput,
          },
        AiCapabilitySlot.documentRecognition => const {
            AiModelCapability.ocr,
            AiModelCapability.textOutput,
          },
      };
}

enum AiBindingValidationMode {
  verified('verified'),
  userSelectedUnknown('userSelectedUnknown'),
  legacyPreserved('legacyPreserved');

  const AiBindingValidationMode(this.storageValue);
  final String storageValue;

  static AiBindingValidationMode parse(Object? value) => switch (value) {
        'verified' => AiBindingValidationMode.verified,
        'userSelectedUnknown' => AiBindingValidationMode.userSelectedUnknown,
        'legacyPreserved' => AiBindingValidationMode.legacyPreserved,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      };
}

enum AiCredentialState { present, missing, unavailable }

enum AiConfigFailure {
  invalidInput,
  dataCorrupt,
  temporarilyUnavailable,
  providerNotFound,
  providerAlreadyExists,
  providerInUse,
  credentialMissing,
  connectionRejected,
  syncFailed,
  modelNotFound,
  modelUnavailable,
  capabilityUnknown,
  capabilityUnsupported,
  staleRevision,
}

final class AiConfigException implements Exception {
  const AiConfigException(this.failure);

  final AiConfigFailure failure;

  @override
  String toString() => 'AiConfigException(${failure.name})';
}

String validateAiConfigId(String value) {
  if (value.isEmpty ||
      value.runes.length > 128 ||
      value.contains('\u0000') ||
      value.contains('/') ||
      value.runes.any(_isControlRune)) {
    throw const AiConfigException(AiConfigFailure.invalidInput);
  }
  return value;
}

String validateCanonicalModelId(String value) {
  if (value.isEmpty ||
      value.runes.length > 200 ||
      value.trim() != value ||
      value.contains('\u0000') ||
      value.runes.any(_isControlRune)) {
    throw const AiConfigException(AiConfigFailure.invalidInput);
  }
  return value;
}

final class AiProviderRecord {
  AiProviderRecord({
    required String providerId,
    required this.kind,
    required String displayName,
    required String baseUrl,
    required this.state,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.lastConnectionStatus = AiOperationStatus.never,
    this.lastConnectionAt,
    this.lastSyncStatus = AiOperationStatus.never,
    this.lastSyncAt,
  })  : providerId = validateAiConfigId(providerId),
        displayName = _bounded(displayName, 200),
        baseUrl = _bounded(baseUrl, 2048) {
    if (revision < 0 ||
        createdAt < 0 ||
        updatedAt < 0 ||
        (lastConnectionAt != null && lastConnectionAt! < 0) ||
        (lastSyncAt != null && lastSyncAt! < 0) ||
        (state == AiProviderState.ready && baseUrl.trim().isEmpty)) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
  }

  final String providerId;
  final AiProviderKind kind;
  final String displayName;
  final String baseUrl;
  final AiProviderState state;
  final int revision;
  final int createdAt;
  final int updatedAt;
  final AiOperationStatus lastConnectionStatus;
  final int? lastConnectionAt;
  final AiOperationStatus lastSyncStatus;
  final int? lastSyncAt;
}

enum AiModelOrigin {
  providerCatalog,
  curated,
  userDefined,
  legacyImported;

  static AiModelOrigin parse(Object? value) =>
      values.where((item) => item.name == value).firstOrNull ??
      (throw const AiConfigException(AiConfigFailure.dataCorrupt));
}

final class AiModelRecord {
  AiModelRecord({
    required String modelRef,
    required String providerId,
    required String canonicalModelId,
    required String displayName,
    required this.availability,
    required this.origin,
    required this.firstSeenAt,
    required this.lastSeenAt,
  })  : modelRef = validateAiConfigId(modelRef),
        providerId = validateAiConfigId(providerId),
        canonicalModelId = validateCanonicalModelId(canonicalModelId),
        displayName = _bounded(displayName, 200) {
    if (firstSeenAt < 0 || lastSeenAt < 0) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
  }

  final String modelRef;
  final String providerId;
  final String canonicalModelId;
  final String displayName;
  final AiModelAvailability availability;
  final AiModelOrigin origin;
  final int firstSeenAt;
  final int lastSeenAt;
}

final class AiCapabilityClaim {
  AiCapabilityClaim({
    required String modelRef,
    required this.capability,
    required this.source,
    required this.support,
    required this.assertedAt,
  }) : modelRef = validateAiConfigId(modelRef) {
    if (support == AiCapabilitySupport.unknown || assertedAt < 0) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
  }

  final String modelRef;
  final AiModelCapability capability;
  final AiCapabilityClaimSource source;
  final AiCapabilitySupport support;
  final int assertedAt;
}

final class AiCapabilityBinding {
  AiCapabilityBinding({
    required this.slot,
    required String modelRef,
    required this.temperature,
    required String reasoningEffort,
    required this.validationMode,
    required this.revision,
    required this.updatedAt,
  })  : modelRef = validateAiConfigId(modelRef),
        reasoningEffort = _bounded(reasoningEffort, 100) {
    if (!temperature.isFinite ||
        temperature < 0 ||
        temperature > 2 ||
        revision < 0 ||
        updatedAt < 0) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
  }

  final AiCapabilitySlot slot;
  final String modelRef;
  final double temperature;
  final String reasoningEffort;
  final AiBindingValidationMode validationMode;
  final int revision;
  final int updatedAt;
}

String _bounded(String value, int maxRunes) {
  if (value.runes.length > maxRunes ||
      value.contains('\u0000') ||
      value.runes.any((rune) => _isControlRune(rune) && rune != 0x09)) {
    throw const AiConfigException(AiConfigFailure.invalidInput);
  }
  return value;
}

bool _isControlRune(int rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
