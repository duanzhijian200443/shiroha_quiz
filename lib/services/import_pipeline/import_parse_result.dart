class ImportParseResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final bool blocked;
  final String? blockReason;

  const ImportParseResult({
    required this.questions,
    this.warnings = const [],
    this.diagnostics = const {},
    this.blocked = false,
    this.blockReason,
  });
}
