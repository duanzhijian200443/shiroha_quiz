import 'import_question_field_policy.dart';

class ImportParseResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final bool blocked;
  final String? blockReason;
  final ExplanationRetentionMode explanationRetentionMode;

  const ImportParseResult({
    required this.questions,
    this.warnings = const [],
    this.diagnostics = const {},
    this.blocked = false,
    this.blockReason,
    this.explanationRetentionMode = ExplanationRetentionMode.subjectiveOnly,
  });
}
