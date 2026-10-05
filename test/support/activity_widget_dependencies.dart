import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_commit_command.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_entry_guard.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_generation.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/application/study_query/study_query_ports.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/ui/dependencies/ai_dependencies_scope.dart';

class _Engine extends Fake implements AiEngineRepository {}

class RecordingExamAi extends Fake implements AiService {
  int calls = 0;
  @override
  Future<String> judgeAnswer(
      String question, String answer, String user) async {
    calls++;
    return '100';
  }
}

class _Pipeline extends Fake implements ImportPipelineService {}

class _Coordinator extends Fake implements ImportTaskCoordinator {}

class _Query extends Fake implements StudyQuestionQueryPort {}

class _Provider extends Fake implements AiAnswerProviderPort {}

class _Commit extends Fake implements AiAnswerCommitPersistencePort {}

Widget activityWidgetDependencies(
        {required Widget child,
        required ExamMutationPersistencePort exam,
        RecordingExamAi? ai}) =>
    AiDependenciesScope(
        engineRepository: _Engine(),
        aiConfigService: const UnavailableAiConfigPresentationService(),
        aiService: ai ?? RecordingExamAi(),
        importPipelineService: _Pipeline(),
        importTaskCoordinator: _Coordinator(),
        answerGenerationService: AiAnswerGenerationService(
            questionPort: _Query(),
            providerPort: _Provider(),
            idFactory: () => 'unused',
            clock: () => DateTime.utc(2026)),
        answerCommitCommand: AiAnswerCommitCommand(persistencePort: _Commit()),
        answerEntryGuard: AiAnswerEntryGuard(
            questionPort: _Query(), clock: () => DateTime.utc(2026)),
        examMutationCommand: ExamMutationCommand(exam),
        child: child);
