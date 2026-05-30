import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/database/database_helper.dart';

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

  // 断点续传新增字段
  String? sourceType; // 'text' 或 'vision'
  List<String>? pendingChunks;
  List<String>? failedChunks;

  final int createdAt;
  int? completedAt;

  ImportTask({
    required this.id,
    required this.title,
    this.status = TaskStatus.processing,
    this.progressText = '正在准备解析...',
    this.percent = 0.0,
    this.errorMsg,
    this.parsedData,
    this.bankName,
    this.folderName,
    this.sourceType,
    this.pendingChunks,
    this.failedChunks,
    int? createdAt,
    this.completedAt,
  }) : createdAt = createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'status': status.index,
      'progress_text': progressText,
      'percent': percent,
      'error_msg': errorMsg,
      'parsed_data': parsedData != null ? jsonEncode(parsedData) : null,
      'bank_name': bankName,
      'folder_name': folderName,
      'created_at': createdAt,
      'completed_at': completedAt,
      'source_type': sourceType,
      'pending_chunks': pendingChunks != null ? jsonEncode(pendingChunks) : null,
      'failed_chunks': failedChunks != null ? jsonEncode(failedChunks) : null,
    };
  }

  factory ImportTask.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>>? parsed;
    if (map['parsed_data'] != null) {
      try {
        final decoded = jsonDecode(map['parsed_data'] as String);
        if (decoded is List) {
          parsed = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (e) {
        debugPrint('Failed to decode parsed_data: $e');
      }
    }

    final statusIndex = map['status'] as int? ?? 0;
    final status = TaskStatus.values[statusIndex.clamp(0, TaskStatus.values.length - 1)];

    List<String>? pending;
    if (map['pending_chunks'] != null) {
      try {
        final decoded = jsonDecode(map['pending_chunks'] as String);
        if (decoded is List) pending = decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }

    List<String>? failed;
    if (map['failed_chunks'] != null) {
      try {
        final decoded = jsonDecode(map['failed_chunks'] as String);
        if (decoded is List) failed = decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }

    return ImportTask(
      id: map['id'] as String,
      title: map['title'] as String,
      status: status,
      progressText: map['progress_text'] as String? ?? '',
      percent: (map['percent'] as num? ?? 0.0).toDouble(),
      errorMsg: map['error_msg'] as String?,
      parsedData: parsed,
      bankName: map['bank_name'] as String?,
      folderName: map['folder_name'] as String?,
      createdAt: map['created_at'] as int?,
      completedAt: map['completed_at'] as int?,
      sourceType: map['source_type'] as String?,
      pendingChunks: pending,
      failedChunks: failed,
    );
  }
}

class TaskManager extends ChangeNotifier {
  static final TaskManager instance = TaskManager._();
  TaskManager._() {
    _loadTasksFromDb();
  }

  final List<ImportTask> tasks = [];
  int get processingCount => tasks.where((t) => t.status == TaskStatus.processing).length;
  int get pendingCount => tasks.where((t) => t.status == TaskStatus.pendingReview).length;

  Future<void> _loadTasksFromDb() async {
    try {
      // 1. 运行3天前的过期清理 (解析完成或出错后的3天自动清除)
      final threeDaysAgo = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - (3 * 24 * 3600);
      await DatabaseHelper.instance.deleteOldImportTasks(threeDaysAgo);

      // 2. 从数据库加载所有任务
      final maps = await DatabaseHelper.instance.getAllImportTasks();
      tasks.clear();
      for (var map in maps) {
        tasks.add(ImportTask.fromMap(map));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading tasks from SQLite: $e');
    }
  }

  Future<void> _saveTask(ImportTask task) async {
    try {
      await DatabaseHelper.instance.saveImportTask(task.toMap());
    } catch (e) {
      debugPrint('Error saving task to SQLite: $e');
    }
  }

  void addTask(ImportTask task) {
    tasks.insert(0, task);
    _saveTask(task);
    notifyListeners();
  }

  void updateProgress(String id, String text, double percent) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].progressText = text;
      tasks[idx].percent = percent;
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  // 核心新增：将任务挂起为“待校对”
  void requireReview(String id, String text, List<Map<String, dynamic>> data, String bank, String folder) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.pendingReview;
      tasks[idx].progressText = text;
      // 去重：按题干哈希或题号去重，防止多次重试导致重复数据
      tasks[idx].parsedData = _deduplicateQuestions(data);
      tasks[idx].bankName = bank;
      tasks[idx].folderName = folder;
      tasks[idx].percent = 1.0;
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _deduplicateQuestions(List<Map<String, dynamic>> questions) {
    final seen = <String>{};
    final List<Map<String, dynamic>> result = [];
    for (var q in questions) {
      final key = '${q['q_num']}_${q['content']}';
      if (!seen.contains(key)) {
        seen.add(key);
        result.add(q);
      }
    }
    return result;
  }

  // --- 断点续传核心逻辑 ---

  void appendPendingChunks(String id, String sourceType, List<String> chunks) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].sourceType = sourceType;
      tasks[idx].pendingChunks ??= [];
      tasks[idx].pendingChunks!.addAll(chunks);
      _saveTask(tasks[idx]);
    }
  }

  void markChunkSuccess(String id, String chunk, List<Map<String, dynamic>> results) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].pendingChunks?.remove(chunk);
      tasks[idx].parsedData ??= [];
      tasks[idx].parsedData!.addAll(results);
      _saveTask(tasks[idx]);
    }
  }

  void markChunkFailed(String id, String chunk) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].pendingChunks?.remove(chunk);
      tasks[idx].failedChunks ??= [];
      tasks[idx].failedChunks!.add(chunk);
      _saveTask(tasks[idx]);
    }
  }

  void completeTask(String id, String text) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.completed;
      tasks[idx].progressText = text;
      tasks[idx].completedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 清理内存及数据库中的 parsedData 以节省体积
      tasks[idx].parsedData = null; 
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  void failTask(String id, String error) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.error;
      tasks[idx].errorMsg = error;
      tasks[idx].completedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  void deleteTask(String id) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks.removeAt(idx);
      DatabaseHelper.instance.deleteImportTask(id).catchError((e) {
        debugPrint('Error deleting task from SQLite: $e');
      });
      notifyListeners();
    }
  }

  void clearCompleted() {
    tasks.removeWhere((t) => t.status == TaskStatus.completed || t.status == TaskStatus.error);
    DatabaseHelper.instance.clearCompletedImportTasks().catchError((e) {
      debugPrint('Error clearing completed tasks from SQLite: $e');
    });
    notifyListeners();
  }
}
