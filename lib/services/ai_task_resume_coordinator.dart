import 'task_manager.dart';

typedef TextBatchResumeParser = Future<List<Map<String, dynamic>>> Function(
  List<String> pendingChunks, {
  String? taskId,
});

typedef VisionImageResumeParser = Future<List<Map<String, dynamic>>> Function(
  List<String> imagePaths,
);

class AiTaskResumeCoordinator {
  AiTaskResumeCoordinator({
    required TextBatchResumeParser parseTextBatches,
    required VisionImageResumeParser parseVisionImages,
    TaskManager? taskManager,
  })  : _parseTextBatches = parseTextBatches,
        _parseVisionImages = parseVisionImages,
        _taskManager = taskManager ?? TaskManager.instance;

  final TextBatchResumeParser _parseTextBatches;
  final VisionImageResumeParser _parseVisionImages;
  final TaskManager _taskManager;

  Future<void> resume(String taskId) async {
    final task = _taskManager.tasks.firstWhere((task) => task.id == taskId);
    task.status = TaskStatus.processing;
    _taskManager.updateProgress(taskId, '正在继续执行断点重传...', task.percent);

    switch (task.sourceType) {
      case 'text':
        await _resumeTextTask(taskId, task);
        return;
      case 'vision':
        await _resumeVisionTask(taskId, task);
        return;
      default:
        _taskManager.failTask(
            taskId, '无法恢复未知类型的导入任务: ${task.sourceType ?? 'unknown'}');
    }
  }

  Future<void> _resumeTextTask(String taskId, ImportTask task) async {
    final pending = List<String>.from(task.pendingChunks ?? []);
    try {
      await _parseTextBatches(pending, taskId: taskId);
      _markReadyForReview(taskId);
    } catch (e) {
      _taskManager.failTask(taskId, e.toString());
    }
  }

  Future<void> _resumeVisionTask(String taskId, ImportTask task) async {
    final pending = List<String>.from(task.pendingChunks ?? []);
    try {
      for (final path in pending) {
        final results = await _parseVisionImages([path]);
        _taskManager.markChunkSuccess(taskId, path, results);
      }
      _markReadyForReview(taskId);
    } catch (e) {
      _taskManager.failTask(taskId, e.toString());
    }
  }

  void _markReadyForReview(String taskId) {
    final updatedTask =
        _taskManager.tasks.firstWhere((task) => task.id == taskId);
    _taskManager.requireReview(
      taskId,
      '恢复解析成功，请校对入库',
      updatedTask.parsedData ?? [],
      updatedTask.bankName ?? '',
      updatedTask.folderName ?? '',
    );
  }
}
