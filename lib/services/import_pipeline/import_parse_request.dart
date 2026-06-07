class ImportParseRequest {
  final List<String> filePaths;
  final List<String> fileNames;
  final bool useVisionEngine;
  final int maxConcurrency;
  final String taskId;

  const ImportParseRequest({
    required this.filePaths,
    required this.fileNames,
    required this.useVisionEngine,
    required this.maxConcurrency,
    required this.taskId,
  });
}
