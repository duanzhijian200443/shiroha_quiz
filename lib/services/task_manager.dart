import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_snapshot_policy.dart';

enum TaskStatus { processing, pendingReview, completed, error }

extension TaskStatusX on TaskStatus {
  bool get isFinalState =>
      this == TaskStatus.completed || this == TaskStatus.error;
}

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

  // 4-H 新增：导入过程中的警告和诊断详情
  List<String>? warnings;
  Map<String, dynamic>? diagnostics;

  // 诊断元数据快捷获取
  String? get traceId => diagnostics?[TaskManager.keyTraceId]?.toString();
  String? get parseMode => diagnostics?[TaskManager.keyParseMode]?.toString();
  ExplanationRetentionMode get explanationRetentionMode =>
      parseExplanationRetentionMode(
        diagnostics?[TaskManager.keyExplanationRetentionMode],
      );
  Duration get elapsed {
    if (status == TaskStatus.processing) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return Duration(seconds: (now - createdAt).clamp(0, 1 << 31));
    }
    final end = completedAt ?? createdAt;
    return Duration(seconds: (end - createdAt).clamp(0, 1 << 31));
  }

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
    this.warnings,
    this.diagnostics,
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
      'pending_chunks':
          pendingChunks != null ? jsonEncode(pendingChunks) : null,
      'failed_chunks': failedChunks != null ? jsonEncode(failedChunks) : null,
      'warnings': warnings != null ? jsonEncode(warnings) : null,
      'diagnostics': diagnostics != null ? jsonEncode(diagnostics) : null,
    };
  }

  factory ImportTask.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>>? parsed;
    if (map['parsed_data'] != null) {
      try {
        final decoded = jsonDecode(map['parsed_data'] as String);
        if (decoded is List) {
          parsed =
              decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (e) {
        debugPrint('Failed to decode parsed_data: $e');
      }
    }

    final statusIndex = map['status'] as int? ?? 0;
    final status =
        TaskStatus.values[statusIndex.clamp(0, TaskStatus.values.length - 1)];

    List<String>? pending;
    if (map['pending_chunks'] != null) {
      try {
        final decoded = jsonDecode(map['pending_chunks'] as String);
        if (decoded is List) {
          pending = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    List<String>? failed;
    if (map['failed_chunks'] != null) {
      try {
        final decoded = jsonDecode(map['failed_chunks'] as String);
        if (decoded is List) {
          failed = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    List<String>? warningsList;
    if (map['warnings'] != null) {
      try {
        final decoded = jsonDecode(map['warnings'] as String);
        if (decoded is List) {
          warningsList = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    Map<String, dynamic>? diagnosticsMap;
    if (map['diagnostics'] != null) {
      try {
        final decoded = jsonDecode(map['diagnostics'] as String);
        if (decoded is Map) {
          diagnosticsMap = Map<String, dynamic>.from(decoded);
        }
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
      warnings: warningsList,
      diagnostics: diagnosticsMap,
    );
  }
}

enum ReviewDraftSaveStatus { saved, stale, taskMissing, itemMissing, failed }

class ReviewDraftSaveResult {
  const ReviewDraftSaveResult(this.status, {required this.revision});

  final ReviewDraftSaveStatus status;
  final int revision;

  bool get saved => status == ReviewDraftSaveStatus.saved;
}

class TaskManager extends ChangeNotifier {
  static const String keyTraceId = '_traceId';
  static const String keyParseMode = '_parseMode';
  static const String keyExplanationRetentionMode = '_explanationRetentionMode';
  static const String keyReviewDraftRevision = '_reviewDraftRevision';
  static const String keyReviewItemId = '_reviewItemId';
  static const String keyAnswerDistillationStatus =
      '_answer_distillation_status';
  static const String keyAnswerDistillationReason =
      '_answer_distillation_reason';

  static final TaskManager _instance = TaskManager._internal();
  static TaskManager get instance => _instance;

  TaskManager._internal()
      : _persistTasks = true,
        _saveTaskOverride = null {
    ready = _loadTasksFromDb();
  }

  @visibleForTesting
  TaskManager.forTesting({
    Future<void> Function(Map<String, dynamic> taskMap)? saveTask,
  })  : _persistTasks = saveTask != null,
        _saveTaskOverride = saveTask {
    ready = Future<void>.value();
  }

  late final Future<void> ready;
  final bool _persistTasks;
  final Future<void> Function(Map<String, dynamic> taskMap)? _saveTaskOverride;
  Future<void> _reviewDraftWriteTail = Future<void>.value();

  final List<ImportTask> tasks = [];
  int get processingCount =>
      tasks.where((t) => t.status == TaskStatus.processing).length;
  int get pendingCount =>
      tasks.where((t) => t.status == TaskStatus.pendingReview).length;

  Future<void> _loadTasksFromDb() async {
    try {
      final threeDaysAgo = DateTime.now()
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch ~/
          1000;
      await ImportTaskRepository.instance.deleteOldImportTasks(threeDaysAgo);

      final maps = await ImportTaskRepository.instance.getAllImportTasks();
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
    if (!_persistTasks) return;
    try {
      await _persistTask(task);
    } catch (_) {
      _logTaskPersistenceFailure();
    }
  }

  Future<void> _persistTask(ImportTask task) async {
    if (!_persistTasks) return;
    final override = _saveTaskOverride;
    if (override != null) {
      await override(task.toMap());
      return;
    }
    await ImportTaskRepository.instance.saveImportTask(task.toMap());
  }

  void _logTaskPersistenceFailure() {
    AppLogger.warning(
      'Import task persistence failed',
      module: 'ImportTask',
      data: const <String, Object?>{
        'stage': 'task_persistence',
        'status': 'failed',
        'errorType': 'ImportTaskPersistenceFailure',
      },
    );
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

  void requireReview(
    String id,
    String text,
    List<Map<String, dynamic>> data,
    String bank,
    String folder, {
    List<String> warnings = const [],
    Map<String, dynamic> diagnostics = const {},
  }) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.pendingReview;
      tasks[idx].completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
      tasks[idx].progressText = text;
      tasks[idx].parsedData = _deduplicateQuestions(data);
      tasks[idx].bankName = bank;
      tasks[idx].folderName = folder;
      tasks[idx].percent = 1.0;
      if (warnings.isNotEmpty) {
        tasks[idx].warnings = warnings;
      }
      if (diagnostics.isNotEmpty) {
        final existingTraceId = tasks[idx].traceId;
        final existingParseMode = tasks[idx].parseMode;
        final existingExplanationRetentionMode =
            tasks[idx].diagnostics?[keyExplanationRetentionMode]?.toString();

        tasks[idx].diagnostics = diagnostics;

        // 恢复原有元数据
        if (existingTraceId != null ||
            existingParseMode != null ||
            existingExplanationRetentionMode != null) {
          tasks[idx].diagnostics ??= {};
          if (existingTraceId != null)
            tasks[idx].diagnostics![keyTraceId] = existingTraceId;
          if (existingParseMode != null)
            tasks[idx].diagnostics![keyParseMode] = existingParseMode;
          if (existingExplanationRetentionMode != null &&
              !tasks[idx]
                  .diagnostics!
                  .containsKey(keyExplanationRetentionMode)) {
            tasks[idx].diagnostics![keyExplanationRetentionMode] =
                existingExplanationRetentionMode;
          }
        }
      }
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  void attachDiagnostics(
    String id, {
    List<String> warnings = const [],
    Map<String, dynamic> diagnostics = const {},
  }) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].warnings = warnings;

      final existingTraceId = tasks[idx].traceId;
      final existingParseMode = tasks[idx].parseMode;
      final existingExplanationRetentionMode =
          tasks[idx].diagnostics?[keyExplanationRetentionMode]?.toString();

      tasks[idx].diagnostics = diagnostics;

      // 恢复原有元数据
      if (existingTraceId != null ||
          existingParseMode != null ||
          existingExplanationRetentionMode != null) {
        tasks[idx].diagnostics ??= {};
        if (existingTraceId != null)
          tasks[idx].diagnostics![keyTraceId] = existingTraceId;
        if (existingParseMode != null)
          tasks[idx].diagnostics![keyParseMode] = existingParseMode;
        if (existingExplanationRetentionMode != null &&
            !tasks[idx].diagnostics!.containsKey(keyExplanationRetentionMode)) {
          tasks[idx].diagnostics![keyExplanationRetentionMode] =
              existingExplanationRetentionMode;
        }
      }

      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  int reviewDraftRevision(String id) {
    final idx = tasks.indexWhere((task) => task.id == id);
    if (idx < 0) return 0;
    return _readReviewDraftRevision(tasks[idx]);
  }

  Future<ReviewDraftSaveResult> saveReviewDraft(
    String id, {
    required List<Map<String, dynamic>> questions,
    required ExplanationRetentionMode explanationRetentionMode,
  }) {
    return _enqueueReviewDraftWrite(
      () => _saveReviewDraftNow(
        id,
        questions: questions,
        explanationRetentionMode: explanationRetentionMode,
      ),
    );
  }

  Future<ReviewDraftSaveResult> mergeReviewDraftAnswer(
    String id, {
    required String reviewItemId,
    required int expectedRevision,
    required String standardAnswer,
    required String status,
  }) {
    return mergeReviewDraftAnswerDistillation(
      id,
      reviewItemId: reviewItemId,
      expectedRevision: expectedRevision,
      standardAnswer: standardAnswer,
      status: status,
    );
  }

  Future<ReviewDraftSaveResult> mergeReviewDraftAnswerDistillation(
    String id, {
    required String reviewItemId,
    required int expectedRevision,
    required String status,
    String? standardAnswer,
    String? reasonCode,
  }) {
    if (!SubjectiveAnswerDistillationSnapshotPolicy.isAiStatus(status)) {
      throw ArgumentError.value(status, 'status', 'unsupported status');
    }
    final answer = standardAnswer?.trim();
    if (status == 'ai_applied' && (answer == null || answer.isEmpty)) {
      throw ArgumentError.value(
        standardAnswer,
        'standardAnswer',
        'must be non-empty when status is ai_applied',
      );
    }
    final safeReasonCode =
        SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
      status: status,
      value: reasonCode,
    );

    return _enqueueReviewDraftWrite(() async {
      final idx = tasks.indexWhere((task) => task.id == id);
      if (idx < 0) {
        return const ReviewDraftSaveResult(
          ReviewDraftSaveStatus.taskMissing,
          revision: 0,
        );
      }
      final task = tasks[idx];
      final revision = _readReviewDraftRevision(task);
      if (revision != expectedRevision) {
        return ReviewDraftSaveResult(
          ReviewDraftSaveStatus.stale,
          revision: revision,
        );
      }
      final questions = task.parsedData
          ?.map((question) => Map<String, dynamic>.from(question))
          .toList(growable: false);
      if (questions == null) {
        return ReviewDraftSaveResult(
          ReviewDraftSaveStatus.itemMissing,
          revision: revision,
        );
      }
      final questionIndex = questions.indexWhere(
        (question) => question[keyReviewItemId]?.toString() == reviewItemId,
      );
      if (questionIndex < 0) {
        return ReviewDraftSaveResult(
          ReviewDraftSaveStatus.itemMissing,
          revision: revision,
        );
      }
      final updatedQuestion = <String, dynamic>{
        ...questions[questionIndex],
        keyAnswerDistillationStatus: status,
      };
      if (status == 'ai_applied') {
        updatedQuestion['standard_answer'] = answer;
        updatedQuestion.remove(keyAnswerDistillationReason);
      } else if (safeReasonCode != null) {
        updatedQuestion[keyAnswerDistillationReason] = safeReasonCode;
      } else {
        updatedQuestion.remove(keyAnswerDistillationReason);
      }
      questions[questionIndex] = updatedQuestion;
      return _saveReviewDraftNow(
        id,
        questions: questions,
        explanationRetentionMode: task.explanationRetentionMode,
        expectedRevision: expectedRevision,
      );
    });
  }

  Future<ReviewDraftSaveResult> _saveReviewDraftNow(
    String id, {
    required List<Map<String, dynamic>> questions,
    required ExplanationRetentionMode explanationRetentionMode,
    int? expectedRevision,
  }) async {
    final idx = tasks.indexWhere((task) => task.id == id);
    if (idx < 0) {
      return const ReviewDraftSaveResult(
        ReviewDraftSaveStatus.taskMissing,
        revision: 0,
      );
    }

    final task = tasks[idx];
    final currentRevision = _readReviewDraftRevision(task);
    if (expectedRevision != null && currentRevision != expectedRevision) {
      return ReviewDraftSaveResult(
        ReviewDraftSaveStatus.stale,
        revision: currentRevision,
      );
    }
    final nextRevision = currentRevision + 1;
    final nextTask = ImportTask.fromMap(task.toMap());
    nextTask.parsedData = questions
        .map(_sanitizeAnswerDistillationSnapshot)
        .toList(growable: false);
    nextTask.diagnostics = <String, dynamic>{
      ...?nextTask.diagnostics,
      keyExplanationRetentionMode: explanationRetentionMode.name,
      keyReviewDraftRevision: nextRevision,
    };
    try {
      await _persistTask(nextTask);
    } catch (_) {
      _logTaskPersistenceFailure();
      return ReviewDraftSaveResult(
        ReviewDraftSaveStatus.failed,
        revision: currentRevision,
      );
    }
    task.parsedData = nextTask.parsedData;
    task.diagnostics = nextTask.diagnostics;
    notifyListeners();
    return ReviewDraftSaveResult(
      ReviewDraftSaveStatus.saved,
      revision: nextRevision,
    );
  }

  static Map<String, dynamic> _sanitizeAnswerDistillationSnapshot(
    Map<String, dynamic> question,
  ) {
    final sanitized = Map<String, dynamic>.from(question);
    final status = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeStatus(
      sanitized[keyAnswerDistillationStatus],
    );
    if (status == null) {
      sanitized.remove(keyAnswerDistillationStatus);
      sanitized.remove(keyAnswerDistillationReason);
      return sanitized;
    }

    sanitized[keyAnswerDistillationStatus] = status;
    final reason = SubjectiveAnswerDistillationSnapshotPolicy.sanitizeReason(
      status: status,
      value: sanitized[keyAnswerDistillationReason],
    );
    if (reason == null) {
      sanitized.remove(keyAnswerDistillationReason);
    } else {
      sanitized[keyAnswerDistillationReason] = reason;
    }
    return sanitized;
  }

  Future<ReviewDraftSaveResult> _enqueueReviewDraftWrite(
    Future<ReviewDraftSaveResult> Function() action,
  ) {
    final completer = Completer<ReviewDraftSaveResult>();
    _reviewDraftWriteTail = _reviewDraftWriteTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  int _readReviewDraftRevision(ImportTask task) {
    final raw = task.diagnostics?[keyReviewDraftRevision];
    return switch (raw) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
  }

  List<Map<String, dynamic>> _deduplicateQuestions(
      List<Map<String, dynamic>> questions) {
    final seen = <QuestionIdentity>{};
    final result = <Map<String, dynamic>>[];

    for (final question in questions) {
      final identity = QuestionIdentity.fromMap(question);
      if (!identity.hasQuestionNumber && !identity.hasContent) {
        result.add(question);
        continue;
      }

      if (seen.add(identity)) {
        result.add(question);
      }
    }

    return result;
  }

  void appendPendingChunks(String id, String sourceType, List<String> chunks) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].sourceType = sourceType;
      tasks[idx].pendingChunks ??= [];
      tasks[idx].pendingChunks!.addAll(chunks);
      _saveTask(tasks[idx]);
      notifyListeners(); // UI 能实时看到 pendingChunks 变化
    }
  }

  void markChunkSuccess(
      String id, String chunk, List<Map<String, dynamic>> results) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].pendingChunks?.remove(chunk);
      tasks[idx].parsedData ??= [];
      tasks[idx].parsedData!.addAll(results);
      _saveTask(tasks[idx]);
      notifyListeners(); // UI 能实时看到批次完成、pending 数量减少
    }
  }

  void markChunkFailed(String id, String chunk) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].pendingChunks?.remove(chunk);
      tasks[idx].failedChunks ??= [];
      tasks[idx].failedChunks!.add(chunk);
      _saveTask(tasks[idx]);
      notifyListeners(); // UI 能实时看到失败批次
    }
  }

  void completeTask(String id, String text) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks[idx].status = TaskStatus.completed;
      tasks[idx].progressText = text;
      tasks[idx].completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
      tasks[idx].parsedData = null;
      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  void failTask(
    String id,
    String error, {
    List<String>? warnings,
    Map<String, dynamic>? diagnostics,
    bool clearSensitivePayload = false,
  }) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      final task = tasks[idx];
      final existingTraceId = task.traceId;
      final existingParseMode = task.parseMode;
      if (clearSensitivePayload) {
        task.parsedData = null;
        task.pendingChunks = null;
        task.failedChunks = null;
        task.warnings = List<String>.from(warnings ?? const <String>[]);
      } else if (warnings != null) {
        task.warnings = List<String>.from(warnings);
      }
      if (clearSensitivePayload || diagnostics != null) {
        task.diagnostics = Map<String, dynamic>.from(
          diagnostics ?? const <String, dynamic>{},
        );
        if (existingTraceId != null) {
          task.diagnostics![keyTraceId] = existingTraceId;
        }
        if (existingParseMode != null) {
          task.diagnostics![keyParseMode] = existingParseMode;
        }
      }
      task.status = TaskStatus.error;
      task.errorMsg = error;
      task.completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _saveTask(task);
      notifyListeners();
    }
  }

  void deleteTask(String id) {
    final idx = tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      tasks.removeAt(idx);
      if (_persistTasks) {
        ImportTaskRepository.instance.deleteImportTask(id).catchError((e) {
          debugPrint('Background task deletion failed: $e');
        });
      }
      notifyListeners();
    }
  }

  void clearCompletedTasks() {
    tasks.removeWhere((t) => t.status.isFinalState);
    if (_persistTasks) {
      ImportTaskRepository.instance.clearCompletedImportTasks().catchError((e) {
        debugPrint('Clear completed tasks failed: $e');
      });
    }
    notifyListeners();
  }
}
