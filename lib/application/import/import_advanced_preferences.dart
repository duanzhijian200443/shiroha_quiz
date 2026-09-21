/// Loads the durable import execution preferences.
typedef ImportAdvancedPreferencesLoader = Future<ImportAdvancedPreferences>
    Function();

/// Persists the durable import execution preferences.
typedef ImportAdvancedPreferencesSaver = Future<void> Function(
  ImportAdvancedPreferences preferences,
);

/// How aggressively document imports schedule OCR work.
///
/// This only steers execution scheduling (effective concurrency). It never
/// changes OCR recognition content, explanation retention, typed structure,
/// the review flow, or final question semantics.
enum ImportProcessingStrategy {
  /// Pick a safe parallelism based on task size and provider capability.
  automatic,

  /// Low concurrency: fewer rate limits, timeouts and resource contention.
  stability,

  /// Higher concurrency within the provider-safe ceiling, for bulk imports.
  speed,
}

/// Application-level import execution preferences.
///
/// These are durable app preferences, not per-import state: OCR vs text mode
/// is still chosen per import, and review state never lives here.
class ImportAdvancedPreferences {
  const ImportAdvancedPreferences({
    this.processingStrategy = ImportProcessingStrategy.automatic,
    this.autoRetryEnabled = true,
    this.retainUnresolvedFragments = true,
  });

  static const ImportAdvancedPreferences defaults = ImportAdvancedPreferences();

  final ImportProcessingStrategy processingStrategy;
  final bool autoRetryEnabled;
  final bool retainUnresolvedFragments;

  ImportAdvancedPreferences copyWith({
    ImportProcessingStrategy? processingStrategy,
    bool? autoRetryEnabled,
    bool? retainUnresolvedFragments,
  }) {
    return ImportAdvancedPreferences(
      processingStrategy: processingStrategy ?? this.processingStrategy,
      autoRetryEnabled: autoRetryEnabled ?? this.autoRetryEnabled,
      retainUnresolvedFragments:
          retainUnresolvedFragments ?? this.retainUnresolvedFragments,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'processingStrategy': processingStrategy.name,
      'autoRetryEnabled': autoRetryEnabled,
      'retainUnresolvedFragments': retainUnresolvedFragments,
    };
  }

  /// Tolerant decode: a missing, malformed or unknown payload falls back to
  /// the frozen defaults rather than failing the import settings surface.
  static ImportAdvancedPreferences fromJson(Map<String, dynamic> json) {
    return ImportAdvancedPreferences(
      processingStrategy: _decodeStrategy(json['processingStrategy']),
      autoRetryEnabled: json['autoRetryEnabled'] is bool
          ? json['autoRetryEnabled'] as bool
          : defaults.autoRetryEnabled,
      retainUnresolvedFragments: json['retainUnresolvedFragments'] is bool
          ? json['retainUnresolvedFragments'] as bool
          : defaults.retainUnresolvedFragments,
    );
  }

  static ImportProcessingStrategy _decodeStrategy(Object? raw) {
    if (raw is String) {
      for (final strategy in ImportProcessingStrategy.values) {
        if (strategy.name == raw) return strategy;
      }
    }
    return defaults.processingStrategy;
  }

  @override
  bool operator ==(Object other) {
    return other is ImportAdvancedPreferences &&
        other.processingStrategy == processingStrategy &&
        other.autoRetryEnabled == autoRetryEnabled &&
        other.retainUnresolvedFragments == retainUnresolvedFragments;
  }

  @override
  int get hashCode => Object.hash(
        processingStrategy,
        autoRetryEnabled,
        retainUnresolvedFragments,
      );
}
