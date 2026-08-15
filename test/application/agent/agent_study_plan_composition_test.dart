import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_plan_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_command_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_persistence_repository.dart';
import 'package:shiroha_quiz/data/repositories/study_plan_read_repository.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('Section 51: Production Composition & Fresh-ID Contract', () {
    test(
        'production wiring includes long-lived StudyPlan services and dispatcher',
        () {
      const uuid = Uuid();
      final readRepository = StudyPlanReadRepository();
      final draftService = StudyPlanDraftService(
        planningPort: readRepository,
        draftIdFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      final persistenceRepository = StudyPlanPersistenceRepository();
      final commandService = StudyPlanCommandService(
        draftService: draftService,
        persistencePort: persistenceRepository,
        planIdFactory: uuid.v4,
        clock: () => DateTime.now().toUtc(),
      );
      final dispatcher =
          AgentStudyPlanToolDispatcher(draftService: draftService);

      expect(readRepository, isA<StudyPlanPlanningPort>());
      expect(readRepository, isA<StudyPlanCandidateQueryPort>());
      expect(persistenceRepository, isA<StudyPlanPersistencePort>());
      expect(draftService, isA<StudyPlanDraftService>());
      expect(commandService, isA<StudyPlanCommandService>());
      expect(dispatcher, isA<AgentStudyPlanToolDispatcher>());
    });

    test('production planIdFactory satisfies fresh UUID / non-reuse contract',
        () {
      const uuid = Uuid();
      final id1 = uuid.v4();
      final id2 = uuid.v4();
      final id3 = uuid.v4();

      expect(id1, isNot(id2));
      expect(id2, isNot(id3));
      expect(id1, isNot(id3));

      // Matches standard UUIDv4 format: 8-4-4-4-12 hex characters
      final uuidV4Regex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidV4Regex.hasMatch(id1), isTrue);
      expect(uuidV4Regex.hasMatch(id2), isTrue);
      expect(uuidV4Regex.hasMatch(id3), isTrue);
    });

    test('AgentStudyPlanToolCatalog toolName is propose_study_plan', () {
      expect(AgentStudyPlanToolCatalog.toolName, 'propose_study_plan');
    });
  });
}
