class ImportParseRequest {
  final List<String> filePaths;
  final List<String> fileNames;
  final bool useVisionEngine;
  final bool useOcrEngine;
  final int maxConcurrency;
  final String taskId;

  const ImportParseRequest({
    required this.filePaths,
    required this.fileNames,
    required this.useVisionEngine,
    this.useOcrEngine = false,
    required this.maxConcurrency,
    required this.taskId,
  });
}
