/// Loads the durable import execution preferences.
typedef ImportAdvancedPreferencesLoader = Future<ImportAdvancedPreferences>
    Function();

/// Persists the durable import execution preferences.
typedef ImportAdvancedPreferencesSaver = Future<void> Function(
  ImportAdvancedPreferences preferences,
);

/// Application-level import execution preferences.
///
/// These are durable app preferences, not per-import state: OCR vs text mode
/// is still chosen per import, and review state never lives here.
class ImportAdvancedPreferences {
  const ImportAdvancedPreferences({
    this.ocrTaskConcurrency = defaultOcrTaskConcurrency,
    this.autoRetryEnabled = true,
    this.retainUnresolvedFragments = true,
  });

  static const ImportAdvancedPreferences defaults = ImportAdvancedPreferences();

  /// Bounds of the user-facing OCR task concurrency budget.
  ///
  /// The budget caps provider OCR requests across the app. One import task
  /// stays serial internally, including files within a single PDF.
  static const int minOcrTaskConcurrency = 1;
  static const int maxOcrTaskConcurrency = 10;
  static const int defaultOcrTaskConcurrency = 2;

  /// Normalizes any value into the supported budget range.
  static int clampOcrTaskConcurrency(int value) {
    if (value < minOcrTaskConcurrency) return minOcrTaskConcurrency;
    if (value > maxOcrTaskConcurrency) return maxOcrTaskConcurrency;
    return value;
  }

  /// Maximum number of app-wide concurrent OCR provider requests.
  ///
  /// This only steers execution scheduling. It never changes OCR recognition
  /// content, explanation retention, typed structure, the review flow, or
  /// final question semantics.
  final int ocrTaskConcurrency;

  /// Reserved: persisted for forward compatibility; no runtime path consumes
  /// it yet, so the settings surface presents it as planned rather than real.
  final bool autoRetryEnabled;

  /// Reserved: persisted for forward compatibility; no runtime path consumes
  /// it yet, so the settings surface presents it as planned rather than real.
  final bool retainUnresolvedFragments;

  /// The concurrency budget inside the supported bounds, whatever value this
  /// instance was constructed with.
  int get effectiveOcrTaskConcurrency =>
      clampOcrTaskConcurrency(ocrTaskConcurrency);

  ImportAdvancedPreferences copyWith({
    int? ocrTaskConcurrency,
    bool? autoRetryEnabled,
    bool? retainUnresolvedFragments,
  }) {
    return ImportAdvancedPreferences(
      ocrTaskConcurrency: ocrTaskConcurrency ?? this.ocrTaskConcurrency,
      autoRetryEnabled: autoRetryEnabled ?? this.autoRetryEnabled,
      retainUnresolvedFragments:
          retainUnresolvedFragments ?? this.retainUnresolvedFragments,
    );
  }

  /// Persists the clamped budget, so a stored payload is always inside the
  /// supported range.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ocrTaskConcurrency': effectiveOcrTaskConcurrency,
      'autoRetryEnabled': autoRetryEnabled,
      'retainUnresolvedFragments': retainUnresolvedFragments,
    };
  }

  /// Tolerant decode: a missing, malformed or unknown payload falls back to
  /// the frozen defaults rather than failing the import settings surface.
  ///
  /// A payload written before the concurrency slider existed carries the
  /// retired `processingStrategy` vocabulary instead; its intent is migrated
  /// (stability -> 1, automatic -> 2, speed -> 4).
  static ImportAdvancedPreferences fromJson(Map<String, dynamic> json) {
    return ImportAdvancedPreferences(
      ocrTaskConcurrency: _decodeOcrTaskConcurrency(json),
      autoRetryEnabled: json['autoRetryEnabled'] is bool
          ? json['autoRetryEnabled'] as bool
          : defaults.autoRetryEnabled,
      retainUnresolvedFragments: json['retainUnresolvedFragments'] is bool
          ? json['retainUnresolvedFragments'] as bool
          : defaults.retainUnresolvedFragments,
    );
  }

  static int _decodeOcrTaskConcurrency(Map<String, dynamic> json) {
    final raw = json['ocrTaskConcurrency'];
    if (raw is num) return clampOcrTaskConcurrency(raw.round());
    final legacy = _legacyStrategyConcurrency(json['processingStrategy']);
    return legacy ?? defaults.ocrTaskConcurrency;
  }

  static int? _legacyStrategyConcurrency(Object? raw) {
    if (raw is! String) return null;
    return switch (raw) {
      'stability' => 1,
      'automatic' => 2,
      'speed' => 4,
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ImportAdvancedPreferences &&
        other.ocrTaskConcurrency == ocrTaskConcurrency &&
        other.autoRetryEnabled == autoRetryEnabled &&
        other.retainUnresolvedFragments == retainUnresolvedFragments;
  }

  @override
  int get hashCode => Object.hash(
        ocrTaskConcurrency,
        autoRetryEnabled,
        retainUnresolvedFragments,
      );
}
