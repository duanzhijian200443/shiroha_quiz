import 'package:flutter/material.dart';
import '../../application/home_training_result.dart';
import '../../application/questions/folder_query_port.dart';
import '../../application/task_center/retry_file_selection.dart';
import '../../services/task_manager.dart';
import '../../services/import_pipeline/import_task_coordinator.dart';
import '../../services/import_review/import_commit_service.dart';
import '../../services/task_center/task_center_facade.dart';
import '../../services/task_center/task_center_file_picker_host.dart';
import '../../services/task_center/task_center_review_bridge.dart';
import '../dependencies/task_center_dependencies.dart';
import '../pages/import_staging_screen.dart';

/// Explicit composition root for the legacy review input and picker adapters.
TaskCenterDependencies createTaskCenterDependencies(
    {required TaskManager manager,
    required ImportTaskCoordinator coordinator,
    FolderQueryPort? folderQuery,
    ImportCommitService? commitService,
    RetryFileSelectionHost? fileSelection}) {
  final facade =
      TaskCenterFacade(taskManager: manager, coordinator: coordinator);
  final review = TaskCenterReviewBridge(manager);
  return TaskCenterDependencies(
      query: facade,
      command: facade,
      selectedSourceRetry: facade,
      fileSelection: fileSelection ?? TaskCenterFilePickerHost(),
      openReview: (context, request) => review.open(request, (task) async {
            if (!context.mounted) {
              throw const HomeTrainingContractException(
                  HomeTrainingFailure.unavailable);
            }
            // Construct from the current admitted input before push, with no scheduling gap.
            final page = ImportStagingScreen(
                taskId: task.id,
                parsedQuestions: task.parsedData!,
                warnings: task.warnings,
                diagnostics: task.diagnostics,
                taskManager: manager,
                initialExplanationRetentionMode: task.explanationRetentionMode,
                folderQuery: folderQuery,
                commitService: commitService);
            await Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => page));
          }));
}
