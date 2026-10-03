import '../home_training_result.dart';

/// Exact captured task/attempt target shared by commands and picker handoff.
/// Nullable metadata asserts persisted absence, never a wildcard or a made-up
/// compatibility identity. Review bridges retain trace/revision CAS and leases.
final class TaskCenterTaskTarget {
  TaskCenterTaskTarget({
    required this.taskId,
    required this.expectedAttemptNumber,
    required this.expectedAttemptToken,
    required this.expectedTraceId,
    required this.expectedReviewRevision,
  }) {
    requireHomeTrainingInput(isSafeTaskCenterToken(taskId));
    requireHomeTrainingInput(
        expectedAttemptNumber == null || expectedAttemptNumber! > 0);
    requireHomeTrainingInput(expectedAttemptToken == null ||
        isSafeTaskCenterToken(expectedAttemptToken!));
    requireHomeTrainingInput(
        expectedTraceId == null || isSafeTaskCenterToken(expectedTraceId!));
    requireHomeTrainingInput(
        expectedReviewRevision == null || expectedReviewRevision! >= 0);
  }
  final String taskId;
  final int? expectedAttemptNumber;
  final String? expectedAttemptToken;
  final String? expectedTraceId;
  final int? expectedReviewRevision;
}

final class RetryFileSelectionRequest {
  const RetryFileSelectionRequest(this.target);
  final TaskCenterTaskTarget target;
}

/// Opaque ephemeral command input. Only a host/composition/ingestion adapter
/// may implement this handle and retain a path/URI within that boundary.
/// No picker object, bytes, serialization, logging or reusable read DTO API.
abstract interface class RetrySourceSelection {}

sealed class RetryFileSelectionResult {
  const RetryFileSelectionResult();
}

final class RetryFileSelectionCancelled extends RetryFileSelectionResult {
  const RetryFileSelectionCancelled();
}

final class RetryFileSelectionSelected extends RetryFileSelectionResult {
  const RetryFileSelectionSelected(
      {required this.request, required this.selection});
  final RetryFileSelectionRequest request;
  final RetrySourceSelection selection;
}

abstract interface class RetryFileSelectionHost {
  /// Host opens the picker only after explicit user action. Cancel is no retry.
  Future<RetryFileSelectionResult> select(RetryFileSelectionRequest request);
}

abstract interface class TaskCenterSelectedSourceRetry {
  /// Accepts only selected input; cancellation cannot be submitted. Revalidate
  /// the captured attempt after the picker, then use the existing retry adapter.
  /// Stale is zero mutation. Never persist, return or log the selection handle.
  Future<HomeTrainingResult<HomeTrainingUnit>> retryWithSelectedSource(
      RetryFileSelectionSelected selected);
}

bool isSafeTaskCenterToken(String value) =>
    value.trim().isNotEmpty && !RegExp(r'[/\\:\x00-\x1f\x7f]').hasMatch(value);
