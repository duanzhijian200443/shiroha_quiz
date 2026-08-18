enum ImportReviewMetadataProjectionState {
  notProvided,
  available,
  unavailable,
}

class ImportReviewMetadata {
  static const key = '_import_review';
  static const projectionStateKey = '_projectionState';

  final String source; // text / vision / fused / unknown
  final List<String> sources;
  final List<String> fragmentKinds;
  final List<int> originalIndices;
  final List<String> riskHints;
  final List<String> repairCandidateCodes;
  final List<String> latexInvalidFields;

  bool get hasMeaningfulReviewMetadata =>
      source != 'unknown' ||
      sources.isNotEmpty ||
      fragmentKinds.isNotEmpty ||
      originalIndices.isNotEmpty ||
      riskHints.isNotEmpty ||
      repairCandidateCodes.isNotEmpty ||
      latexInvalidFields.isNotEmpty;

  const ImportReviewMetadata({
    required this.source,
    required this.sources,
    required this.fragmentKinds,
    required this.originalIndices,
    required this.riskHints,
    this.repairCandidateCodes = const [],
    this.latexInvalidFields = const [],
  });

  factory ImportReviewMetadata.fromMap(Map<String, dynamic>? map) {
    if (map == null) return ImportReviewMetadata.empty();

    return ImportReviewMetadata(
      source: map['source']?.toString() ?? 'unknown',
      sources: _parseStringList(map['sources']),
      fragmentKinds: _parseStringList(map['fragmentKinds']),
      originalIndices: _parseIntList(map['originalIndices']),
      riskHints: _parseStringList(map['riskHints']),
      repairCandidateCodes: _parseStringList(map['repairCandidateCodes']),
      latexInvalidFields: _parseStringList(map['latexInvalidFields'])
          .where(_isSafeLatexField)
          .toList(growable: false),
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
      repairCandidateCodes: [],
      latexInvalidFields: [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'sources': sources,
      'fragmentKinds': fragmentKinds,
      'originalIndices': originalIndices,
      'riskHints': riskHints,
      'repairCandidateCodes': repairCandidateCodes,
      if (latexInvalidFields.isNotEmpty)
        'latexInvalidFields': latexInvalidFields,
    };
  }

  static bool _isSafeLatexField(String field) {
    return const {
      'content',
      'options',
      'standard_answer',
      'explanation',
    }.contains(field);
  }
}
