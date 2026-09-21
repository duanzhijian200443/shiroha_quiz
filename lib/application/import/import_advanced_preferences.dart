/// Loads the durable import execution preferences.
typedef ImportAdvancedPreferencesLoader = Future<ImportAdvancedPreferences>
    Function();

/// Persists the durable import execution preferences.
typedef ImportAdvancedPreferencesSaver = Future<void> Function(
  ImportAdvancedPreferences preferences,
);

enum ImportCompletionBehavior { notifyOnly, openReview }

/// Application-level import execution preferences.
///
/// These are durable app preferences, not per-import state: OCR vs text mode
/// is still chosen per import, and review state never lives here.
class ImportAdvancedPreferences {
  const ImportAdvancedPreferences({
    this.ocrTaskConcurrency = defaultOcrTaskConcurrency,
    this.autoRetryEnabled = true,
    this.ocrRequestTimeoutSeconds = defaultOcrRequestTimeoutSeconds,
    this.autoRepairLatexEnabled = false,
    this.completionBehavior = ImportCompletionBehavior.notifyOnly,
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
  static const int defaultOcrRequestTimeoutSeconds = 90;
  static const List<int> allowedOcrRequestTimeoutSeconds = <int>[
    60,
    90,
    120,
    180,
  ];

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

  /// Enables bounded retries for transient OCR provider failures only.
  final bool autoRetryEnabled;

  /// Per OCR provider network request, not per task or PDF.
  final int ocrRequestTimeoutSeconds;

  /// Generates review repair proposals for eligible LaTeX issues only.
  final bool autoRepairLatexEnabled;

  final ImportCompletionBehavior completionBehavior;

  /// Deprecated compatibility field. No UI or runtime path consumes it.
  final bool retainUnresolvedFragments;

  /// The concurrency budget inside the supported bounds, whatever value this
  /// instance was constructed with.
  int get effectiveOcrTaskConcurrency =>
      clampOcrTaskConcurrency(ocrTaskConcurrency);

  int get effectiveOcrRequestTimeoutSeconds =>
      allowedOcrRequestTimeoutSeconds.contains(ocrRequestTimeoutSeconds)
          ? ocrRequestTimeoutSeconds
          : defaultOcrRequestTimeoutSeconds;

  ImportAdvancedPreferences copyWith({
    int? ocrTaskConcurrency,
    bool? autoRetryEnabled,
    int? ocrRequestTimeoutSeconds,
    bool? autoRepairLatexEnabled,
    ImportCompletionBehavior? completionBehavior,
    bool? retainUnresolvedFragments,
  }) {
    return ImportAdvancedPreferences(
      ocrTaskConcurrency: ocrTaskConcurrency ?? this.ocrTaskConcurrency,
      autoRetryEnabled: autoRetryEnabled ?? this.autoRetryEnabled,
      ocrRequestTimeoutSeconds:
          ocrRequestTimeoutSeconds ?? this.ocrRequestTimeoutSeconds,
      autoRepairLatexEnabled:
          autoRepairLatexEnabled ?? this.autoRepairLatexEnabled,
      completionBehavior: completionBehavior ?? this.completionBehavior,
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
      'ocrRequestTimeoutSeconds': effectiveOcrRequestTimeoutSeconds,
      'autoRepairLatexEnabled': autoRepairLatexEnabled,
      'completionBehavior': completionBehavior.name,
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
      ocrRequestTimeoutSeconds: json['ocrRequestTimeoutSeconds'] is int &&
              allowedOcrRequestTimeoutSeconds
                  .contains(json['ocrRequestTimeoutSeconds'])
          ? json['ocrRequestTimeoutSeconds'] as int
          : defaults.ocrRequestTimeoutSeconds,
      autoRepairLatexEnabled: json['autoRepairLatexEnabled'] is bool
          ? json['autoRepairLatexEnabled'] as bool
          : defaults.autoRepairLatexEnabled,
      completionBehavior: ImportCompletionBehavior.values
              .where((value) => value.name == json['completionBehavior'])
              .firstOrNull ??
          ImportCompletionBehavior.notifyOnly,
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
        other.ocrRequestTimeoutSeconds == ocrRequestTimeoutSeconds &&
        other.autoRepairLatexEnabled == autoRepairLatexEnabled &&
        other.completionBehavior == completionBehavior &&
        other.retainUnresolvedFragments == retainUnresolvedFragments;
  }

  @override
  int get hashCode => Object.hash(
        ocrTaskConcurrency,
        autoRetryEnabled,
        ocrRequestTimeoutSeconds,
        autoRepairLatexEnabled,
        completionBehavior,
        retainUnresolvedFragments,
      );
}
