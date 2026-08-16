import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/models/question_identity.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
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
  String? get correlationId =>
      diagnostics?[TaskManager.keyCorrelationId]?.toString();
  String? get parentTraceId =>
      diagnostics?[TaskManager.keyParentTraceId]?.toString();
  String? get parseMode => diagnostics?[TaskManager.keyParseMode]?.toString();
  int get attemptNumber {
    final value = diagnostics?[TaskManager.keyAttemptNumber];
    return switch (value) {
      final int number when number > 0 => number,
      final num number when number > 0 => number.toInt(),
      final String number => int.tryParse(number) ?? 1,
      _ => 1,
    };
  }

  String? get attemptToken {
    final value = diagnostics?[TaskManager.keyAttemptToken];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  ImportAttemptState get attemptState {
    final value = diagnostics?[TaskManager.keyAttemptState];
    if (value is String) {
      for (final state in ImportAttemptState.values) {
        if (state.name == value) return state;
      }
    }
    return switch (status) {
      TaskStatus.processing => ImportAttemptState.running,
      TaskStatus.pendingReview ||
      TaskStatus.completed =>
        ImportAttemptState.readyForReview,
      TaskStatus.error => ImportAttemptState.failed,
    };
  }

  ImportAttemptRef? get attemptRef {
    final token = attemptToken;
    final currentTraceId = traceId;
    if (token == null ||
        currentTraceId == null ||
        currentTraceId.trim().isEmpty) {
      return null;
    }
    return ImportAttemptRef(
      taskId: id,
      attemptNumber: attemptNumber,
      attemptToken: token,
      traceId: currentTraceId,
    );
  }

  String? get batchId {
    final value = diagnostics?[TaskManager.keyBatchId];
    return value is String && value.isNotEmpty ? value : null;
  }

  int? get selectionIndex {
    final value = diagnostics?[TaskManager.keySelectionIndex];
    return value is num ? value.toInt() : null;
  }

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

enum ReviewDraftSaveStatus {
  saved,
  stale,
  taskMissing,
  itemMissing,
  failed,
  commitInProgress,
}

class ReviewDraftSaveResult {
  const ReviewDraftSaveResult(this.status, {required this.revision});

  final ReviewDraftSaveStatus status;
  final int revision;

  bool get saved => status == ReviewDraftSaveStatus.saved;
}

/// Outcome of one typed commit lease acquisition.
enum TypedCommitLeaseStatus {
  acquired,
  taskMissing,
  taskNotPendingReview,
  staleAttempt,
  staleReviewDraft,
  commitInProgress,
}

final class TypedCommitLeaseResult {
  const TypedCommitLeaseResult(this.status, [this.lease]);

  const TypedCommitLeaseResult.acquired(TypedCommitAttemptLease lease)
      : this(TypedCommitLeaseStatus.acquired, lease);

  final TypedCommitLeaseStatus status;
  final TypedCommitAttemptLease? lease;
}

/// One exclusive typed commit lease for a task.
///
/// [leaseId] is an opaque random identifier and never contains question
/// content, paths or source ids.
final class TypedCommitAttemptLease {
  const TypedCommitAttemptLease({
    required this.leaseId,
    required this.taskId,
    required this.attemptToken,
    required this.attemptNumber,
    required this.reviewDraftRevision,
    required this.storageRoute,
    required this.storageReason,
  });

  final String leaseId;
  final String taskId;
  final String attemptToken;
  final int attemptNumber;
  final int reviewDraftRevision;
  final String storageRoute;
  final String storageReason;
}

/// Result of applying an already-durable typed completion to memory.
enum TypedDurableCompletionStatus {
  applied,
  taskRemovedDurable,
  staleLease,
  alreadyCompleted,
}

enum ImportAttemptWriteStatus {
  applied,
  stale,
  taskMissing,
  invalidState,
  persistenceFailed,
}

class TaskManager extends ChangeNotifier {
  static const String keyTraceId = '_traceId';
  static const String keyCorrelationId = '_correlationId';
  static const String keyParentTraceId = '_parentTraceId';
  static const String keyParseMode = '_parseMode';
  static const String keyBatchId = '_batchId';
  static const String keySelectionIndex = '_selectionIndex';
  static const String keyAttemptNumber =
      TypedImportCommitPersistence.keyAttemptNumber;
  static const String keyAttemptToken =
      TypedImportCommitPersistence.keyAttemptToken;
  static const String keyAttemptState =
      TypedImportCommitPersistence.keyAttemptState;
  static const String keyExplanationRetentionMode = '_explanationRetentionMode';
  static const String keyReviewDraftRevision =
      TypedImportCommitPersistence.keyReviewDraftRevision;
  static const String keyReviewItemId = '_reviewItemId';
  static const String keyAnswerDistillationStatus =
      '_answer_distillation_status';
  static const String keyAnswerDistillationReason =
      '_answer_distillation_reason';
  static const String keyImportStorageRoute =
      TypedImportCommitPersistence.keyImportStorageRoute;
  static const String keyImportStorageReason =
      TypedImportCommitPersistence.keyImportStorageReason;

  static final TaskManager _instance = TaskManager._internal();
  static TaskManager get instance => _instance;

  TaskManager._internal()
      : _persistTasks = true,
        _saveTaskOverride = null,
        _loadTasksOverride = null {
    ready = _loadTasksFromDb();
  }

  @visibleForTesting
  TaskManager.forTesting({
    Future<void> Function(Map<String, dynamic> taskMap)? saveTask,
    Future<List<Map<String, dynamic>>> Function()? loadTasks,
  })  : _persistTasks = saveTask != null,
        _saveTaskOverride = saveTask,
        _loadTasksOverride = loadTasks {
    ready = loadTasks == null ? Future<void>.value() : _loadTasksFromDb();
  }

  late final Future<void> ready;
  final bool _persistTasks;
  final Future<void> Function(Map<String, dynamic> taskMap)? _saveTaskOverride;
  final Future<List<Map<String, dynamic>>> Function()? _loadTasksOverride;
  Future<void> _reviewDraftWriteTail = Future<void>.value();
  final Map<String, Future<void>> _attemptWriteTails = <String, Future<void>>{};
  final Map<String, TypedCommitAttemptLease> _typedCommitLeases =
      <String, TypedCommitAttemptLease>{};
  static final Random _leaseRandom = Random.secure();

  final List<ImportTask> tasks = [];
  int get processingCount =>
      tasks.where((t) => t.status == TaskStatus.processing).length;
  int get pendingCount =>
      tasks.where((t) => t.status == TaskStatus.pendingReview).length;

  Future<void> _loadTasksFromDb() async {
    try {
      final loader = _loadTasksOverride;
      final List<Map<String, dynamic>> maps;
      if (loader != null) {
        maps = await loader();
      } else {
        final threeDaysAgo = DateTime.now()
                .subtract(const Duration(days: 3))
                .millisecondsSinceEpoch ~/
            1000;
        await ImportTaskRepository.instance.deleteOldImportTasks(threeDaysAgo);
        maps = await ImportTaskRepository.instance.getAllImportTasks();
      }
      tasks.clear();
      for (var map in maps) {
        final task = ImportTask.fromMap(map);
        final wasInterrupted = task.status == TaskStatus.processing;
        if (wasInterrupted) {
          _markLoadedTaskInterrupted(task);
        }
        tasks.add(task);
        if (wasInterrupted) {
          await _saveTask(task);
        }
      }
      notifyListeners();
    } catch (_) {
      debugPrint('Error loading tasks from SQLite');
    }
  }

  void _markLoadedTaskInterrupted(ImportTask task) {
    task.status = TaskStatus.error;
    task.progressText = '任务因应用重启而中断，请重新选择文件后重试';
    task.errorMsg = '任务因应用重启而中断';
    task.completedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    task.parsedData = null;
    task.pendingChunks = null;
    task.failedChunks = null;
    task.warnings = <String>[];
    task.diagnostics = <String, dynamic>{
      ..._taskMetadata(task),
      keyAttemptNumber: task.attemptNumber,
      keyAttemptState: ImportAttemptState.interrupted.name,
    }..remove(keyAttemptToken);
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
    addTasksInOrder(<ImportTask>[task]);
  }

  void addTasksInOrder(List<ImportTask> orderedTasks) {
    if (orderedTasks.isEmpty) return;
    tasks.insertAll(0, orderedTasks);
    for (final task in orderedTasks) {
      _saveTask(task);
    }
    notifyListeners();
  }

  Future<ImportAttemptWriteStatus> addAttemptTask(ImportTask task) async {
    final results = await addAttemptTasksInOrder(<ImportTask>[task]);
    return results.single;
  }

  Future<List<ImportAttemptWriteStatus>> addAttemptTasksInOrder(
    List<ImportTask> orderedTasks,
  ) {
    if (orderedTasks.isEmpty) {
      return Future<List<ImportAttemptWriteStatus>>.value(
        <ImportAttemptWriteStatus>[],
      );
    }
    tasks.insertAll(0, orderedTasks);
    notifyListeners();
    return Future.wait<ImportAttemptWriteStatus>(
      orderedTasks.map((task) {
        final attempt = task.attemptRef;
        if (attempt == null) {
          return Future<ImportAttemptWriteStatus>.value(
            ImportAttemptWriteStatus.invalidState,
          );
        }
        return _persistAttemptSnapshot(attempt, task);
      }),
    );
  }

  bool isCurrentAttempt(ImportAttemptRef attempt) {
    return _taskForAttempt(attempt) != null;
  }

  bool isAttemptRunnable(ImportAttemptRef attempt) {
    final task = _taskForAttempt(attempt);
    if (task == null || task.status != TaskStatus.processing) return false;
    return task.attemptState == ImportAttemptState.queued ||
        task.attemptState == ImportAttemptState.running;
  }

  Future<ImportAttemptWriteStatus> markAttemptRunning(
    ImportAttemptRef attempt,
  ) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    if (task.attemptState == ImportAttemptState.running) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.applied,
      );
    }
    if (task.status != TaskStatus.processing ||
        task.attemptState != ImportAttemptState.queued) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    task.diagnostics = <String, dynamic>{
      ...?task.diagnostics,
      keyAttemptState: ImportAttemptState.running.name,
    };
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> updateAttemptProgress(
    ImportAttemptRef attempt,
    String text,
    double percent,
  ) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    if (!isAttemptRunnable(attempt)) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    task.progressText = text;
    task.percent = percent;
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> requestAttemptCancellation(
    ImportAttemptRef attempt,
  ) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    switch (task.attemptState) {
      case ImportAttemptState.queued:
        _markAttemptCancelledInMemory(task);
        break;
      case ImportAttemptState.running:
        task.diagnostics = <String, dynamic>{
          ...?task.diagnostics,
          keyAttemptState: ImportAttemptState.cancelRequested.name,
        };
        task.progressText = '正在等待当前 OCR 请求结束...';
        break;
      case ImportAttemptState.cancelRequested:
      case ImportAttemptState.cancelled:
        return Future<ImportAttemptWriteStatus>.value(
          ImportAttemptWriteStatus.applied,
        );
      case ImportAttemptState.readyForReview:
      case ImportAttemptState.failed:
      case ImportAttemptState.interrupted:
        return Future<ImportAttemptWriteStatus>.value(
          ImportAttemptWriteStatus.invalidState,
        );
    }
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> finalizeAttemptCancelled(
    ImportAttemptRef attempt,
  ) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    if (task.attemptState == ImportAttemptState.cancelled) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.applied,
      );
    }
    if (task.attemptState != ImportAttemptState.queued &&
        task.attemptState != ImportAttemptState.running &&
        task.attemptState != ImportAttemptState.cancelRequested) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    _markAttemptCancelledInMemory(task);
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> requireAttemptReview(
    ImportAttemptRef attempt,
    String text,
    List<Map<String, dynamic>> data,
    String bank,
    String folder, {
    List<String> warnings = const <String>[],
    Map<String, dynamic> diagnostics = const <String, dynamic>{},
  }) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    if (!isAttemptRunnable(attempt)) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    task.status = TaskStatus.pendingReview;
    task.completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    task.progressText = text;
    task.parsedData = _deduplicateQuestions(data);
    task.bankName = bank;
    task.folderName = folder;
    task.percent = 1.0;
    task.warnings = List<String>.from(warnings);
    task.diagnostics = _replaceDiagnosticsPreservingTaskMetadata(
      task,
      diagnostics,
    )..[keyAttemptState] = ImportAttemptState.readyForReview.name;
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> failAttempt(
    ImportAttemptRef attempt,
    String error, {
    List<String>? warnings,
    Map<String, dynamic>? diagnostics,
    bool clearSensitivePayload = false,
  }) {
    final task = _taskForAttempt(attempt);
    if (task == null) return _missingAttemptStatus(attempt);
    if (!isAttemptRunnable(attempt)) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    if (clearSensitivePayload) {
      task.parsedData = null;
      task.pendingChunks = null;
      task.failedChunks = null;
      task.warnings = List<String>.from(warnings ?? const <String>[]);
    } else if (warnings != null) {
      task.warnings = List<String>.from(warnings);
    }
    if (clearSensitivePayload || diagnostics != null) {
      task.diagnostics = _replaceDiagnosticsPreservingTaskMetadata(
        task,
        diagnostics ?? const <String, dynamic>{},
      );
    }
    task.diagnostics = <String, dynamic>{
      ...?task.diagnostics,
      keyAttemptState: ImportAttemptState.failed.name,
    };
    task.status = TaskStatus.error;
    task.errorMsg = error;
    task.completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    notifyListeners();
    return _persistAttemptSnapshot(attempt, task);
  }

  Future<ImportAttemptWriteStatus> restartAttempt(
    ImportAttemptRef nextAttempt, {
    required String parseMode,
    required ExplanationRetentionMode explanationRetentionMode,
  }) {
    final index = tasks.indexWhere((task) => task.id == nextAttempt.taskId);
    if (index < 0) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.taskMissing,
      );
    }
    final task = tasks[index];
    if (nextAttempt.attemptNumber != task.attemptNumber + 1 ||
        nextAttempt.attemptToken.trim().isEmpty ||
        nextAttempt.traceId.trim().isEmpty) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }
    if (task.attemptState != ImportAttemptState.failed &&
        task.attemptState != ImportAttemptState.cancelled &&
        task.attemptState != ImportAttemptState.interrupted &&
        task.attemptState != ImportAttemptState.cancelRequested) {
      return Future<ImportAttemptWriteStatus>.value(
        ImportAttemptWriteStatus.invalidState,
      );
    }

    final stableMetadata = _taskMetadata(task);
    // OBS-1 retry lineage: the new attempt inherits the same correlation and
    // points its parent trace at the previous attempt's trace.
    final previousTraceId = task.traceId;
    task.status = TaskStatus.processing;
    task.progressText = '已进入后台队列...';
    task.percent = 0.1;
    task.errorMsg = null;
    task.parsedData = null;
    task.bankName = null;
    task.folderName = null;
    task.sourceType = null;
    task.pendingChunks = null;
    task.failedChunks = null;
    task.warnings = null;
    task.completedAt = null;
    task.diagnostics = <String, dynamic>{
      if (stableMetadata[keyBatchId] != null)
        keyBatchId: stableMetadata[keyBatchId],
      if (stableMetadata[keySelectionIndex] != null)
        keySelectionIndex: stableMetadata[keySelectionIndex],
      if (stableMetadata[keyImportStorageRoute] != null)
        keyImportStorageRoute: stableMetadata[keyImportStorageRoute],
      if (stableMetadata[keyImportStorageReason] != null)
        keyImportStorageReason: stableMetadata[keyImportStorageReason],
      if (stableMetadata[keyCorrelationId] != null)
        keyCorrelationId: stableMetadata[keyCorrelationId],
      if (previousTraceId != null) keyParentTraceId: previousTraceId,
      keyTraceId: nextAttempt.traceId,
      keyParseMode: parseMode,
      keyExplanationRetentionMode: explanationRetentionMode.name,
      keyAttemptNumber: nextAttempt.attemptNumber,
      keyAttemptToken: nextAttempt.attemptToken,
      keyAttemptState: ImportAttemptState.queued.name,
    };
    notifyListeners();
    return _persistAttemptSnapshot(nextAttempt, task);
  }

  void _markAttemptCancelledInMemory(ImportTask task) {
    task.status = TaskStatus.error;
    task.progressText = '任务已取消';
    task.errorMsg = '任务已取消';
    task.completedAt ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    task.parsedData = null;
    task.pendingChunks = null;
    task.failedChunks = null;
    task.warnings = <String>[];
    task.diagnostics = <String, dynamic>{
      ..._taskMetadata(task),
      keyAttemptState: ImportAttemptState.cancelled.name,
    };
  }

  ImportTask? _taskForAttempt(ImportAttemptRef attempt) {
    final index = tasks.indexWhere((task) => task.id == attempt.taskId);
    if (index < 0) return null;
    final task = tasks[index];
    if (task.attemptNumber != attempt.attemptNumber ||
        task.attemptToken != attempt.attemptToken ||
        task.traceId != attempt.traceId) {
      return null;
    }
    return task;
  }

  Future<ImportAttemptWriteStatus> _missingAttemptStatus(
    ImportAttemptRef attempt,
  ) {
    final taskExists = tasks.any((task) => task.id == attempt.taskId);
    return Future<ImportAttemptWriteStatus>.value(
      taskExists
          ? ImportAttemptWriteStatus.stale
          : ImportAttemptWriteStatus.taskMissing,
    );
  }

  Future<ImportAttemptWriteStatus> _persistAttemptSnapshot(
    ImportAttemptRef attempt,
    ImportTask task,
  ) {
    final snapshot = ImportTask.fromMap(task.toMap());
    final completer = Completer<ImportAttemptWriteStatus>();
    final previous = _attemptWriteTails[attempt.taskId] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then<void>((_) async {
      if (_taskForAttempt(attempt) == null) {
        completer.complete(
          tasks.any((task) => task.id == attempt.taskId)
              ? ImportAttemptWriteStatus.stale
              : ImportAttemptWriteStatus.taskMissing,
        );
        return;
      }
      try {
        await _persistTask(snapshot);
        completer.complete(ImportAttemptWriteStatus.applied);
      } catch (_) {
        _logTaskPersistenceFailure();
        completer.complete(ImportAttemptWriteStatus.persistenceFailed);
      }
    });
    _attemptWriteTails[attempt.taskId] = operation;
    unawaited(operation.whenComplete(() {
      if (identical(_attemptWriteTails[attempt.taskId], operation)) {
        _attemptWriteTails.remove(attempt.taskId);
      }
    }));
    return completer.future;
  }

  Map<String, dynamic> _taskMetadata(ImportTask task) {
    final existing = task.diagnostics;
    final metadata = <String, dynamic>{};
    for (final key in <String>[
      keyTraceId,
      keyCorrelationId,
      keyParentTraceId,
      keyParseMode,
      keyBatchId,
      keySelectionIndex,
      keyExplanationRetentionMode,
      keyAttemptNumber,
      keyAttemptToken,
      keyAttemptState,
      keyImportStorageRoute,
      keyImportStorageReason,
    ]) {
      final value = existing?[key];
      if (value != null) metadata[key] = value;
    }
    return metadata;
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
        tasks[idx].diagnostics = _replaceDiagnosticsPreservingTaskMetadata(
          tasks[idx],
          diagnostics,
        );
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
      tasks[idx].diagnostics = _replaceDiagnosticsPreservingTaskMetadata(
        tasks[idx],
        diagnostics,
      );

      _saveTask(tasks[idx]);
      notifyListeners();
    }
  }

  Map<String, dynamic> _replaceDiagnosticsPreservingTaskMetadata(
    ImportTask task,
    Map<String, dynamic> diagnostics,
  ) {
    final existing = task.diagnostics;
    final next = Map<String, dynamic>.from(diagnostics);
    for (final key in <String>[
      keyTraceId,
      keyCorrelationId,
      keyParentTraceId,
      keyParseMode,
      keyBatchId,
      keySelectionIndex,
      keyAttemptNumber,
      keyAttemptToken,
      keyAttemptState,
      keyImportStorageRoute,
      keyImportStorageReason,
    ]) {
      final value = existing?[key];
      if (value != null) {
        next[key] = value;
      }
    }
    if (!next.containsKey(keyExplanationRetentionMode)) {
      final retentionMode = existing?[keyExplanationRetentionMode];
      if (retentionMode != null) {
        next[keyExplanationRetentionMode] = retentionMode;
      }
    }
    return next;
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
    if (_typedCommitLeases.containsKey(id)) {
      return Future<ReviewDraftSaveResult>.value(
        ReviewDraftSaveResult(
          ReviewDraftSaveStatus.commitInProgress,
          revision: reviewDraftRevision(id),
        ),
      );
    }
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
    if (_typedCommitLeases.containsKey(id)) {
      return Future<ReviewDraftSaveResult>.value(
        ReviewDraftSaveResult(
          ReviewDraftSaveStatus.commitInProgress,
          revision: reviewDraftRevision(id),
        ),
      );
    }
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
    if (_typedCommitLeases.containsKey(id)) {
      return ReviewDraftSaveResult(
        ReviewDraftSaveStatus.commitInProgress,
        revision: reviewDraftRevision(id),
      );
    }
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

  /// Begins a typed commit attempt for one task.
  ///
  /// The lease registration is serialized with the review-draft queue: every
  /// review draft write enqueued before this call completes first, and every
  /// write enqueued afterwards observes the active lease and is rejected with
  /// [ReviewDraftSaveStatus.commitInProgress]. The in-memory current-attempt
  /// gate mirrors the persisted repository gate (P2-A).
  Future<TypedCommitLeaseResult> beginTypedCommitAttempt({
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required int expectedReviewDraftRevision,
  }) {
    final completer = Completer<TypedCommitLeaseResult>();
    _reviewDraftWriteTail = _reviewDraftWriteTail.then((_) async {
      try {
        completer.complete(
          _beginTypedCommitAttemptNow(
            taskId: taskId,
            attemptToken: attemptToken,
            attemptNumber: attemptNumber,
            expectedReviewDraftRevision: expectedReviewDraftRevision,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  TypedCommitLeaseResult _beginTypedCommitAttemptNow({
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required int expectedReviewDraftRevision,
  }) {
    if (_typedCommitLeases.containsKey(taskId)) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.commitInProgress,
      );
    }
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.taskMissing,
      );
    }
    final task = tasks[index];
    if (task.status != TaskStatus.pendingReview) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.taskNotPendingReview,
      );
    }
    if (task.attemptToken != attemptToken ||
        task.attemptNumber != attemptNumber) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.staleAttempt,
      );
    }
    if (task.attemptState != ImportAttemptState.readyForReview) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.taskNotPendingReview,
      );
    }
    final route = task.diagnostics?[keyImportStorageRoute];
    final reason = task.diagnostics?[keyImportStorageReason];
    if (route != TypedImportCommitPersistence.typedV2RouteValue ||
        reason != TypedImportCommitPersistence.typedCandidateReadyReasonValue) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.taskNotPendingReview,
      );
    }
    if (task.parsedData == null || task.parsedData!.isEmpty) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.taskNotPendingReview,
      );
    }
    final currentRevision = _readReviewDraftRevision(task);
    if (expectedReviewDraftRevision <= 0 ||
        currentRevision != expectedReviewDraftRevision) {
      return const TypedCommitLeaseResult(
        TypedCommitLeaseStatus.staleReviewDraft,
      );
    }

    final lease = TypedCommitAttemptLease(
      leaseId: _newTypedCommitLeaseId(),
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      reviewDraftRevision: expectedReviewDraftRevision,
      storageRoute: TypedImportCommitPersistence.typedV2RouteValue,
      storageReason:
          TypedImportCommitPersistence.typedCandidateReadyReasonValue,
    );
    _typedCommitLeases[taskId] = lease;
    return TypedCommitLeaseResult.acquired(lease);
  }

  /// Releases an active typed commit lease after a failed attempt. The task
  /// stays `pendingReview` and new review draft writes are allowed again.
  void releaseTypedCommitLease(TypedCommitAttemptLease lease) {
    final active = _typedCommitLeases[lease.taskId];
    if (active != null && active.leaseId == lease.leaseId) {
      _typedCommitLeases.remove(lease.taskId);
    }
  }

  /// Synchronizes the already-durable typed completion into memory only.
  ///
  /// Never persists: the SQLite transaction already wrote `import_tasks` to
  /// completed. No `_saveTask`, `ImportTaskRepository` or database write is
  /// ever triggered from this path. When the in-memory task was removed, a
  /// fixed safe warning is recorded and the durable database state remains
  /// authoritative. The lease is cleared only after every review draft write
  /// queued before the completion has drained, so no old pendingReview
  /// snapshot can be written after the task completed.
  TypedDurableCompletionStatus applyDurableTypedCommitCompletion({
    required TypedCommitAttemptLease lease,
    required String completionText,
    required int completedAt,
  }) {
    final index = tasks.indexWhere((task) => task.id == lease.taskId);
    if (index < 0) {
      _typedCommitLeases.remove(lease.taskId);
      _logTypedCommitTaskRemovedWarning();
      return TypedDurableCompletionStatus.taskRemovedDurable;
    }
    final task = tasks[index];
    if (task.attemptToken != lease.attemptToken ||
        task.attemptNumber != lease.attemptNumber) {
      _typedCommitLeases.remove(lease.taskId);
      return TypedDurableCompletionStatus.staleLease;
    }
    if (task.status == TaskStatus.completed) {
      _typedCommitLeases.remove(lease.taskId);
      return TypedDurableCompletionStatus.alreadyCompleted;
    }
    task.status = TaskStatus.completed;
    task.progressText = completionText;
    task.completedAt = completedAt;
    task.parsedData = null;
    notifyListeners();
    _scheduleTypedCommitLeaseCleanup(lease.taskId);
    return TypedDurableCompletionStatus.applied;
  }

  void _scheduleTypedCommitLeaseCleanup(String taskId) {
    _reviewDraftWriteTail = _reviewDraftWriteTail.then((_) {
      _typedCommitLeases.remove(taskId);
    });
  }

  void _logTypedCommitTaskRemovedWarning() {
    AppLogger.warning(
      'Typed import committed durably but the in-memory task was removed',
      module: 'ImportTask',
      data: const <String, Object?>{
        'stage': 'typed_commit_memory_sync',
        'status': 'durable_completed_task_removed',
      },
    );
  }

  static String _newTypedCommitLeaseId() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final entropy = _leaseRandom.nextInt(0x7fffffff).toRadixString(16);
    return 'typed-commit-$timestamp-$entropy';
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
      if (clearSensitivePayload) {
        task.parsedData = null;
        task.pendingChunks = null;
        task.failedChunks = null;
        task.warnings = List<String>.from(warnings ?? const <String>[]);
      } else if (warnings != null) {
        task.warnings = List<String>.from(warnings);
      }
      if (clearSensitivePayload || diagnostics != null) {
        task.diagnostics = _replaceDiagnosticsPreservingTaskMetadata(
          task,
          diagnostics ?? const <String, dynamic>{},
        );
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
