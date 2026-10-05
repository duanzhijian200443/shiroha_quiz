import 'package:flutter/widgets.dart';
import '../../application/home_training_result.dart';
import '../../application/task_center/task_center_contracts.dart';
import '../../application/task_center/retry_file_selection.dart';

typedef TaskCenterReviewNavigator = Future<HomeTrainingResult<HomeTrainingUnit>>
    Function(BuildContext context, TaskCenterReviewNavigationRequest request);

/// Only safe Application seams cross into TaskCenter and Home presentation.
final class TaskCenterDependencies {
  const TaskCenterDependencies(
      {required this.query,
      required this.command,
      required this.selectedSourceRetry,
      required this.fileSelection,
      required this.openReview});
  final TaskCenterQuery query;
  final TaskCenterCommand command;
  final TaskCenterSelectedSourceRetry selectedSourceRetry;
  final RetryFileSelectionHost fileSelection;
  final TaskCenterReviewNavigator openReview;
}
