import '../../application/projects/project_repository.dart';
import '../../application/supplemental_answers/supplemental_answer_target_port.dart';
import '../models/persisted_question.dart';
import 'question_repository.dart';

/// Data-layer implementation of the P6 target-scope port.
///
/// Delegates typed dual-reads to [QuestionRepository] and bank relations to
/// [ProjectRepository]; the application layer never sees SQL or rows.
final class SupplementalAnswerTargetRepository
    implements SupplementalAnswerTargetPort {
  const SupplementalAnswerTargetRepository({
    required QuestionRepository questionRepository,
    required ProjectRepository projectRepository,
  })  : _questionRepository = questionRepository,
        _projectRepository = projectRepository;

  final QuestionRepository _questionRepository;
  final ProjectRepository _projectRepository;

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByBank(
    String bankName,
  ) async {
    final questions = await _questionRepository.getPersistedQuestionsByBank(
      bankName,
    );
    return questions.map(_projectRead).toList(growable: false);
  }

  @override
  Future<List<SupplementalTargetRead>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) async {
    final questions = await _questionRepository.getPersistedQuestionsByIds(
      storageIds,
    );
    return questions.map(_projectRead).toList(growable: false);
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) {
    return _projectRepository.listProjectBankNames(projectId);
  }
}

SupplementalTargetRead _projectRead(PersistedQuestion question) {
  return switch (question) {
    TypedPersistedQuestion(
      :final storageId,
      :final bankName,
      :final draft,
    ) =>
      SupplementalTargetRead(
        storageId: storageId,
        bankName: bankName,
        typedDraft: draft,
      ),
    LegacyPersistedQuestion(question: final legacy) => SupplementalTargetRead(
        storageId: legacy.id ?? '',
        bankName: legacy.bankName,
      ),
  };
}
