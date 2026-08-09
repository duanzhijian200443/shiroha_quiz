library;

import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';

final class ConversationFileRef {
  const ConversationFileRef({
    required this.fileId,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String fileId;
  final String displayName;
  final String mimeType;
  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationFileRef &&
          fileId == other.fileId &&
          displayName == other.displayName &&
          mimeType == other.mimeType &&
          sizeBytes == other.sizeBytes;

  @override
  int get hashCode => Object.hash(fileId, displayName, mimeType, sizeBytes);
}

final class ConversationThreadSlice {
  ConversationThreadSlice({
    required this.conversation,
    required List<ConversationMessage> messages,
    required List<ConversationFileRef> files,
    required this.hasMoreBefore,
    required this.nextBeforeSequence,
  })  : messages = List<ConversationMessage>.unmodifiable(messages),
        files = List<ConversationFileRef>.unmodifiable(files);

  final Conversation conversation;
  final List<ConversationMessage> messages;
  final List<ConversationFileRef> files;
  final bool hasMoreBefore;
  final int? nextBeforeSequence;
}

final class AppendMessageResult {
  const AppendMessageResult({
    required this.conversation,
    required this.message,
  });

  final Conversation conversation;
  final ConversationMessage message;
}

final class AppendFileResult {
  const AppendFileResult({
    required this.conversation,
    required this.file,
    required this.attached,
  });

  final Conversation conversation;
  final ConversationFileRef file;
  final bool attached;
}

final class DetachFileResult {
  const DetachFileResult({
    required this.conversation,
    required this.fileId,
    required this.detached,
  });

  final Conversation conversation;
  final String fileId;
  final bool detached;
}

abstract interface class ConversationRepositoryPort {
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  });

  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  });

  Future<AppendFileResult> attachFile({
    required String conversationId,
    required String fileId,
    required DateTime attachedAt,
  });

  Future<DetachFileResult> detachFile({
    required String conversationId,
    required String fileId,
    required DateTime detachedAt,
  });

  Future<List<ConversationFileRef>> listAttachableFiles({required int limit});

  Future<List<Conversation>> listRecentConversations({required int limit});

  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  });

  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  });

  Future<void> deleteConversation(String conversationId);
}

enum ConversationFailure {
  invalidInput,
  conversationNotFound,
  projectNotFound,
  fileNotFound,
  scopeUnavailable,
  idConflict,
  dataCorrupt,
  temporarilyUnavailable,
}

final class ConversationException implements Exception {
  const ConversationException(this.failure);

  final ConversationFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ConversationFailure.invalidInput => 'The conversation input is invalid.',
      ConversationFailure.conversationNotFound =>
        'The conversation does not exist.',
      ConversationFailure.projectNotFound =>
        'The learning space does not exist.',
      ConversationFailure.fileNotFound => 'The library file does not exist.',
      ConversationFailure.scopeUnavailable =>
        'The conversation learning space is unavailable.',
      ConversationFailure.idConflict =>
        'A generated conversation identifier is already in use.',
      ConversationFailure.dataCorrupt =>
        'The stored conversation data is invalid.',
      ConversationFailure.temporarilyUnavailable =>
        'Conversation storage is temporarily unavailable.',
    };
    return 'ConversationException(${failure.name}): $detail';
  }
}
