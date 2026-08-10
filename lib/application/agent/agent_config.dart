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

final class AgentConfig {
  factory AgentConfig({
    required AgentProviderKind providerKind,
    required String mainProfileId,
    bool webEnabled = false,
  }) {
    final normalizedProfileId = mainProfileId.trim();
    if (!_isBoundedIdentifier(normalizedProfileId)) {
      throw const AgentConfigException(AgentConfigFailure.invalidInput);
    }
    return AgentConfig._(
      providerKind: providerKind,
      mainProfileId: normalizedProfileId,
      webEnabled: webEnabled,
    );
  }

  const AgentConfig._({
    required this.providerKind,
    required this.mainProfileId,
    required this.webEnabled,
  });

  final AgentProviderKind providerKind;
  final String mainProfileId;
  final bool webEnabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentConfig &&
          providerKind == other.providerKind &&
          mainProfileId == other.mainProfileId &&
          webEnabled == other.webEnabled;

  @override
  int get hashCode => Object.hash(providerKind, mainProfileId, webEnabled);
}

final class AgentConfigCodec {
  const AgentConfigCodec();

  static const int schemaVersion = 1;
  static const Set<String> _keys = <String>{
    'schema_version',
    'provider_kind',
    'main_profile_id',
    'web_enabled',
  };

  String encode(AgentConfig config) {
    return jsonEncode(<String, Object>{
      'schema_version': schemaVersion,
      'provider_kind': config.providerKind.storageValue,
      'main_profile_id': config.mainProfileId,
      'web_enabled': config.webEnabled,
    });
  }

  AgentConfig decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic> ||
          decoded.keys.toSet().difference(_keys).isNotEmpty ||
          _keys.difference(decoded.keys.toSet()).isNotEmpty ||
          decoded['schema_version'] != schemaVersion ||
          decoded['main_profile_id'] is! String ||
          decoded['web_enabled'] is! bool) {
        throw const AgentConfigException(
          AgentConfigFailure.corruptStoredConfig,
        );
      }
      return AgentConfig(
        providerKind: AgentProviderKind.parse(decoded['provider_kind']),
        mainProfileId: decoded['main_profile_id']! as String,
        webEnabled: decoded['web_enabled']! as bool,
      );
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
