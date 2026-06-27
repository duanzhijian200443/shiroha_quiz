enum AiEngineType {
  text('text'),
  vision('vision'),
  ocr('ocr');

  const AiEngineType(this.dbValue);

  final String dbValue;

  static AiEngineType fromDbValue(
    dynamic value, {
    AiEngineType fallback = AiEngineType.text,
  }) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'text' => AiEngineType.text,
      'vision' => AiEngineType.vision,
      'ocr' => AiEngineType.ocr,
      _ => fallback,
    };
  }
}

class AiEngineProfile {
  const AiEngineProfile({
    required this.id,
    required this.engineType,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    required this.temperature,
    required this.reasoningEffort,
    required this.isActive,
  });

  final String id;
  final AiEngineType engineType;
  final String name;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final double temperature;
  final String reasoningEffort;
  final bool isActive;

  factory AiEngineProfile.fromMap(
    Map<String, dynamic> map, {
    AiEngineType fallbackType = AiEngineType.text,
  }) {
    return AiEngineProfile(
      id: _readString(map['id']),
      engineType: AiEngineType.fromDbValue(
        map['engine_type'],
        fallback: fallbackType,
      ),
      name: _readString(map['name']),
      apiKey: _readString(map['api_key']),
      baseUrl: _normalizeBaseUrl(map['base_url']),
      modelName: _readString(map['model_name']),
      temperature: _readDouble(map['temperature'], fallback: 0.7),
      reasoningEffort: _readString(map['reasoning_effort']),
      isActive: _readBool(map['is_active']),
    );
  }

  bool get isComplete => missingFields.isEmpty;

  List<String> get missingFields {
    return [
      if (apiKey.isEmpty) 'api_key',
      if (baseUrl.isEmpty) 'base_url',
      if (modelName.isEmpty) 'model_name',
    ];
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'engine_type': engineType.dbValue,
      'name': name,
      'api_key': apiKey,
      'base_url': baseUrl,
      'model_name': modelName,
      'temperature': temperature,
      'reasoning_effort': reasoningEffort,
      'is_active': isActive ? 1 : 0,
    };
  }

  static String _readString(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static double _readDouble(dynamic value, {required double fallback}) {
    return switch (value) {
      final num raw => raw.toDouble(),
      final String raw => double.tryParse(raw.trim()) ?? fallback,
      _ => fallback,
    };
  }

  static bool _readBool(dynamic value) {
    return switch (value) {
      final bool raw => raw,
      final num raw => raw != 0,
      final String raw =>
        raw.trim() == '1' || raw.trim().toLowerCase() == 'true',
      _ => false,
    };
  }

  static String _normalizeBaseUrl(dynamic value) {
    var normalized = _readString(value);
    while (normalized.endsWith('/') &&
        normalized.length > 'https://'.length &&
        normalized.length > 'http://'.length) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
