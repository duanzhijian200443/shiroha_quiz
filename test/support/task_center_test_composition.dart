import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/task_center/task_center_facade.dart';
import 'package:shiroha_quiz/services/task_center/task_center_file_picker_host.dart';
import 'package:shiroha_quiz/services/task_center/task_center_review_bridge.dart';
import 'package:shiroha_quiz/ui/dependencies/task_center_dependencies.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

typedef TaskReviewPageBuilder = Widget Function(BuildContext, ImportTask);
typedef TaskCenterRetryFilePicker = Future<FilePickerResult?> Function();

/// Synthetic legacy test composition; raw compatibility input stays here.
TaskCenterDependencies testTaskCenterDependencies(
    {required TaskManager manager,
    ImportTaskCoordinator? coordinator,
    TaskCenterRetryFilePicker? picker,
    ValueChanged<ImportTask>? onReview,
    TaskReviewPageBuilder? reviewBuilder}) {
  final facade = TaskCenterFacade(
      taskManager: manager,
      coordinator: coordinator ?? ImportTaskCoordinator(taskManager: manager));
  return TaskCenterDependencies(
      query: facade,
      command: facade,
      selectedSourceRetry: facade,
      fileSelection:
          TaskCenterFilePickerHost(picker: picker, exists: (_) async => true),
      openReview: (context, request) =>
          TaskCenterReviewBridge(manager).open(request, (task) async {
            if (!context.mounted) {
              throw const HomeTrainingContractException(
                  HomeTrainingFailure.unavailable);
            }
            if (onReview != null) {
              onReview(task);
              return;
            }
            final page = reviewBuilder?.call(context, task) ??
                ImportStagingScreen(
                    taskId: task.id,
                    parsedQuestions: task.parsedData!,
                    warnings: task.warnings,
                    diagnostics: task.diagnostics,
                    taskManager: manager,
                    initialExplanationRetentionMode:
                        task.explanationRetentionMode);
            await Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => page));
          }));
}
