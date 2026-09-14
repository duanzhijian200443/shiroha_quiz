import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../application/ai_config/ai_config_ports.dart';
import '../../domain/ai_config/ai_config_contracts.dart';

final class HttpAiProviderConnection implements AiProviderConnectionPort {
  const HttpAiProviderConnection({required http.Client client})
      : _client = client;

  final http.Client _client;

  @override
  Future<void> testConnection({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  }) async {
    await discoverModels(
      providerKind: providerKind,
      baseUrl: baseUrl,
      credential: credential,
    );
  }

  @override
  Future<AiDiscoveredModelSnapshot> discoverModels({
    required AiProviderKind providerKind,
    required String baseUrl,
    required String credential,
  }) async {
    if (credential.isEmpty) {
      throw const AiConfigException(AiConfigFailure.credentialMissing);
    }
    final endpoint = _modelEndpoint(providerKind, baseUrl);
    final uri = providerKind == AiProviderKind.gemini
        ? endpoint.replace(queryParameters: <String, String>{'key': credential})
        : endpoint;
    final headers = <String, String>{
      'Accept': 'application/json',
      if (providerKind != AiProviderKind.gemini)
        'Authorization': 'Bearer $credential',
    };
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const AiConfigException(AiConfigFailure.temporarilyUnavailable);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AiConfigException(AiConfigFailure.connectionRejected);
    }
    if (response.statusCode != 200) {
      throw const AiConfigException(AiConfigFailure.syncFailed);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      final rawModels = providerKind == AiProviderKind.gemini
          ? decoded['models']
          : decoded['data'] ?? decoded['models'];
      if (rawModels is! List) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      return AiDiscoveredModelSnapshot(
        models: rawModels.map((raw) {
          if (raw is! Map) {
            throw const AiConfigException(AiConfigFailure.dataCorrupt);
          }
          final map = Map<String, dynamic>.from(raw);
          final id = (map['id'] ?? map['name'])?.toString();
          if (id == null) {
            throw const AiConfigException(AiConfigFailure.dataCorrupt);
          }
          return AiDiscoveredModel(
            canonicalModelId: id,
            displayName: map['displayName']?.toString() ?? id,
            officialCapabilities: _officialCapabilities(map['capabilities']),
          );
        }).toList(growable: false),
      );
    } on AiConfigException {
      rethrow;
    } catch (_) {
      throw const AiConfigException(AiConfigFailure.dataCorrupt);
    }
  }

  static Uri _modelEndpoint(AiProviderKind kind, String baseUrl) {
    final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final base = Uri.tryParse(normalized);
    if (base == null ||
        !base.hasScheme ||
        (base.scheme != 'https' && base.scheme != 'http') ||
        base.host.isEmpty) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final suffix = switch (kind) {
      AiProviderKind.gemini => '/models',
      AiProviderKind.zhipu when normalized.endsWith('/v4') => '/models',
      AiProviderKind.zhipu => '/v4/models',
      AiProviderKind.deepseek || AiProviderKind.openAiCompatible => '/models',
    };
    return Uri.parse('$normalized$suffix');
  }

  static Map<AiModelCapability, AiCapabilitySupport> _officialCapabilities(
    Object? raw,
  ) {
    if (raw is! Map) return const {};
    final result = <AiModelCapability, AiCapabilitySupport>{};
    for (final capability in AiModelCapability.values) {
      final value = raw[capability.storageValue];
      if (value is bool) {
        result[capability] = value
            ? AiCapabilitySupport.supported
            : AiCapabilitySupport.unsupported;
      }
    }
    return result;
  }
}
