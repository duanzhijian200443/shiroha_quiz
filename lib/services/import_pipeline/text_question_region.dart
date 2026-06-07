enum TextQuestionKind {
  choice,
  multiChoice,
  trueFalse,
  fillBlank,
  subjective,
  unknown,
}

enum RegionHealth {
  clean,
  repairable,
  rejected,
}

class TextQuestionRegion {
  final int number;
  final String rawText;
  final int startOffset;
  final int endOffset;
  final String? answerText;
  final TextQuestionKind kind;
  final RegionHealth health;
  final List<String> diagnostics;

  const TextQuestionRegion({
    required this.number,
    required this.rawText,
    required this.startOffset,
    required this.endOffset,
    this.answerText,
    required this.kind,
    required this.health,
    this.diagnostics = const [],
  });

  TextQuestionRegion copyWith({
    int? number,
    String? rawText,
    int? startOffset,
    int? endOffset,
    String? answerText,
    TextQuestionKind? kind,
    RegionHealth? health,
    List<String>? diagnostics,
  }) {
    return TextQuestionRegion(
      number: number ?? this.number,
      rawText: rawText ?? this.rawText,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      answerText: answerText ?? this.answerText,
      kind: kind ?? this.kind,
      health: health ?? this.health,
      diagnostics: diagnostics ?? this.diagnostics,
    );
  }
}
