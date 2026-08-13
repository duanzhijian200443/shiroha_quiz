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
  Future<List<PersistedQuestion>> listTypedQuestionsByBank(
    String bankName,
  ) {
    return _questionRepository.getPersistedQuestionsByBank(bankName);
  }

  @override
  Future<List<PersistedQuestion>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) {
    return _questionRepository.getPersistedQuestionsByIds(storageIds);
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) {
    return _projectRepository.listProjectBankNames(projectId);
  }
}
