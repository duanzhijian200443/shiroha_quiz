import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';

void main() {
  test('scope distinguishes Global, active, and unavailable Learning Space',
      () {
    expect(ConversationScope.global().kind, ConversationScopeKind.global);
    expect(
      ConversationScope.learningSpace('project-a').projectId,
      'project-a',
    );
    final unavailable = ConversationScope.unavailableLearningSpace();
    expect(unavailable.kind, ConversationScopeKind.learningSpace);
    expect(unavailable.projectId, isNull);
    expect(unavailable.isUnavailableLearningSpace, isTrue);
  });

  test(
      'title normalization collapses whitespace and truncates deterministically',
      () {
    expect(
        normalizeConversationTitle('  first\n  question  '), 'first question');
    final title = normalizeConversationTitle('甲' * 41);
    expect(title.runes.length, Conversation.maxTitleRunes);
    expect(title.endsWith('…'), isTrue);
  });

  test('message normalizes newlines while preserving internal structure', () {
    final message = ConversationMessage(
      messageId: 'message-a',
      conversationId: 'conversation-a',
      sequence: 1,
      role: ConversationMessageRole.user,
      content: '  first\r\nsecond\rthird  ',
      createdAt: DateTime(2026, 8, 10, 12, 0, 0, 123, 456),
    );

    expect(message.content, 'first\nsecond\nthird');
    expect(message.createdAt.isUtc, isTrue);
    expect(message.createdAt.microsecond, 0);
  });

  test('accepts opaque identity and rejects bounds, timestamp, blank, and NUL',
      () {
    expect(ConversationScope.learningSpace('../学习').projectId, '../学习');
    for (final id in <String>['', 'a' * 129]) {
      expect(() => ConversationScope.learningSpace(id), throwsFormatException);
    }
    expect(
      () => Conversation(
        conversationId: 'conversation-a',
        scope: ConversationScope.global(),
        title: 'title',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
      ),
      throwsFormatException,
    );
    for (final content in <String>['  ', 'a\u0000b']) {
      expect(
        () => ConversationMessage(
          messageId: 'message-a',
          conversationId: 'conversation-a',
          sequence: 1,
          role: ConversationMessageRole.user,
          content: content,
          createdAt: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
    }
  });
}
