import '../../data/models/import_question_validation.dart';

/// Pure structural routing shared by parsing and staging finalization.
class ImportQuestionRepairPolicy {
  const ImportQuestionRepairPolicy();

  static const metadataKey = 'repairCandidateCodes';
  static const danglingLatexCode = 'dangling_latex';

  List<String> candidateCodes(
    Map<String, dynamic> question, {
    Iterable<String> diagnostics = const [],
    bool requireAnswer = false,
  }) {
    final diagnosticSet = diagnostics.toSet();
    final riskHints = _readRiskHints(question);
    final type = _readInt(question['type']);
    final isChoice = type == 0 || type == 1;
    final codes = <String>{};

    if (_readString(question['content']).isEmpty ||
        diagnosticSet.contains('empty_content')) {
      codes.add('empty_content');
    }
    if (isChoice &&
        (meaningfulOptions(_readOptions(question['options'])).length < 2 ||
            diagnosticSet.contains('choice_options_less_than_2'))) {
      codes.add('choice_options_less_than_2');
    }
    if (diagnosticSet.contains(danglingLatexCode) ||
        riskHints.contains('latex_unrenderable')) {
      codes.add(danglingLatexCode);
    }
    if (requireAnswer &&
        isChoice &&
        !isMeaningfulAnswer(_readString(question['standard_answer']))) {
      codes.add('choice_missing_answer');
    }

    return codes.toList()..sort();
  }

  Map<String, dynamic> syncCandidateMetadata(
    Map<String, dynamic> question, {
    Iterable<String> diagnostics = const [],
    bool requireAnswer = false,
  }) {
    final next = Map<String, dynamic>.from(question);
    final rawMetadata = question['_import_review'];
    final metadata = rawMetadata is Map
        ? Map<String, dynamic>.fromEntries(
            rawMetadata.entries.map(
              (entry) => MapEntry(entry.key.toString(), entry.value),
            ),
          )
        : <String, dynamic>{};
    metadata[metadataKey] = candidateCodes(
      question,
      diagnostics: diagnostics,
      requireAnswer: requireAnswer,
    );
    next['_import_review'] = metadata;
    return next;
  }

  Set<String> _readRiskHints(Map<String, dynamic> question) {
    final metadata = question['_import_review'];
    final rawHints = metadata is Map ? metadata['riskHints'] : null;
    return rawHints is List
        ? rawHints.map((item) => item.toString()).toSet()
        : <String>{};
  }

  List<String> _readOptions(Object? value) {
    return value is List
        ? value.map((item) => item.toString()).toList(growable: false)
        : const <String>[];
  }

  String _readString(Object? value) => value?.toString().trim() ?? '';

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return value is String ? int.tryParse(value.trim()) : null;
  }
}
