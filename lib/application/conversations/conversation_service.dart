library;

import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import 'conversation_repository.dart';

/// C0 application semantics shared by Presentation and the future A0 adapter.
final class ConversationService {
  ConversationService({
    required ConversationRepositoryPort repository,
    required String Function() conversationIdFactory,
    required String Function() messageIdFactory,
    DateTime Function()? clock,
  })  : _repository = repository,
        _conversationIdFactory = conversationIdFactory,
        _messageIdFactory = messageIdFactory,
        _clock = clock ?? _utcNow;

  static const int defaultConversationLimit = 20;
  static const int defaultMessageLimit = 100;
  static const int maxQueryLimit = 100;

  final ConversationRepositoryPort _repository;
  final String Function() _conversationIdFactory;
  final String Function() _messageIdFactory;
  final DateTime Function() _clock;

  Future<ConversationThreadSlice> startWithUserMessage({
    required ConversationScope scope,
    required String content,
    Iterable<String> fileIds = const <String>[],
  }) async {
    if (scope.isUnavailableLearningSpace) {
      throw const ConversationException(ConversationFailure.scopeUnavailable);
    }
    final normalizedContent = _normalizeContent(content);
    final now = normalizeConversationTimestamp(_clock());
    final conversationId = _newId(
      _conversationIdFactory,
      label: 'Conversation',
    );
    final messageId = _newId(_messageIdFactory, label: 'Message');
    final normalizedFileIds = <String>[];
    final seenFileIds = <String>{};
    for (final fileId in fileIds) {
      try {
        validateConversationId(fileId, label: 'File');
      } on FormatException {
        throw const ConversationException(ConversationFailure.invalidInput);
      }
      if (seenFileIds.add(fileId)) normalizedFileIds.add(fileId);
    }
    final conversation = Conversation(
      conversationId: conversationId,
      scope: scope,
      title: conversationTitleFromMessage(normalizedContent),
      createdAt: now,
      updatedAt: now,
    );
    final firstMessage = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: 1,
      role: ConversationMessageRole.user,
      content: normalizedContent,
      createdAt: now,
    );
    return _repositoryCall(
      () => _repository.createWithFirstMessage(
        conversation: conversation,
        firstMessage: firstMessage,
        fileIds: normalizedFileIds,
        attachedAt: now,
      ),
    );
  }

  Future<AppendMessageResult> appendUserMessage({
    required String conversationId,
    required String content,
  }) {
    _validateInputId(conversationId, label: 'Conversation');
    final normalizedContent = _normalizeContent(content);
    return _repositoryCall(
      () => _repository.appendMessage(
        conversationId: conversationId,
        messageId: _newId(_messageIdFactory, label: 'Message'),
        role: ConversationMessageRole.user,
        content: normalizedContent,
        createdAt: normalizeConversationTimestamp(_clock()),
      ),
    );
  }

  /// Appends one Assistant message through the same C0 append seam.
  ///
  /// The Agent runtime never writes Assistant rows itself: the repository
  /// keeps sequence, transaction, and recency ownership, while this service
  /// keeps message identity, canonical content normalization, and clock
  /// ownership. The API is intentionally Assistant-only; Presentation cannot
  /// write arbitrary roles through it.
  Future<AppendMessageResult> appendAssistantMessage({
    required String conversationId,
    required String content,
  }) {
    _validateInputId(conversationId, label: 'Conversation');
    final normalizedContent = _normalizeContent(content);
    return _repositoryCall(
      () => _repository.appendMessage(
        conversationId: conversationId,
        messageId: _newId(_messageIdFactory, label: 'Message'),
        role: ConversationMessageRole.assistant,
        content: normalizedContent,
        createdAt: normalizeConversationTimestamp(_clock()),
      ),
    );
  }

  Future<AppendFileResult> attachFile({
    required String conversationId,
    required String fileId,
  }) {
    _validateInputId(conversationId, label: 'Conversation');
    _validateInputId(fileId, label: 'File');
    return _repositoryCall(
      () => _repository.attachFile(
        conversationId: conversationId,
        fileId: fileId,
        attachedAt: normalizeConversationTimestamp(_clock()),
      ),
    );
  }

  Future<DetachFileResult> detachFile({
    required String conversationId,
    required String fileId,
  }) {
    _validateInputId(conversationId, label: 'Conversation');
    _validateInputId(fileId, label: 'File');
    return _repositoryCall(
      () => _repository.detachFile(
        conversationId: conversationId,
        fileId: fileId,
        detachedAt: normalizeConversationTimestamp(_clock()),
      ),
    );
  }

  Future<List<ConversationFileRef>> listAttachableFiles({int limit = 100}) {
    _validateLimit(limit);
    return _repositoryCall(() => _repository.listAttachableFiles(limit: limit));
  }

  Future<List<Conversation>> listRecentConversations({
    int limit = defaultConversationLimit,
  }) {
    _validateLimit(limit);
    return _repositoryCall(
      () => _repository.listRecentConversations(limit: limit),
    );
  }

  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    int limit = defaultConversationLimit,
  }) {
    _validateInputId(projectId, label: 'Project');
    _validateLimit(limit);
    return _repositoryCall(
      () => _repository.listConversationsForProject(
        projectId: projectId,
        limit: limit,
      ),
    );
  }

  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    int? beforeSequence,
    int limit = defaultMessageLimit,
  }) {
    _validateInputId(conversationId, label: 'Conversation');
    _validateLimit(limit);
    if (beforeSequence != null && beforeSequence <= 1) {
      throw const ConversationException(ConversationFailure.invalidInput);
    }
    return _repositoryCall(
      () => _repository.loadConversation(
        conversationId: conversationId,
        beforeSequence: beforeSequence,
        limit: limit,
      ),
    );
  }

  Future<void> deleteConversation(String conversationId) {
    _validateInputId(conversationId, label: 'Conversation');
    return _repositoryCall(
      () => _repository.deleteConversation(conversationId),
    );
  }

  String _newId(String Function() factory, {required String label}) {
    final value = factory();
    try {
      validateConversationId(value, label: label);
      return value;
    } on FormatException {
      throw const ConversationException(ConversationFailure.idConflict);
    }
  }

  void _validateInputId(String value, {required String label}) {
    try {
      validateConversationId(value, label: label);
    } on FormatException {
      throw const ConversationException(ConversationFailure.invalidInput);
    }
  }

  String _normalizeContent(String content) {
    try {
      return normalizeConversationMessageContent(content);
    } on FormatException {
      throw const ConversationException(ConversationFailure.invalidInput);
    }
  }

  void _validateLimit(int limit) {
    if (limit < 1 || limit > maxQueryLimit) {
      throw const ConversationException(ConversationFailure.invalidInput);
    }
  }

  Future<T> _repositoryCall<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ConversationException {
      rethrow;
    } on ArgumentError {
      throw const ConversationException(ConversationFailure.dataCorrupt);
    }
  }

  static DateTime _utcNow() => DateTime.now().toUtc();
}
