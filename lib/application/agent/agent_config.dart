import 'dart:convert';

enum AgentProviderKind {
  deepSeekResponses('deepseek_responses');

  const AgentProviderKind(this.storageValue);

  final String storageValue;

  static AgentProviderKind parse(Object? value) {
    return switch (value) {
      'deepseek_responses' => AgentProviderKind.deepSeekResponses,
      _ => throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        ),
    };
  }
}

enum AgentReasoningEffort {
  high('high'),
  max('max');

  const AgentReasoningEffort(this.storageValue);

  final String storageValue;

  static AgentReasoningEffort parse(Object? value) {
    return switch (value) {
      'high' => AgentReasoningEffort.high,
      'max' => AgentReasoningEffort.max,
      _ => throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        ),
    };
  }
}

final class AgentConfig {
  factory AgentConfig({
    required AgentProviderKind providerKind,
    required String mainProfileId,
    String? fallbackProfileId,
    bool webEnabled = false,
    double temperature = 1.0,
    AgentReasoningEffort reasoningEffort = AgentReasoningEffort.high,
  }) {
    final normalizedProfileId = mainProfileId.trim();
    final normalizedFallbackId = fallbackProfileId?.trim();
    if (!_isBoundedIdentifier(normalizedProfileId) ||
        (normalizedFallbackId != null &&
            (!_isBoundedIdentifier(normalizedFallbackId) ||
                normalizedFallbackId == normalizedProfileId)) ||
        !temperature.isFinite ||
        temperature < 0.0 ||
        temperature > 2.0) {
      throw const AgentConfigException(AgentConfigFailure.invalidInput);
    }
    return AgentConfig._(
      providerKind: providerKind,
      mainProfileId: normalizedProfileId,
      fallbackProfileId: normalizedFallbackId,
      webEnabled: webEnabled,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );
  }

  const AgentConfig._({
    required this.providerKind,
    required this.mainProfileId,
    this.fallbackProfileId,
    required this.webEnabled,
    required this.temperature,
    required this.reasoningEffort,
  });

  final AgentProviderKind providerKind;
  final String mainProfileId;
  final String? fallbackProfileId;
  final bool webEnabled;
  final double temperature;
  final AgentReasoningEffort reasoningEffort;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentConfig &&
          providerKind == other.providerKind &&
          mainProfileId == other.mainProfileId &&
          fallbackProfileId == other.fallbackProfileId &&
          webEnabled == other.webEnabled &&
          temperature == other.temperature &&
          reasoningEffort == other.reasoningEffort;

  @override
  int get hashCode => Object.hash(
        providerKind,
        mainProfileId,
        fallbackProfileId,
        webEnabled,
        temperature,
        reasoningEffort,
      );
}

final class AgentConfigCodec {
  const AgentConfigCodec();

  static const int schemaVersion = 2;
  static const Set<String> _v1Keys = <String>{
    'schema_version',
    'provider_kind',
    'main_profile_id',
    'web_enabled',
    'temperature',
    'reasoning_effort',
  };
  static const Set<String> _v2Keys = <String>{
    'schema_version',
    'provider_kind',
    'main_profile_id',
    'fallback_profile_id',
    'web_enabled',
    'temperature',
    'reasoning_effort',
  };

  String encode(AgentConfig config) {
    return jsonEncode(<String, Object?>{
      'schema_version': schemaVersion,
      'provider_kind': config.providerKind.storageValue,
      'main_profile_id': config.mainProfileId,
      'fallback_profile_id': config.fallbackProfileId,
      'web_enabled': config.webEnabled,
      'temperature': config.temperature,
      'reasoning_effort': config.reasoningEffort.storageValue,
    });
  }

  AgentConfig decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        );
      }
      final version = decoded['schema_version'];
      if (version == 1) {
        if (decoded.keys.toSet().difference(_v1Keys).isNotEmpty ||
            _v1Keys.difference(decoded.keys.toSet()).isNotEmpty ||
            decoded['main_profile_id'] is! String ||
            decoded['web_enabled'] is! bool ||
            decoded['temperature'] is! num) {
          throw const AgentConfigException(
            AgentConfigFailure.corruptStoredConfig,
          );
        }
        return AgentConfig(
          providerKind: AgentProviderKind.parse(decoded['provider_kind']),
          mainProfileId: decoded['main_profile_id']! as String,
          fallbackProfileId: null,
          webEnabled: decoded['web_enabled']! as bool,
          temperature: (decoded['temperature']! as num).toDouble(),
          reasoningEffort: AgentReasoningEffort.parse(
            decoded['reasoning_effort'],
          ),
        );
      } else if (version == 2) {
        if (decoded.keys.toSet().difference(_v2Keys).isNotEmpty ||
            _v2Keys.difference(decoded.keys.toSet()).isNotEmpty ||
            decoded['main_profile_id'] is! String ||
            (decoded['fallback_profile_id'] != null &&
                decoded['fallback_profile_id'] is! String) ||
            decoded['web_enabled'] is! bool ||
            decoded['temperature'] is! num) {
          throw const AgentConfigException(
            AgentConfigFailure.corruptStoredConfig,
          );
        }
        return AgentConfig(
          providerKind: AgentProviderKind.parse(decoded['provider_kind']),
          mainProfileId: decoded['main_profile_id']! as String,
          fallbackProfileId: decoded['fallback_profile_id'] as String?,
          webEnabled: decoded['web_enabled']! as bool,
          temperature: (decoded['temperature']! as num).toDouble(),
          reasoningEffort: AgentReasoningEffort.parse(
            decoded['reasoning_effort'],
          ),
        );
      } else {
        throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        );
      }
    } on AgentConfigException catch (error) {
      if (error.failure == AgentConfigFailure.invalidInput) {
        throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        );
      }
      rethrow;
    } on FormatException {
      throw const AgentConfigException(
        AgentConfigFailure.corruptStoredConfig,
      );
    } on TypeError {
      throw const AgentConfigException(
        AgentConfigFailure.corruptStoredConfig,
      );
    }
  }
}

enum AgentConfigFailure {
  invalidInput,
  unconfigured,
  corruptStoredConfig,
  profileNotFound,
  profileIncomplete,
  temporarilyUnavailable,
}

final class AgentConfigException implements Exception {
  const AgentConfigException(this.failure);

  final AgentConfigFailure failure;

  @override
  String toString() => 'AgentConfigException(${failure.name})';
}

bool _isBoundedIdentifier(String value) {
  final length = value.runes.length;
  return length >= 1 && length <= 128 && !value.contains('\u0000');
}
