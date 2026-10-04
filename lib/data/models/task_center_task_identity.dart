import 'dart:convert';
import '../../application/task_center/retry_file_selection.dart';

/// Strict nullable persisted identity; absence never becomes attempt 1 or
/// review revision 0 merely because a legacy compatibility getter does so.
TaskCenterTaskTarget? captureTaskCenterTaskTarget(
    String taskId, Map<String, dynamic>? diagnostics) {
  try {
    return TaskCenterTaskTarget(
      taskId: taskId,
      expectedAttemptNumber: diagnostics?['_attemptNumber'] as int?,
      expectedAttemptToken: diagnostics?['_attemptToken'] as String?,
      expectedTraceId: diagnostics?['_traceId'] as String?,
      expectedReviewRevision: diagnostics?['_reviewDraftRevision'] as int?,
    );
  } catch (_) {
    return null;
  }
}

bool sameTaskCenterTaskTarget(TaskCenterTaskTarget a, TaskCenterTaskTarget b) =>
    a.taskId == b.taskId &&
    a.expectedAttemptNumber == b.expectedAttemptNumber &&
    a.expectedAttemptToken == b.expectedAttemptToken &&
    a.expectedTraceId == b.expectedTraceId &&
    a.expectedReviewRevision == b.expectedReviewRevision;

bool persistedTaskCenterTargetMatches(
    Map<String, Object?> row, TaskCenterTaskTarget target) {
  try {
    final raw = row['diagnostics'];
    final decoded = raw == null ? null : jsonDecode(raw as String);
    if (raw != null && decoded is! Map) return false;
    final captured = captureTaskCenterTaskTarget(row['id'] as String,
        decoded == null ? null : Map<String, dynamic>.from(decoded as Map));
    return captured != null && sameTaskCenterTaskTarget(captured, target);
  } catch (_) {
    return false;
  }
}

/// JSON whitespace/key order is not a durable attempt change. Actual content,
/// review revision and all scalar fields still participate in the comparison.
bool sameImportTaskPersistedSnapshot(
    Map<String, Object?> actual, Map<String, dynamic> expected) {
  const jsonColumns = {
    'parsed_data',
    'pending_chunks',
    'failed_chunks',
    'warnings',
    'diagnostics'
  };
  try {
    return expected.entries.every((entry) {
      final left = actual[entry.key];
      final right = entry.value;
      if (!jsonColumns.contains(entry.key) || left == null || right == null) {
        return left == right;
      }
      return _sameJsonValue(
          jsonDecode(left as String), jsonDecode(right as String));
    });
  } catch (_) {
    return false;
  }
}

bool _sameJsonValue(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
            (key) => b.containsKey(key) && _sameJsonValue(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        a
            .asMap()
            .entries
            .every((entry) => _sameJsonValue(entry.value, b[entry.key]));
  }
  return a == b;
}
