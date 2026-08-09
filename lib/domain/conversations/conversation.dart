/// Stable C0 conversation scope.
///
/// A learning-space scope with a null [projectId] is an explicit unavailable
/// lifecycle state produced when the referenced Project is deleted. It never
/// means Global and must not be used to create a new conversation.
final class ConversationScope {
  factory ConversationScope.global() => const ConversationScope._(
        kind: ConversationScopeKind.global,
        projectId: null,
      );

  factory ConversationScope.learningSpace(String projectId) {
    validateConversationId(projectId, label: 'Project');
    return ConversationScope._(
      kind: ConversationScopeKind.learningSpace,
      projectId: projectId,
    );
  }

  factory ConversationScope.unavailableLearningSpace() =>
      const ConversationScope._(
        kind: ConversationScopeKind.learningSpace,
        projectId: null,
      );

  const ConversationScope._({required this.kind, required this.projectId});

  final ConversationScopeKind kind;
  final String? projectId;

  bool get isUnavailableLearningSpace =>
      kind == ConversationScopeKind.learningSpace && projectId == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationScope &&
          kind == other.kind &&
          projectId == other.projectId;

  @override
  int get hashCode => Object.hash(kind, projectId);
}

enum ConversationScopeKind { global, learningSpace }

/// Durable C0 conversation metadata.
final class Conversation {
  factory Conversation({
    required String conversationId,
    required ConversationScope scope,
    required String title,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    validateConversationId(conversationId, label: 'Conversation');
    final normalizedTitle = normalizeConversationTitle(title);
    final normalizedCreatedAt = normalizeConversationTimestamp(createdAt);
    final normalizedUpdatedAt = normalizeConversationTimestamp(updatedAt);
    if (normalizedUpdatedAt.isBefore(normalizedCreatedAt)) {
      throw const FormatException(
        'Conversation updated time must not precede creation time.',
      );
    }
    return Conversation._(
      conversationId: conversationId,
      scope: scope,
      title: normalizedTitle,
      createdAt: normalizedCreatedAt,
      updatedAt: normalizedUpdatedAt,
    );
  }

  const Conversation._({
    required this.conversationId,
    required this.scope,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  static const int maxTitleRunes = 40;

  final String conversationId;
  final ConversationScope scope;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation withUpdatedAt(DateTime value) => Conversation(
        conversationId: conversationId,
        scope: scope,
        title: title,
        createdAt: createdAt,
        updatedAt: value,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Conversation &&
          conversationId == other.conversationId &&
          scope == other.scope &&
          title == other.title &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode =>
      Object.hash(conversationId, scope, title, createdAt, updatedAt);
}

String normalizeConversationTitle(String value) {
  final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) {
    throw const FormatException('Conversation titles must not be empty.');
  }
  final runes = collapsed.runes.toList(growable: false);
  if (runes.length <= Conversation.maxTitleRunes) return collapsed;
  return '${String.fromCharCodes(runes.take(Conversation.maxTitleRunes - 1))}…';
}

String conversationTitleFromMessage(String normalizedContent) {
  return normalizeConversationTitle(normalizedContent);
}

DateTime normalizeConversationTimestamp(DateTime value) {
  final milliseconds = value.millisecondsSinceEpoch;
  if (milliseconds < 0) {
    throw const FormatException(
        'Conversation timestamps must be non-negative.');
  }
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
}

void validateConversationId(String value, {required String label}) {
  final length = value.runes.length;
  if (length < 1 || length > 128) {
    throw FormatException(
      '$label identifiers must use the bounded opaque token format.',
    );
  }
}
