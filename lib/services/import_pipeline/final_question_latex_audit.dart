import 'import_question_field_policy.dart';
import 'import_question_repair_policy.dart';
import 'latex_sanity_checker.dart';
import 'ocr_safe_html_cleanup.dart';

const String latexUnrenderableIssue = 'latex_unrenderable';
const String rawHtmlTagIssue = 'raw_html_tag';
const Set<String> _derivedDiagnosticCodes = {
  latexUnrenderableIssue,
  rawHtmlTagIssue,
  'dangling_latex',
  'unsafe_html_content_removed',
  'unsupported_html_tag_preserved',
};

List<String> clearDerivedImportDiagnostics(
  Iterable<String> diagnostics,
) {
  return diagnostics
      .where((diagnostic) => !_derivedDiagnosticCodes.contains(diagnostic))
      .toSet()
      .toList();
}

class FinalQuestionLatexAuditResult {
  const FinalQuestionLatexAuditResult({
    required this.question,
    required this.invalidFields,
  });

  final Map<String, dynamic> question;
  final List<String> invalidFields;

  bool get hasUnrenderableLatex => invalidFields.isNotEmpty;
}

FinalQuestionLatexAuditResult auditFinalQuestionLatex(
  Map<String, dynamic> question, {
  LatexSanityChecker checker = const LatexSanityChecker(),
}) {
  Map<String, dynamic>? repairedQuestion;

  void repairStringField(String key) {
    final value = question[key];
    if (value is! String) return;
    final repaired = repairLatexDeterministically(value);
    if (repaired == value) return;
    repairedQuestion ??= Map<String, dynamic>.from(question);
    repairedQuestion![key] = repaired;
  }

  for (final key in const ['content', 'standard_answer', 'explanation']) {
    repairStringField(key);
  }

  final originalOptions = question['options'];
  if (originalOptions is List) {
    final repairedOptions = originalOptions
        .map(
          (option) =>
              option is String ? repairLatexDeterministically(option) : option,
        )
        .toList(growable: false);
    for (var index = 0; index < originalOptions.length; index++) {
      if (repairedOptions[index] != originalOptions[index]) {
        repairedQuestion ??= Map<String, dynamic>.from(question);
        repairedQuestion!['options'] = repairedOptions;
        break;
      }
    }
  }

  final candidate = repairedQuestion ?? question;
  final invalidFields = <String>[];

  void auditStringField(String key) {
    final value = candidate[key];
    if (value is String && checker.hasDanglingDelimiters(value)) {
      invalidFields.add(key);
    }
  }

  auditStringField('content');

  final options = candidate['options'];
  if (options is List &&
      options.whereType<String>().any(checker.hasDanglingDelimiters)) {
    invalidFields.add('options');
  }

  auditStringField('standard_answer');
  auditStringField('explanation');

  if (invalidFields.isEmpty) {
    return FinalQuestionLatexAuditResult(
      question: candidate,
      invalidFields: const [],
    );
  }

  final auditedQuestion = Map<String, dynamic>.from(candidate);
  final rawMetadata = candidate['_import_review'];
  final metadata = rawMetadata is Map
      ? Map<String, dynamic>.fromEntries(
          rawMetadata.entries.map(
            (entry) => MapEntry(entry.key.toString(), entry.value),
          ),
        )
      : <String, dynamic>{};
  final rawHints = metadata['riskHints'];
  final riskHints = rawHints is List
      ? rawHints.map((hint) => hint.toString()).toSet()
      : <String>{};
  riskHints.add(latexUnrenderableIssue);
  metadata['riskHints'] = riskHints.toList()..sort();
  auditedQuestion['_import_review'] = metadata;

  return FinalQuestionLatexAuditResult(
    question: auditedQuestion,
    invalidFields: List.unmodifiable(invalidFields),
  );
}

List<Map<String, dynamic>> auditFinalQuestionsLatex(
  Iterable<Map<String, dynamic>> questions,
) {
  return questions
      .map((question) => auditFinalQuestionLatex(question).question)
      .toList(growable: false);
}

Map<String, dynamic> finalizeAndAuditImportQuestion(
  Map<String, dynamic> question, {
  ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
  QuestionExplanationOverride override = QuestionExplanationOverride.inherit,
  ImportQuestionFieldPolicy fieldPolicy = const ImportQuestionFieldPolicy(),
  bool preserveRawExplanation = true,
}) {
  final retained = fieldPolicy.applyToMap(
    question,
    mode: mode,
    override: override,
    preserveRawExplanation: preserveRawExplanation,
  );
  final cleared = _clearDerivedDiagnostics(retained);
  final htmlCleaned = _cleanupFinalHtmlFields(cleared);
  var audited = auditFinalQuestionLatex(htmlCleaned).question;

  if (_finalFieldsContainRawHtml(audited)) {
    audited = _addRiskHint(audited, rawHtmlTagIssue);
  }
  return const ImportQuestionRepairPolicy().syncCandidateMetadata(audited);
}

List<Map<String, dynamic>> finalizeAndAuditImportQuestions(
  Iterable<Map<String, dynamic>> questions, {
  ExplanationRetentionMode mode = ExplanationRetentionMode.subjectiveOnly,
  List<QuestionExplanationOverride>? overrides,
  ImportQuestionFieldPolicy fieldPolicy = const ImportQuestionFieldPolicy(),
  bool preserveRawExplanation = true,
}) {
  final source = questions.toList(growable: false);
  if (overrides != null && overrides.length != source.length) {
    throw ArgumentError.value(
      overrides.length,
      'overrides.length',
      'must match question count ${source.length}',
    );
  }
  return source
      .asMap()
      .entries
      .map(
        (entry) => finalizeAndAuditImportQuestion(
          entry.value,
          mode: mode,
          override:
              overrides?[entry.key] ?? QuestionExplanationOverride.inherit,
          fieldPolicy: fieldPolicy,
          preserveRawExplanation: preserveRawExplanation,
        ),
      )
      .toList(growable: false);
}

Map<String, dynamic> _clearDerivedDiagnostics(
  Map<String, dynamic> question,
) {
  Map<String, dynamic>? next;
  final rawDiagnostics = question['diagnostics'];
  if (rawDiagnostics is List) {
    final diagnostics = rawDiagnostics
        .map((item) => item.toString())
        .where((item) => !_derivedDiagnosticCodes.contains(item))
        .toList(growable: false);
    if (diagnostics.length != rawDiagnostics.length) {
      next = Map<String, dynamic>.from(question);
      next['diagnostics'] = diagnostics;
    }
  }

  final source = next ?? question;
  final rawMetadata = source['_import_review'];
  if (rawMetadata is! Map) return source;
  final metadata = Map<String, dynamic>.fromEntries(
    rawMetadata.entries.map(
      (entry) => MapEntry(entry.key.toString(), entry.value),
    ),
  );
  final rawHints = metadata['riskHints'];
  if (rawHints is! List) return source;
  final hints = rawHints
      .map((hint) => hint.toString())
      .where((hint) => !_derivedDiagnosticCodes.contains(hint))
      .toSet()
      .toList()
    ..sort();
  if (hints.length == rawHints.length) return source;

  next ??= Map<String, dynamic>.from(question);
  metadata['riskHints'] = hints;
  next['_import_review'] = metadata;
  return next;
}

Map<String, dynamic> _cleanupFinalHtmlFields(
  Map<String, dynamic> question,
) {
  Map<String, dynamic>? next;
  final diagnostics = <String>{
    if (question['diagnostics'] is List)
      ...(question['diagnostics'] as List).map((item) => item.toString()),
  };

  void cleanStringField(String key) {
    final value = question[key];
    if (value is! String) return;
    final cleaned = stripSafeHtmlWrappers(value);
    diagnostics.addAll(cleaned.diagnostics);
    if (cleaned.text == value) return;
    next ??= Map<String, dynamic>.from(question);
    next![key] = cleaned.text;
  }

  for (final key in const ['content', 'standard_answer', 'explanation']) {
    cleanStringField(key);
  }

  final rawOptions = question['options'];
  if (rawOptions is List) {
    final cleanedOptions = rawOptions.map((option) {
      if (option is! String) return option;
      final cleaned = stripSafeHtmlWrappers(option);
      diagnostics.addAll(cleaned.diagnostics);
      return cleaned.text;
    }).toList(growable: false);
    if (!_sameList(rawOptions, cleanedOptions)) {
      next ??= Map<String, dynamic>.from(question);
      next!['options'] = cleanedOptions;
    }
  }

  final originalDiagnostics = question['diagnostics'];
  final diagnosticsList = diagnostics.toList()..sort();
  if (originalDiagnostics is! List ||
      !_sameList(originalDiagnostics, diagnosticsList)) {
    next ??= Map<String, dynamic>.from(question);
    next!['diagnostics'] = diagnosticsList;
  }
  return next ?? question;
}

bool _finalFieldsContainRawHtml(Map<String, dynamic> question) {
  for (final key in const ['content', 'standard_answer', 'explanation']) {
    final value = question[key];
    if (value is String && containsRawHtmlTag(value)) return true;
  }
  final options = question['options'];
  return options is List && options.whereType<String>().any(containsRawHtmlTag);
}

Map<String, dynamic> _addRiskHint(
  Map<String, dynamic> question,
  String hint,
) {
  final next = Map<String, dynamic>.from(question);
  final rawMetadata = question['_import_review'];
  final metadata = rawMetadata is Map
      ? Map<String, dynamic>.fromEntries(
          rawMetadata.entries.map(
            (entry) => MapEntry(entry.key.toString(), entry.value),
          ),
        )
      : <String, dynamic>{};
  final rawHints = metadata['riskHints'];
  final hints = rawHints is List
      ? rawHints.map((item) => item.toString()).toSet()
      : <String>{};
  hints.add(hint);
  metadata['riskHints'] = hints.toList()..sort();
  next['_import_review'] = metadata;
  return next;
}

bool _sameList(List<dynamic> left, List<dynamic> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
