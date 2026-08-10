/// Deterministic bounded persisted-message history for one Agent turn.
library;

import 'dart:convert';

import '../../domain/conversations/conversation_message.dart';
import '../conversations/conversation_repository.dart';
import 'agent_provider.dart';
import 'agent_runtime_limits.dart';

/// The bounded, chronological history sent to the Provider.
final class AgentHistory {
  const AgentHistory({
    required this.messages,
    required this.totalUtf8Bytes,
    required this.droppedMessageCount,
  });

  /// Chronological persisted User/Assistant messages, newest-kept.
  final List<AgentProviderMessage> messages;

  /// Total UTF-8 byte size of the kept message contents.
  final int totalUtf8Bytes;

  /// Number of persisted messages dropped by the message/byte bounds.
  final int droppedMessageCount;
}

enum AgentHistoryFailure { targetMissing, targetTooLarge }

final class AgentHistoryException implements Exception {
  const AgentHistoryException(this.failure);

  final AgentHistoryFailure failure;

  @override
  String toString() => 'AgentHistoryException(${failure.name})';
}

/// Builds the bounded history for one turn.
///
/// Rules:
/// - only persisted User/Assistant visible messages are used;
/// - output stays chronological;
/// - newest messages win the message-count and UTF-8 byte bounds;
/// - the target User Message is never silently dropped;
/// - no tool trace, system prompt history, reasoning, or provider state is
///   included;
/// - no tokenizer, summary memory, or compression.
final class AgentHistoryBuilder {
  AgentHistoryBuilder({AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _limits = limits;

  final AgentRuntimeLimits _limits;

  AgentHistory build({
    required ConversationThreadSlice slice,
    required String targetMessageId,
  }) {
    final all = slice.messages;
    final targetIndex = all.indexWhere(
      (message) => message.messageId == targetMessageId,
    );
    if (targetIndex < 0) {
      throw const AgentHistoryException(AgentHistoryFailure.targetMissing);
    }
    final targetBytes = _utf8Length(all[targetIndex].content);
    if (targetBytes > _limits.maxHistoryUtf8Bytes) {
      throw const AgentHistoryException(AgentHistoryFailure.targetTooLarge);
    }

    var start = all.length - _limits.maxHistoryMessages;
    if (start < 0) start = 0;
    final candidates = all.sublist(start);

    // Newest-first accumulation until the UTF-8 byte bound; everything older
    // than the first overflowing message is dropped.
    final keptNewestFirst = <ConversationMessage>[];
    var totalBytes = 0;
    for (var index = candidates.length - 1; index >= 0; index--) {
      final message = candidates[index];
      final bytes = _utf8Length(message.content);
      if (totalBytes + bytes > _limits.maxHistoryUtf8Bytes) break;
      keptNewestFirst.add(message);
      totalBytes += bytes;
    }

    // Absolute target preservation: when the target fell outside the
    // newest-kept suffix, force it in and drop the oldest non-target kept
    // messages until the byte bound holds again.
    var targetKept = keptNewestFirst.any(
      (message) => message.messageId == targetMessageId,
    );
    if (!targetKept) {
      keptNewestFirst.add(all[targetIndex]);
      totalBytes += targetBytes;
      while (totalBytes > _limits.maxHistoryUtf8Bytes) {
        final oldestNonTarget = keptNewestFirst.indexWhere(
          (message) => message.messageId != targetMessageId,
        );
        if (oldestNonTarget < 0) break;
        totalBytes -= _utf8Length(keptNewestFirst[oldestNonTarget].content);
        keptNewestFirst.removeAt(oldestNonTarget);
      }
    }

    keptNewestFirst.sort(
      (left, right) => left.sequence.compareTo(right.sequence),
    );
    final messages = <AgentProviderMessage>[
      for (final message in keptNewestFirst)
        AgentProviderMessage(
          role: message.role == ConversationMessageRole.user
              ? AgentProviderMessageRole.user
              : AgentProviderMessageRole.assistant,
          content: message.content,
        ),
    ];
    return AgentHistory(
      messages: List<AgentProviderMessage>.unmodifiable(messages),
      totalUtf8Bytes: totalBytes,
      droppedMessageCount: all.length - keptNewestFirst.length,
    );
  }

  static int _utf8Length(String value) => utf8.encode(value).length;
}
