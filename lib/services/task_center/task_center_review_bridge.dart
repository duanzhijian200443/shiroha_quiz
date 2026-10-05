import '../../application/home_training_result.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../task_manager.dart';
import '../import_pipeline/import_attempt_context.dart';

/// Explicit legacy review compatibility boundary. Never exports raw review input
/// to a TaskCenter read DTO; the composition callback owns immediate navigation.
final class TaskCenterReviewBridge {
  const TaskCenterReviewBridge(this.manager);
  final TaskManager manager;

  Future<HomeTrainingResult<HomeTrainingUnit>> open(
      TaskCenterReviewNavigationRequest request,
      Future<void> Function(ImportTask) present) async {
    try {
      final failure = await manager.validateTaskCenterTarget(request.target);
      if (failure != null) return HomeTrainingFailed(failure);
      // No await between this last exact target/eligibility check and present.
      if (!manager.matchesTaskCenterTarget(request.target)) {
        return const HomeTrainingFailed(HomeTrainingFailure.stale);
      }
      final task =
          manager.tasks.where((t) => t.id == request.target.taskId).firstOrNull;
      if (task == null) {
        return const HomeTrainingFailed(HomeTrainingFailure.stale);
      }
      if (manager.isTaskCenterBusy(task.id) ||
          task.status != TaskStatus.pendingReview ||
          (task.diagnostics?[TaskManager.keyAttemptState] != null &&
              task.attemptState != ImportAttemptState.readyForReview) ||
          task.parsedData == null) {
        return const HomeTrainingFailed(HomeTrainingFailure.conflict);
      }
      await present(task);
      return const HomeTrainingSuccess(HomeTrainingUnit());
    } catch (_) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }
}
