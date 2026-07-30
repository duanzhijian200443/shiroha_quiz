import '../../data/models/question_draft.dart';

enum ExplanationRetentionMode {
  subjectiveOnly,
  allQuestionTypes,
}

ExplanationRetentionMode parseExplanationRetentionMode(Object? value) {
  final name = value?.toString();
  for (final mode in ExplanationRetentionMode.values) {
    if (mode.name == name) return mode;
  }
  return ExplanationRetentionMode.subjectiveOnly;
}

enum QuestionExplanationOverride {
  inherit,
  keep,
  discard,
}

/// Owns the distinction between raw explanation provenance and the final
/// explanation that is audited, displayed, and persisted.
class ImportQuestionFieldPolicy {
  const ImportQuestionFieldPolicy();

  Map<String, dynamic> applyToMap(
    Map<String, dynamic> question, {
    ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
    QuestionExplanationOverride override = QuestionExplanationOverride.inherit,
    bool preserveRawExplanation = true,
  }) {
    final type = _readType(question['type']);
    if (!_isKnownType(type)) {
      if (preserveRawExplanation || question['raw_explanation'] == null) {
        return question;
      }
      return <String, dynamic>{...question, 'raw_explanation': null};
    }

    final existingExplanation = _readNonEmpty(question['explanation']);
    final rawExplanation =
        _readNonEmpty(question['raw_explanation']) ?? existingExplanation;
    final retain = shouldRetainExplanation(
      type: type,
      mode: mode,
      override: override,
    );
    final finalExplanation =
        retain ? (existingExplanation ?? rawExplanation ?? '') : '';
    final finalRawExplanation = preserveRawExplanation ? rawExplanation : null;

    if (question['explanation'] == finalExplanation &&
        question['raw_explanation'] == finalRawExplanation) {
      return question;
    }

    return <String, dynamic>{
      ...question,
      'explanation': finalExplanation,
      'raw_explanation': finalRawExplanation,
    };
  }

  List<Map<String, dynamic>> applyToMaps(
    Iterable<Map<String, dynamic>> questions, {
    ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
    List<QuestionExplanationOverride>? overrides,
    bool preserveRawExplanation = true,
  }) {
    final source = questions.toList(growable: false);
    _validateOverrideCount(source.length, overrides);
    return source
        .asMap()
        .entries
        .map(
          (entry) => applyToMap(
            entry.value,
            mode: mode,
            override:
                overrides?[entry.key] ?? QuestionExplanationOverride.inherit,
            preserveRawExplanation: preserveRawExplanation,
          ),
        )
        .toList(growable: false);
  }

  QuestionDraft applyToDraft(
    QuestionDraft question, {
    ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
    QuestionExplanationOverride override = QuestionExplanationOverride.inherit,
    bool preserveRawExplanation = true,
  }) {
    final existingExplanation = _readNonEmpty(question.explanation);
    final rawExplanation =
        _readNonEmpty(question.rawExplanation) ?? existingExplanation;
    final retain = shouldRetainExplanation(
      type: question.type.code,
      mode: mode,
      override: override,
    );
    final finalExplanation =
        retain ? (existingExplanation ?? rawExplanation ?? '') : '';
    final finalRawExplanation = preserveRawExplanation ? rawExplanation : null;

    if (question.explanation == finalExplanation &&
        question.rawExplanation == finalRawExplanation) {
      return question;
    }

    return QuestionDraft(
      type: question.type,
      content: question.content,
      options: question.options,
      standardAnswer: question.standardAnswer,
      explanation: finalExplanation,
      rawExplanation: finalRawExplanation,
    );
  }

  List<QuestionDraft> applyToDrafts(
    Iterable<QuestionDraft> questions, {
    ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
    List<QuestionExplanationOverride>? overrides,
    bool preserveRawExplanation = true,
  }) {
    final source = questions.toList(growable: false);
    _validateOverrideCount(source.length, overrides);
    return source
        .asMap()
        .entries
        .map(
          (entry) => applyToDraft(
            entry.value,
            mode: mode,
            override:
                overrides?[entry.key] ?? QuestionExplanationOverride.inherit,
            preserveRawExplanation: preserveRawExplanation,
          ),
        )
        .toList(growable: false);
  }

  bool shouldRetainExplanation({
    required int? type,
    ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
    QuestionExplanationOverride override = QuestionExplanationOverride.inherit,
  }) {
    switch (override) {
      case QuestionExplanationOverride.keep:
        return true;
      case QuestionExplanationOverride.discard:
        return false;
      case QuestionExplanationOverride.inherit:
        break;
    }

    if (type == QuestionType.shortAnswer.code) return true;
    if (type == 0 || type == 1 || type == QuestionType.fillBlank.code) {
      return mode == ExplanationRetentionMode.allQuestionTypes;
    }
    return true;
  }

  void _validateOverrideCount(
    int questionCount,
    List<QuestionExplanationOverride>? overrides,
  ) {
    if (overrides != null && overrides.length != questionCount) {
      throw ArgumentError.value(
        overrides.length,
        'overrides.length',
        'must match question count $questionCount',
      );
    }
  }

  bool _isKnownType(int? type) =>
      type == 0 ||
      type == 1 ||
      type == QuestionType.fillBlank.code ||
      type == QuestionType.shortAnswer.code;

  String? _readNonEmpty(dynamic value) {
    final text = value?.toString();
    return text == null || text.trim().isEmpty ? null : text;
  }

  int? _readType(dynamic value) {
    return switch (value) {
      final int raw => raw,
      final num raw => raw.toInt(),
      final String raw => int.tryParse(raw.trim()),
      _ => null,
    };
  }
}
