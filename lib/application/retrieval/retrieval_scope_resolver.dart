library;

import '../conversations/conversation_repository.dart';
import '../conversations/conversation_service.dart';
import '../projects/project_repository.dart';
import 'retrieval.dart';
import 'retrieval_ports.dart';

final class ApplicationRetrievalScopeResolver
    implements RetrievalScopeResolverPort {
  ApplicationRetrievalScopeResolver(
      {required ProjectRepository projectRepository,
      required ConversationService conversationService})
      : _projectRepository = projectRepository,
        _conversationService = conversationService;

  final ProjectRepository _projectRepository;
  final ConversationService _conversationService;

  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async {
    try {
      return switch (scope) {
        RetrievalFilesScope(:final fileIds) => _validateIds(fileIds),
        RetrievalProjectScope(:final projectId) =>
          _projectRepository.listProjectFileIds(projectId),
        RetrievalConversationAttachmentsScope(:final conversationId) =>
          (await _conversationService.loadConversation(
                  conversationId: conversationId, limit: 1))
              .files
              .map((file) => file.fileId)
              .toList(growable: false),
      };
    } on RetrievalException {
      rethrow;
    } on ProjectRepositoryException catch (error) {
      throw RetrievalException(
          error.failure == ProjectRepositoryFailure.projectNotFound
              ? RetrievalFailure.scopeUnavailable
              : RetrievalFailure.internalError);
    } on ConversationException catch (error) {
      throw RetrievalException(
          error.failure == ConversationFailure.conversationNotFound ||
                  error.failure == ConversationFailure.scopeUnavailable
              ? RetrievalFailure.scopeUnavailable
              : RetrievalFailure.temporarilyUnavailable);
    }
  }

  List<String> _validateIds(List<String> ids) {
    if (ids
        .any((id) => id.isEmpty || id.length > 128 || id.contains('\u0000'))) {
      throw const RetrievalException(RetrievalFailure.invalidRequest);
    }
    return ids;
  }
}
