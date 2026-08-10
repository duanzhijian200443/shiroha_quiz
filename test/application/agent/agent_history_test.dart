import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_history.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';

void main() {
  test('keeps the latest 40 messages and drops older history', () {
    final messages = _messages(50);
    final history = AgentHistoryBuilder().build(
      slice: _slice(messages),
      targetMessageId: 'message-50',
    );

    expect(history.messages, hasLength(40));
    expect(history.droppedMessageCount, 10);
    expect(history.messages.first.content, 'message 11');
    expect(history.messages.last.content, 'message 50');
    expect(
      history.messages.every(
        (message) => message.role == AgentProviderMessageRole.user,
      ),
      isTrue,
    );
  });

  test('drops older messages beyond the UTF-8 byte bound', () {
    final messages = _messages(5, content: (index) => '你' * (8 + index));
    final history = AgentHistoryBuilder(
      limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 100),
    ).build(slice: _slice(messages), targetMessageId: 'message-5');

    // Message sizes are 24/27/30/33/36 UTF-8 bytes from oldest to newest;
    // the newest three (99 bytes) fit, the fourth would exceed 100 bytes.
    expect(history.messages, hasLength(3));
    expect(history.droppedMessageCount, 2);
    expect(history.totalUtf8Bytes, 99);
    expect(history.messages.first.content, '你' * 10);
    expect(history.messages.last.content, '你' * 12);
  });

  test('counts multibyte UTF-8 in bytes, not characters', () {
    final messages = <ConversationMessage>[
      ..._messages(1, startSequence: 1, content: (_) => '你'),
      ..._messages(1, startSequence: 2, content: (_) => '你' * 33),
    ];
    final history = AgentHistoryBuilder(
      limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 100),
    ).build(slice: _slice(messages), targetMessageId: 'message-2');

    // 33 x 3 = 99 bytes fits; adding the 3-byte older message would exceed.
    expect(history.messages, hasLength(1));
    expect(history.totalUtf8Bytes, 99);
    expect(history.messages.single.content, '你' * 33);
  });

  test('output stays chronological even for a descending slice', () {
    final messages = _messages(5).reversed.toList(growable: false);
    final history = AgentHistoryBuilder().build(
      slice: _slice(messages),
      targetMessageId: 'message-5',
    );

    expect(history.messages.map((message) => message.content), <String>[
      'message 1',
      'message 2',
      'message 3',
      'message 4',
      'message 5',
    ]);
  });

  test(
    'preserves the target User Message even when the byte bound drops it',
    () {
      // Target is the oldest message; newest-first selection would drop it.
      final messages = <ConversationMessage>[
        ..._messages(1, startSequence: 1, content: (_) => '你' * 20),
        ..._messages(2, startSequence: 2, content: (_) => '你' * 20),
      ];
      final history = AgentHistoryBuilder(
        limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 100),
      ).build(slice: _slice(messages), targetMessageId: 'message-1');

      expect(history.messages, hasLength(1));
      expect(history.messages.single.content, '你' * 20);
      expect(history.droppedMessageCount, 2);
    },
  );

  test('throws typed failure when the target message is missing', () {
    expect(
      () => AgentHistoryBuilder().build(
        slice: _slice(_messages(3)),
        targetMessageId: 'missing',
      ),
      throwsA(
        isA<AgentHistoryException>().having(
          (error) => error.failure,
          'failure',
          AgentHistoryFailure.targetMissing,
        ),
      ),
    );
  });

  test('throws typed failure when the target alone exceeds the byte bound', () {
    expect(
      () => AgentHistoryBuilder(
        limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 30),
      ).build(
        slice: _slice(_messages(1, content: (_) => '你' * 20)),
        targetMessageId: 'message-1',
      ),
      throwsA(
        isA<AgentHistoryException>().having(
          (error) => error.failure,
          'failure',
          AgentHistoryFailure.targetTooLarge,
        ),
      ),
    );
  });
}

ConversationThreadSlice _slice(List<ConversationMessage> messages) {
  return ConversationThreadSlice(
    conversation: Conversation(
      conversationId: 'conversation-a',
      scope: ConversationScope.global(),
      title: 'title',
      createdAt: DateTime.utc(2026, 8, 10),
      updatedAt: DateTime.utc(2026, 8, 10),
    ),
    messages: messages,
    files: const <ConversationFileRef>[],
    hasMoreBefore: false,
    nextBeforeSequence: null,
  );
}

List<ConversationMessage> _messages(
  int count, {
  int startSequence = 1,
  String Function(int index)? content,
}) {
  return List<ConversationMessage>.generate(count, (index) {
    final sequence = startSequence + index;
    return ConversationMessage(
      messageId: 'message-$sequence',
      conversationId: 'conversation-a',
      sequence: sequence,
      role: ConversationMessageRole.user,
      content: content?.call(index) ?? 'message $sequence',
      createdAt: DateTime.utc(2026, 8, 10, 12, sequence),
    );
  });
}
