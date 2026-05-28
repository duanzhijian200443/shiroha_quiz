import 'package:flutter/material.dart';

enum TaskStatus { processing, pendingReview, completed, error }

class ImportTask {
  final String id;
  final String title;
  TaskStatus status;
  String progressText;
  double percent;
  String? errorMsg;
  
  // 核心新增：暂存大模型解析出的脏数据和目标题库信息
  List<Map<String, dynamic>>? parsedData;
  String? bankName;
  String? folderName;

  ImportTask({
    required this.id, required this.title, this.status = TaskStatus.processing,
    this.progressText = '正在准备解析...', this.percent = 0.0, this.errorMsg,
    this.parsedData, this.bankName, this.folderName,
  });
}

class TaskManager extends ChangeNotifier {
  static final TaskManager instance = TaskManager._();
  TaskManager._();

  final List<ImportTask> tasks = [];
  int get processingCount => tasks.where((t) => t.status == TaskStatus.processing).length;
  int get pendingCount => tasks.where((t) => t.status == TaskStatus.pendingReview).length;

  void addTask(ImportTask task) {
    tasks.insert(0, task);
    notifyListeners();
  }

  void updateProgress(String id, String text, double percent) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) { tasks[idx].progressText = text; tasks[idx].percent = percent; notifyListeners(); }
  }

  // 核心新增：将任务挂起为“待校对”
  void requireReview(String id, String text, List<Map<String, dynamic>> data, String bank, String folder) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.pendingReview;
      tasks[idx].progressText = text;
      tasks[idx].parsedData = data;
      tasks[idx].bankName = bank;
      tasks[idx].folderName = folder;
      tasks[idx].percent = 1.0;
      notifyListeners();
    }
  }

  void completeTask(String id, String text) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.completed;
      tasks[idx].progressText = text;
      // 清理内存
      tasks[idx].parsedData = null; 
      notifyListeners();
    }
  }

  void failTask(String id, String error) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) { tasks[idx].status = TaskStatus.error; tasks[idx].errorMsg = error; notifyListeners(); }
  }

  void clearCompleted() {
    tasks.removeWhere((t) => t.status == TaskStatus.completed || t.status == TaskStatus.error);
    notifyListeners();
  }
}
