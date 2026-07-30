import 'package:flutter/widgets.dart';

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
    required super.child,
  });

  final AiEngineRepository engineRepository;
  final AiService aiService;
  final ImportPipelineService importPipelineService;
  final ImportTaskCoordinator importTaskCoordinator;

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
        !identical(importTaskCoordinator, oldWidget.importTaskCoordinator);
  }
}
