import 'import_question_field_policy.dart';

enum ImportParseMode { text, vision, ocr }

class ImportParseRequest {
  final List<String> filePaths;
  final List<String> fileNames;
  final ImportParseMode mode;
  final int maxConcurrency;
  final String taskId;
  final ExplanationRetentionMode explanationRetentionMode;

  // Phase-one compatibility bridge for the existing two-route pipeline.
  // OCR keeps the current OCR-first/vision-fallback behavior until routing is
  // migrated to [mode] in the next phase.
  bool get useVisionEngine => mode != ImportParseMode.text;

  const ImportParseRequest({
    required this.filePaths,
    required this.fileNames,
    required this.mode,
    required this.maxConcurrency,
    required this.taskId,
    this.explanationRetentionMode = ExplanationRetentionMode.subjectiveOnly,
  });
}
