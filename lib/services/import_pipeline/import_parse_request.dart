import 'import_question_field_policy.dart';

enum ImportParseMode { text, vision, ocr }

class ImportParseRequest {
  final List<String> filePaths;
  final List<String> fileNames;
  final ImportParseMode mode;

  /// Parallelism budget recorded for this task.
  ///
  /// Vision mode uses it as its page-batch parallelism. OCR mode does not: its
  /// files are always parsed one after another. The shared OCR scheduler uses
  /// the current app preference for provider admission across all callers.
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
