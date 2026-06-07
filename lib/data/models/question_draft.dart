import 'dart:convert';

enum QuestionType {
  singleChoice(0, '选择题'),
  fillBlank(2, '填空题'),
  shortAnswer(3, '简答题');

  const QuestionType(this.code, this.displayName);

  final int code;
  final String displayName;

  static QuestionType fromValue(dynamic value) {
    final code = switch (value) {
      final int raw => raw,
      final num raw => raw.toInt(),
      final String raw => int.tryParse(raw.trim()),
      _ => null,
    };

    return switch (code) {
      2 => QuestionType.fillBlank,
      3 => QuestionType.shortAnswer,
      _ => QuestionType.singleChoice,
    };
  }
}

class QuestionDraft {
  const QuestionDraft({
    required this.type,
    required this.content,
    required this.options,
    required this.standardAnswer,
    required this.explanation,
    this.rawExplanation,
  });

  final QuestionType type;
  final String content;
  final List<String> options;
  final String standardAnswer;
  final String explanation;
  final String? rawExplanation;

  QuestionDraft copyWith({
    QuestionType? type,
    String? content,
    List<String>? options,
    String? standardAnswer,
    String? explanation,
    String? rawExplanation,
  }) {
    return QuestionDraft(
      type: type ?? this.type,
      content: content ?? this.content,
      options: options ?? this.options,
      standardAnswer: standardAnswer ?? this.standardAnswer,
      explanation: explanation ?? this.explanation,
      rawExplanation: rawExplanation ?? this.rawExplanation,
    );
  }

  bool get hasAnswerOrExplanation =>
      standardAnswer.trim().isNotEmpty || explanation.trim().isNotEmpty;

  factory QuestionDraft.fromMap(Map<String, dynamic> map) {
    return QuestionDraft(
      type: QuestionType.fromValue(map['type']),
      content: _readString(map['content'], fallbackText: '无题干'),
      options: _readOptions(map['options']),
      standardAnswer: _readString(
        map['standard_answer'],
        fallback: map['answer'],
      ),
      explanation: _readString(map['explanation']),
      rawExplanation: _readNullableString(map['raw_explanation']),
    );
  }

  static List<QuestionDraft> listFromMaps(List<Map<String, dynamic>> maps) {
    return maps.map(QuestionDraft.fromMap).toList(growable: false);
  }

  Map<String, dynamic> toMap() {
    return {
      'type': type.code,
      'content': content,
      'options': options,
      'standard_answer': standardAnswer,
      'explanation': explanation,
      'raw_explanation': rawExplanation,
    };
  }

  static List<String> _readOptions(dynamic value) {
    if (value is List) {
      return value.map((option) => option.toString()).toList(growable: false);
    }

    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) return _readOptions(decoded);
      } catch (_) {
        return [value];
      }
    }

    return const <String>[];
  }

  static String _readString(
    dynamic value, {
    dynamic fallback,
    String fallbackText = '',
  }) {
    final primary = value?.toString().trim();
    if (primary != null && primary.isNotEmpty) return primary;

    final fallbackValue = fallback?.toString().trim();
    if (fallbackValue != null && fallbackValue.isNotEmpty) {
      return fallbackValue;
    }

    return fallbackText;
  }

  static String? _readNullableString(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
