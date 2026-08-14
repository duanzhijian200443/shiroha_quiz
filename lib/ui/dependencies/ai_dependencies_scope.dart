import 'package:flutter/widgets.dart';

import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/answers/ai_answer_generation.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../services/ai_service.dart';
import '../../services/import_pipeline/import_pipeline_service.dart';
import '../../services/import_pipeline/import_task_coordinator.dart';

class AiDependenciesScope extends InheritedWidget {
  const AiDependenciesScope({
    super.key,
    required this.engineRepository,
    required this.aiService,
    required this.importPipelineService,
    required this.importTaskCoordinator,
    required this.answerGenerationService,
    required this.answerCommitCommand,
    required super.child,
  });

  final AiEngineRepository engineRepository;
  final AiService aiService;
  final ImportPipelineService importPipelineService;
  final ImportTaskCoordinator importTaskCoordinator;

  /// P7 Application generation seam: Presentation never touches the
  /// provider adapter or any provider/DB type directly.
  final AiAnswerGenerationService answerGenerationService;

  /// P7 Application commit seam: the only formal write path for AI answers.
  final AiAnswerCommitCommand answerCommitCommand;

  static AiDependenciesScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AiDependenciesScope>();
    if (scope == null) {
      throw const AiEngineDependencyException();
    }
    return scope;
  }

  @override
  bool updateShouldNotify(AiDependenciesScope oldWidget) {
    return !identical(engineRepository, oldWidget.engineRepository) ||
        !identical(aiService, oldWidget.aiService) ||
        !identical(importPipelineService, oldWidget.importPipelineService) ||
        !identical(importTaskCoordinator, oldWidget.importTaskCoordinator) ||
        !identical(
            answerGenerationService, oldWidget.answerGenerationService) ||
        !identical(answerCommitCommand, oldWidget.answerCommitCommand);
  }
}
