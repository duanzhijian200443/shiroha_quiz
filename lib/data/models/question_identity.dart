class QuestionIdentity {
  const QuestionIdentity({
    required this.normalizedQuestionNumber,
    required this.normalizedContent,
    required this.type,
  });

  final String normalizedQuestionNumber;
  final String normalizedContent;
  final int? type;

  factory QuestionIdentity.fromMap(Map<String, dynamic> question) {
    return QuestionIdentity(
      normalizedQuestionNumber: normalizeQuestionNumber(question['q_num']),
      normalizedContent: normalizeContent(question['content']),
      type: _readInt(question['type']),
    );
  }

  static String normalizeQuestionNumber(dynamic raw) {
    if (raw == null) return '';
    var normalized = raw.toString().trim();
    if (normalized.isEmpty) return '';
    normalized = normalized.replaceAll(RegExp(r'[.。、）\)：:]+$'), '');
    normalized = normalized.replaceAll(RegExp(r'^(?:第)?\s*'), '');
    normalized = normalized.replaceAll(RegExp(r'\s*(?:题)$'), '');
    const numberMap = {
      '一': '1',
      '二': '2',
      '三': '3',
      '四': '4',
      '五': '5',
      '六': '6',
      '七': '7',
      '八': '8',
      '九': '9',
      '十': '10',
    };
    for (final entry in numberMap.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized.trim().toLowerCase();
  }

  static String normalizeContent(dynamic raw) {
    return raw
            ?.toString()
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .toLowerCase() ??
        '';
  }

  static int? _readInt(dynamic value) {
    return switch (value) {
      final int raw => raw,
      final num raw => raw.toInt(),
      final String raw => int.tryParse(raw.trim()),
      _ => null,
    };
  }

  bool get hasQuestionNumber => normalizedQuestionNumber.isNotEmpty;
  bool get hasContent => normalizedContent.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is QuestionIdentity &&
        normalizedQuestionNumber == other.normalizedQuestionNumber &&
        normalizedContent == other.normalizedContent &&
        type == other.type;
  }

  @override
  int get hashCode => Object.hash(
        normalizedQuestionNumber,
        normalizedContent,
        type,
      );
}
