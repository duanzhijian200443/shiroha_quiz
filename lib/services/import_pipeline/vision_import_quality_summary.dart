/// Aggregates `vision_quality_gate_file_*` diagnostics across multiple files
/// into a single top-level summary for the import staging UI.
class VisionImportQualitySummary {
  final bool hasLowQualityVisionParse;
  final int total;
  final int riskyCount;
  final int lowQualityFileCount;
  final Map<String, int> issueCounts;
  final String? recommendedAction;

  const VisionImportQualitySummary({
    required this.hasLowQualityVisionParse,
    required this.total,
    required this.riskyCount,
    required this.lowQualityFileCount,
    required this.issueCounts,
    this.recommendedAction,
  });

  static const empty = VisionImportQualitySummary(
    hasLowQualityVisionParse: false,
    total: 0,
    riskyCount: 0,
    lowQualityFileCount: 0,
    issueCounts: const {},
  );

  Map<String, dynamic> toDiagnostics() {
    return {
      'hasLowQualityVisionParse': hasLowQualityVisionParse,
      'total': total,
      'riskyCount': riskyCount,
      'lowQualityFileCount': lowQualityFileCount,
      if (issueCounts.isNotEmpty) 'issueCounts': issueCounts,
      if (recommendedAction != null) 'recommendedAction': recommendedAction,
    };
  }

  /// Collects all `vision_quality_gate_file_*` entries from [diagnostics]
  /// and produces a single aggregated summary.
  factory VisionImportQualitySummary.fromDiagnostics(
      Map<String, dynamic> diagnostics) {
    final gateEntries = diagnostics.entries
        .where((e) => e.key.startsWith('vision_quality_gate_file_'))
        .where((e) => e.value is Map)
        .toList();

    if (gateEntries.isEmpty) return VisionImportQualitySummary.empty;

    var total = 0;
    var riskyCount = 0;
    var lowQualityFileCount = 0;
    bool hasLowQuality = false;
    final mergedIssueCounts = <String, int>{};

    for (final entry in gateEntries) {
      final gate = entry.value as Map;
      total += _readInt(gate['total']);
      final fileRiskyCount = _readInt(gate['riskyCount']);
      riskyCount += fileRiskyCount;
      if (gate['lowQuality'] == true) {
        lowQualityFileCount++;
        hasLowQuality = true;
      }
      final counts = gate['issueCounts'];
      if (counts is Map) {
        for (final issueEntry in counts.entries) {
          final key = issueEntry.key.toString();
          final count = _readInt(issueEntry.value);
          mergedIssueCounts[key] = (mergedIssueCounts[key] ?? 0) + count;
        }
      }
    }

    return VisionImportQualitySummary(
      hasLowQualityVisionParse: hasLowQuality,
      total: total,
      riskyCount: riskyCount,
      lowQualityFileCount: lowQualityFileCount,
      issueCounts: mergedIssueCounts,
      recommendedAction:
          hasLowQuality ? 'review_or_retry_stronger_vision' : null,
    );
  }

  static int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
