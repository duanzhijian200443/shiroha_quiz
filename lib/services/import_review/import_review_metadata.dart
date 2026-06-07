class ImportReviewMetadata {
  static const key = '_import_review';

  final String source; // text / vision / fused / unknown
  final List<String> sources;
  final List<String> fragmentKinds;
  final List<int> originalIndices;
  final List<String> riskHints;

  const ImportReviewMetadata({
    required this.source,
    required this.sources,
    required this.fragmentKinds,
    required this.originalIndices,
    required this.riskHints,
  });

  factory ImportReviewMetadata.fromMap(Map<String, dynamic>? map) {
    if (map == null) return ImportReviewMetadata.empty();

    return ImportReviewMetadata(
      source: map['source']?.toString() ?? 'unknown',
      sources: _parseStringList(map['sources']),
      fragmentKinds: _parseStringList(map['fragmentKinds']),
      originalIndices: _parseIntList(map['originalIndices']),
      riskHints: _parseStringList(map['riskHints']),
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static List<int> _parseIntList(dynamic value) {
    if (value is! List) return const [];
    final result = <int>[];
    for (final e in value) {
      if (e == null) continue;
      if (e is int) {
        result.add(e);
      } else if (e is num) {
        result.add(e.toInt());
      } else if (e is String) {
        final parsed = int.tryParse(e);
        if (parsed != null) result.add(parsed);
      }
    }
    return result;
  }

  factory ImportReviewMetadata.empty() {
    return const ImportReviewMetadata(
      source: 'unknown',
      sources: [],
      fragmentKinds: [],
      originalIndices: [],
      riskHints: [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'sources': sources,
      'fragmentKinds': fragmentKinds,
      'originalIndices': originalIndices,
      'riskHints': riskHints,
    };
  }
}
