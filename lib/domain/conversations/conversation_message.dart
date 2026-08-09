import 'conversation.dart';

enum ConversationMessageRole { user, assistant }

/// One durable plain-text message in a C0 conversation.
final class ConversationMessage {
  factory ConversationMessage({
    required String messageId,
    required String conversationId,
    required int sequence,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) {
    validateConversationId(messageId, label: 'Message');
    validateConversationId(conversationId, label: 'Conversation');
    if (sequence <= 0) {
      throw const FormatException('Message sequence must be positive.');
    }
    return ConversationMessage._(
      messageId: messageId,
      conversationId: conversationId,
      sequence: sequence,
      role: role,
      content: normalizeConversationMessageContent(content),
      createdAt: normalizeConversationTimestamp(createdAt),
    );
  }

  const ConversationMessage._({
    required this.messageId,
    required this.conversationId,
    required this.sequence,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String messageId;
  final String conversationId;
  final int sequence;
  final ConversationMessageRole role;
  final String content;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationMessage &&
          messageId == other.messageId &&
          conversationId == other.conversationId &&
          sequence == other.sequence &&
          role == other.role &&
          content == other.content &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
      messageId, conversationId, sequence, role, content, createdAt);
}

String normalizeConversationMessageContent(String value) {
  final normalized =
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty || normalized.contains('\u0000')) {
    throw const FormatException(
        'Conversation messages must contain safe text.');
  }
  return normalized;
}
