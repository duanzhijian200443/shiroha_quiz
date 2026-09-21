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

/// The explanation retention policy every **new** document import dispatches.
///
/// Document import no longer offers a retention choice: recognized
/// explanations are always retained into Review, where the user edits or
/// removes them per question. The mode stays a parameter of the pipeline so
/// that tasks persisted by older builds keep being read back through
/// [ImportQuestionFieldPolicy] with their own recorded policy.
///
/// It lives here, next to the policy it fixes, so no widget hardcodes the
/// value and the single authority is reachable from production and tests.
const ExplanationRetentionMode newDocumentImportExplanationRetentionMode =
    ExplanationRetentionMode.allQuestionTypes;

/// Diagnostics key that marks a task created by the document import entry.
///
/// Entry provenance is **not** inferable from the retention mode. Every task
/// dispatched through `ImportTaskCoordinator` records all three retention
/// diagnostics, including single-question photo capture, which still runs at
/// [ExplanationRetentionMode.subjectiveOnly] and still needs the review-time
/// controls that describe that choice. Guessing the entry from retention state
/// would hide the only way to restore a recognized objective explanation on a
/// photo-capture task, so the entry states itself explicitly instead.
///
/// The marker is additive task diagnostics metadata: it needs no schema
/// migration, and tasks that predate it simply read as compatibility tasks.
const String documentImportEntryMarkerKey = '_importEntry';

/// Marker value written by the document import entry.
const String documentImportEntryMarkerValue = 'document_v3';

/// Whether [diagnostics] describe a task created by the document import entry.
///
/// A task without the marker is a compatibility task: it came from photo
/// capture, from the Agent, or from an older build, and it keeps the retention
/// controls that match what its own pipeline recorded.
bool isDocumentImportEntryDiagnostics(Map<String, dynamic>? diagnostics) {
  return diagnostics?[documentImportEntryMarkerKey] ==
      documentImportEntryMarkerValue;
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
