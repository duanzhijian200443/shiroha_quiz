import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';

final class _Repository extends Fake implements ConversationRepositoryPort {
  Conversation? createdConversation;
  ConversationMessage? createdMessage;
  List<String>? createdFileIds;
  String? appendedContent;
  ConversationMessageRole? appendedRole;
  String? appendedMessageId;
  DateTime? appendedCreatedAt;
  int nextAppendedSequence = 2;
  ConversationFailure? appendFailure;
  int? receivedLimit;
  int? receivedBeforeSequence;

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    createdConversation = conversation;
    createdMessage = firstMessage;
    createdFileIds = fileIds;
    return ConversationThreadSlice(
      conversation: conversation,
      messages: <ConversationMessage>[firstMessage],
      files: const <ConversationFileRef>[],
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }

  @override
  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) async {
    appendedContent = content;
    appendedRole = role;
    appendedMessageId = messageId;
    appendedCreatedAt = createdAt;
    final failure = appendFailure;
    if (failure != null) {
      throw ConversationException(failure);
    }
    final message = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: nextAppendedSequence++,
      role: role,
      content: content,
      createdAt: createdAt,
    );
    return AppendMessageResult(
      conversation: Conversation(
        conversationId: conversationId,
        scope: ConversationScope.global(),
        title: 'title',
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
      message: message,
    );
  }

  ConversationScope? movedTargetScope;
  DateTime? movedAt;
  ConversationFailure? moveFailure;

  @override
  Future<MoveConversationResult> moveConversation({
    required String conversationId,
    required ConversationScope targetScope,
    required DateTime movedAt,
  }) async {
    movedTargetScope = targetScope;
    this.movedAt = movedAt;
    final failure = moveFailure;
    if (failure != null) {
      throw ConversationException(failure);
    }
    final now = DateTime.utc(2026, 8, 10, 15);
    return MoveConversationResult(
      conversation: Conversation(
        conversationId: conversationId,
        scope: targetScope,
        title: 'title',
        createdAt: now,
        updatedAt: now,
      ),
      moved: true,
    );
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async {
    receivedLimit = limit;
    receivedBeforeSequence = beforeSequence;
    final now = DateTime.utc(2026, 8, 10);
    return ConversationThreadSlice(
      conversation: Conversation(
        conversationId: conversationId,
        scope: ConversationScope.global(),
        title: 'title',
        createdAt: now,
        updatedAt: now,
      ),
      messages: const <ConversationMessage>[],
      files: const <ConversationFileRef>[],
      hasMoreBefore: false,
      nextBeforeSequence: null,
    );
  }
}

void main() {
  late _Repository repository;
  late ConversationService service;
  var conversationSequence = 0;
  var messageSequence = 0;

  setUp(() {
    repository = _Repository();
    service = ConversationService(
      repository: repository,
      conversationIdFactory: () => 'conversation-${++conversationSequence}',
      messageIdFactory: () => 'message-${++messageSequence}',
      clock: () => DateTime.utc(2026, 8, 10, 12),
    );
  });

  test(
    'start normalizes title/content and deduplicates transient files',
    () async {
      final result = await service.startWithUserMessage(
        scope: ConversationScope.learningSpace('project-a'),
        content: '  first\r\n question  ',
        fileIds: const <String>['file-a', 'file-a', 'file-b'],
      );

      expect(result.conversation.title, 'first question');
      expect(result.messages.single.content, 'first\n question');
      expect(result.messages.single.role, ConversationMessageRole.user);
      expect(repository.createdFileIds, <String>['file-a', 'file-b']);
    },
  );

  test('C0 append is User-only and uses normalized content', () async {
    final result = await service.appendUserMessage(
      conversationId: 'conversation-a',
      content: '  next\rline  ',
    );

    expect(repository.appendedContent, 'next\nline');
    expect(repository.appendedRole, ConversationMessageRole.user);
    expect(result.message.role, ConversationMessageRole.user);
  });

  test('appendAssistantMessage is Assistant-only and normalized', () async {
    final result = await service.appendAssistantMessage(
      conversationId: 'conversation-a',
      content: '  hello\r\nworld  ',
    );

    expect(repository.appendedRole, ConversationMessageRole.assistant);
    expect(repository.appendedContent, 'hello\nworld');
    expect(repository.appendedCreatedAt, DateTime.utc(2026, 8, 10, 12));
    expect(result.message.role, ConversationMessageRole.assistant);
    expect(repository.appendedMessageId, startsWith('message-'));
  });

  test(
    'appendAssistantMessage keeps sequence in the shared append seam',
    () async {
      await service.appendUserMessage(
        conversationId: 'conversation-a',
        content: 'question',
      );
      final assistant = await service.appendAssistantMessage(
        conversationId: 'conversation-a',
        content: 'answer',
      );

      expect(assistant.message.sequence, 3);
    },
  );

  test('appendAssistantMessage propagates typed storage failures', () async {
    repository.appendFailure = ConversationFailure.conversationNotFound;
    await expectLater(
      service.appendAssistantMessage(
        conversationId: 'conversation-a',
        content: 'answer',
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.conversationNotFound,
        ),
      ),
    );

    repository.appendFailure = ConversationFailure.scopeUnavailable;
    await expectLater(
      service.appendAssistantMessage(
        conversationId: 'conversation-a',
        content: 'answer',
      ),
      throwsA(
        isA<ConversationException>().having(
          (error) => error.failure,
          'failure',
          ConversationFailure.scopeUnavailable,
        ),
      ),
    );
  });

  test(
    'unavailable scope and invalid limits fail before persistence',
    () async {
      await expectLater(
        service.startWithUserMessage(
          scope: ConversationScope.unavailableLearningSpace(),
          content: 'question',
        ),
        throwsA(
          isA<ConversationException>().having(
            (error) => error.failure,
            'failure',
            ConversationFailure.scopeUnavailable,
          ),
        ),
      );
      expect(
        () => service.listRecentConversations(limit: 101),
        throwsA(isA<ConversationException>()),
      );
      expect(repository.createdConversation, isNull);
    },
  );

  test('load forwards bounded before-sequence slicing', () async {
    await service.loadConversation(
      conversationId: 'conversation-a',
      beforeSequence: 10,
      limit: 20,
    );
    expect(repository.receivedLimit, 20);
    expect(repository.receivedBeforeSequence, 10);
  });

  group('CONV-MOVE application service', () {
    test(
        'invalid target (unavailableLearningSpace) is rejected before repository',
        () async {
      await expectLater(
        service.moveConversation(
          conversationId: 'conv-1',
          targetScope: ConversationScope.unavailableLearningSpace(),
        ),
        throwsA(
          isA<ConversationException>().having(
            (e) => e.failure,
            'failure',
            ConversationFailure.scopeUnavailable,
          ),
        ),
      );
      expect(repository.movedTargetScope, isNull);
    });

    test('invalid conversation ID is rejected before repository', () async {
      await expectLater(
        service.moveConversation(
          conversationId: '',
          targetScope: ConversationScope.global(),
        ),
        throwsA(
          isA<ConversationException>().having(
            (e) => e.failure,
            'failure',
            ConversationFailure.invalidInput,
          ),
        ),
      );
      expect(repository.movedTargetScope, isNull);
    });

    test(
        'clock authority is owned by service and passed normalized to repository',
        () async {
      final res = await service.moveConversation(
        conversationId: 'conv-1',
        targetScope: ConversationScope.learningSpace('project-1'),
      );
      expect(res.moved, isTrue);
      expect(repository.movedTargetScope,
          ConversationScope.learningSpace('project-1'));
      expect(repository.movedAt, DateTime.utc(2026, 8, 10, 12));
    });

    test('repository typed failures propagate safely', () async {
      repository.moveFailure = ConversationFailure.projectNotFound;
      await expectLater(
        service.moveConversation(
          conversationId: 'conv-1',
          targetScope: ConversationScope.learningSpace('project-missing'),
        ),
        throwsA(
          isA<ConversationException>().having(
            (e) => e.failure,
            'failure',
            ConversationFailure.projectNotFound,
          ),
        ),
      );
    });
  });
}
