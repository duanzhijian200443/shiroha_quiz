part of 'agent_runtime.dart';

final class AgentTurnFinalizer {
  AgentTurnFinalizer(this._conversationService, this._limits);
  final ConversationService _conversationService;
  final AgentRuntimeLimits _limits;
  final Map<(String, String), _PendingFinalAssistant> _pendingFinalAssistant =
      {};

  Future<
          ({
            ConversationThreadSlice slice,
            ConversationMessage target,
            ConversationMessage? existingAssistant
          })>
      _prepareTarget(_ActiveTurn turn,
          {required String conversationId,
          required String userMessageId}) async {
    final slice = await _loadSlice(turn, conversationId);
    if (slice.conversation.scope.isUnavailableLearningSpace) {
      throw const _TurnFailure(AgentTurnFailure.scopeUnavailable);
    }
    final target = slice.messages
        .where((message) => message.messageId == userMessageId)
        .firstOrNull;
    if (target == null || target.role != ConversationMessageRole.user) {
      throw const _TurnFailure(AgentTurnFailure.invalidTarget);
    }
    final hasLaterUserMessage = slice.messages.any(
      (message) =>
          message.role == ConversationMessageRole.user &&
          message.sequence > target.sequence,
    );
    if (hasLaterUserMessage) {
      throw const _TurnFailure(AgentTurnFailure.invalidTarget);
    }
    final existingAssistant = slice.messages
        .where(
          (message) =>
              message.role == ConversationMessageRole.assistant &&
              message.sequence > target.sequence,
        )
        .firstOrNull;
    if (existingAssistant != null) {
      return (
        slice: slice,
        target: target,
        existingAssistant: existingAssistant
      );
    }

    return (slice: slice, target: target, existingAssistant: null);
  }

  Future<ConversationMessage?> _resumePending(
      _ActiveTurn turn, ConversationMessage target) async {
    final key = (target.conversationId, target.messageId);
    final pending = _pendingFinalAssistant[key];
    if (pending == null) return null;
    final message = await _appendAssistantWithRecovery(turn,
        target: target, pending: pending);
    _pendingFinalAssistant.remove(key);
    return message;
  }

  Future<AgentTurnResult> _finalize(
      _ActiveTurn turn, ConversationMessage target, String finalText) async {
    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    final key = (target.conversationId, target.messageId);
    final pending = _PendingFinalAssistant(
        conversationId: target.conversationId,
        userMessageId: target.messageId,
        finalText: finalText);
    _pendingFinalAssistant[key] = pending;
    try {
      final message = await _appendAssistantWithRecovery(turn,
          target: target, pending: pending);
      _pendingFinalAssistant.remove(key);
      return AgentTurnSuccess(assistantMessage: message);
    } on _TurnFailure catch (error) {
      if (error.failure == AgentTurnFailure.conversationUnavailable ||
          error.failure == AgentTurnFailure.scopeUnavailable) {
        _pendingFinalAssistant.remove(key);
      }
      rethrow;
    }
  }

  Future<ConversationThreadSlice> _loadSlice(
    _ActiveTurn turn,
    String conversationId,
  ) async {
    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    try {
      return await _conversationService.loadConversation(
        conversationId: conversationId,
        limit: _limits.maxHistoryMessages,
      );
    } on ConversationException catch (error) {
      throw _conversationReadFailure(error.failure);
    }
  }

  Future<ConversationMessage> _appendAssistantWithRecovery(
    _ActiveTurn turn, {
    required ConversationMessage target,
    required _PendingFinalAssistant pending,
  }) async {
    try {
      final result = await _conversationService.appendAssistantMessage(
        conversationId: pending.conversationId,
        content: pending.finalText,
      );
      return result.message;
    } on ConversationException catch (error) {
      switch (error.failure) {
        case ConversationFailure.conversationNotFound:
          throw const _TurnFailure(AgentTurnFailure.conversationUnavailable);
        case ConversationFailure.scopeUnavailable:
        case ConversationFailure.projectNotFound:
          throw const _TurnFailure(AgentTurnFailure.scopeUnavailable);
        case ConversationFailure.invalidInput:
        case ConversationFailure.fileNotFound:
          throw const _TurnFailure(AgentTurnFailure.persistenceFailed);
        case ConversationFailure.idConflict:
        case ConversationFailure.dataCorrupt:
        case ConversationFailure.temporarilyUnavailable:
          return _recoverAmbiguousAppend(
            turn,
            target: target,
            pending: pending,
          );
      }
    }
  }

  /// Ambiguous append recovery: reload and check whether the expected
  /// Assistant row exists; only a confirmed-absent state retries the same
  /// final text. Unconfirmable storage keeps a typed persistence failure.
  Future<ConversationMessage> _recoverAmbiguousAppend(
    _ActiveTurn turn, {
    required ConversationMessage target,
    required _PendingFinalAssistant pending,
  }) async {
    final ConversationThreadSlice slice;
    try {
      slice = await _conversationService.loadConversation(
        conversationId: pending.conversationId,
        limit: _limits.maxHistoryMessages,
      );
    } on ConversationException catch (error) {
      throw switch (error.failure) {
        ConversationFailure.conversationNotFound => const _TurnFailure(
            AgentTurnFailure.conversationUnavailable,
          ),
        ConversationFailure.scopeUnavailable ||
        ConversationFailure.projectNotFound =>
          const _TurnFailure(
            AgentTurnFailure.scopeUnavailable,
          ),
        _ => const _TurnFailure(AgentTurnFailure.persistenceFailed),
      };
    }
    final expected = slice.messages
        .where(
          (message) =>
              message.role == ConversationMessageRole.assistant &&
              message.sequence > target.sequence &&
              message.content == pending.finalText,
        )
        .firstOrNull;
    if (expected != null) return expected;

    _throwIfExpired(turn);
    _throwIfCancelled(turn);
    try {
      final result = await _conversationService.appendAssistantMessage(
        conversationId: pending.conversationId,
        content: pending.finalText,
      );
      return result.message;
    } on ConversationException catch (error) {
      throw switch (error.failure) {
        ConversationFailure.conversationNotFound => const _TurnFailure(
            AgentTurnFailure.conversationUnavailable,
          ),
        ConversationFailure.scopeUnavailable ||
        ConversationFailure.projectNotFound =>
          const _TurnFailure(
            AgentTurnFailure.scopeUnavailable,
          ),
        _ => const _TurnFailure(AgentTurnFailure.persistenceFailed),
      };
    }
  }
}

_TurnFailure _conversationReadFailure(ConversationFailure failure) {
  return switch (failure) {
    ConversationFailure.invalidInput => const _TurnFailure(
        AgentTurnFailure.invalidTarget,
      ),
    ConversationFailure.conversationNotFound => const _TurnFailure(
        AgentTurnFailure.conversationUnavailable,
      ),
    ConversationFailure.scopeUnavailable ||
    ConversationFailure.projectNotFound =>
      const _TurnFailure(
        AgentTurnFailure.scopeUnavailable,
      ),
    ConversationFailure.temporarilyUnavailable => const _TurnFailure(
        AgentTurnFailure.temporarilyUnavailable,
      ),
    ConversationFailure.fileNotFound ||
    ConversationFailure.idConflict ||
    ConversationFailure.dataCorrupt =>
      const _TurnFailure(
        AgentTurnFailure.internalError,
      ),
  };
}

final class _PendingFinalAssistant {
  const _PendingFinalAssistant({
    required this.conversationId,
    required this.userMessageId,
    required this.finalText,
  });

  final String conversationId;
  final String userMessageId;
  final String finalText;
}
