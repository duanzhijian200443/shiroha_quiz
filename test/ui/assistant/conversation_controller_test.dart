import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';
import 'package:shiroha_quiz/ui/assistant/conversation_controller.dart';

void main() {
  test(
      'persists User before starting exact target and projects final Assistant',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final starts = <(String, String)>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        starts.add((conversationId, userMessageId));
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    expect(await controller.send('first question'), isTrue);
    expect(repository.messages, hasLength(1));
    expect(repository.messages.single.role, ConversationMessageRole.user);
    expect(starts, <(String, String)>[
      ('conversation-1', repository.messages.single.messageId),
    ]);
    expect(controller.turnPhase, AssistantTurnPhase.thinking);

    turns.single.emit(const AgentTurnTextDelta('A'));
    turns.single.emit(const AgentTurnTextDelta('B'));
    await _flush();
    expect(controller.transientAssistantText, 'AB');
    expect(controller.activeThread!.messages, hasLength(1));

    final assistant = repository.persistAssistant('AB');
    turns.single.complete(AgentTurnSuccess(assistantMessage: assistant));
    await _flush();
    expect(controller.transientAssistantText, isEmpty);
    expect(controller.activeThread!.messages, hasLength(2));
    expect(controller.activeThread!.messages.last, assistant);
    expect(controller.turnPhase, AssistantTurnPhase.idle);
  });

  test('projects Web and local tool lifecycle without exposing payloads',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness();
    final controller = _controller(repository, start: turn.start);

    await controller.send('study overview');
    turn.emit(
      const AgentTurnWebSearchEvent(AgentProviderWebSearchPhase.searching),
    );
    await _flush();
    expect(controller.turnPhase, AssistantTurnPhase.searchingWeb);
    expect(controller.turnStatusMessage, '正在搜索网页…');

    turn.emit(
      const AgentTurnToolCall(
        callId: 'private-call-id',
        name: 'get_study_overview',
      ),
    );
    await _flush();
    expect(controller.turnPhase, AssistantTurnPhase.usingLocalTool);
    expect(controller.turnStatusMessage, '正在读取学习概览…');
    expect(controller.turnStatusMessage, isNot(contains('private-call-id')));
  });

  test('failure retry targets same User and never appends a duplicate User',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final targets = <String>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        targets.add(userMessageId);
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    await controller.send('retry me');
    turns[0].emit(const AgentTurnTextDelta('partial'));
    turns[0].complete(
      const AgentTurnFailed(AgentTurnFailure.temporarilyUnavailable),
    );
    await _flush();
    expect(controller.canRetry, isTrue);
    expect(controller.transientAssistantText, 'partial');
    expect(repository.messages.where(_isUser), hasLength(1));

    expect(await controller.retryLastTurn(), isTrue);
    expect(targets, <String>[targets.first, targets.first]);
    expect(repository.messages.where(_isUser), hasLength(1));

    final assistant = repository.persistAssistant('final');
    turns[1].complete(AgentTurnSuccess(assistantMessage: assistant));
    await _flush();
    expect(controller.activeThread!.messages.where(_isUser), hasLength(1));
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));
  });

  test('cancel retains User and never promotes partial text to history',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness(cancelCompletes: true);
    final controller = _controller(repository, start: turn.start);

    await controller.send('cancel me');
    turn.emit(const AgentTurnTextDelta('partial'));
    await _flush();
    controller.cancelActiveTurn();
    await _flush();

    expect(turn.cancelled, isTrue);
    expect(repository.messages.where(_isUser), hasLength(1));
    expect(repository.messages.where(_isAssistant), isEmpty);
    expect(controller.activeThread!.messages.where(_isAssistant), isEmpty);
    expect(controller.transientAssistantText, 'partial');
    expect(controller.turnPhase, AssistantTurnPhase.cancelled);
  });

  test('already-completed result never duplicates persisted Assistant in UI',
      () async {
    final repository = _MemoryRepository();
    final turn = _TurnHarness();
    final controller = _controller(repository, start: turn.start);

    await controller.send('once');
    final assistant = repository.persistAssistant('done');
    turn.complete(AgentTurnAlreadyCompleted(assistantMessage: assistant));
    await _flush();
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));

    // The same terminal identity cannot produce a second bubble.
    expect(controller.activeThread!.messages.where(_isAssistant), hasLength(1));
  });

  test('unconfigured Agent blocks pre-persist send with a safe settings hint',
      () async {
    final repository = _MemoryRepository();
    var providerStarts = 0;
    final controller = _controller(
      repository,
      configured: false,
      start: ({required conversationId, required userMessageId}) {
        providerStarts++;
        return _TurnHarness().session;
      },
    );

    expect(await controller.send('do not persist'), isFalse);
    expect(repository.messages, isEmpty);
    expect(repository.conversation, isNull);
    expect(providerStarts, 0);
    expect(controller.turnFailure, AgentTurnFailure.agentUnconfigured);
    expect(controller.needsAgentSettings, isTrue);
    expect(controller.errorMessage, isNot(contains('Exception')));
  });

  test('typed deletion and unavailable-scope failures map to safe UX',
      () async {
    final repository = _MemoryRepository();
    final turns = <_TurnHarness>[];
    final controller = _controller(
      repository,
      start: ({required conversationId, required userMessageId}) {
        final turn = _TurnHarness();
        turns.add(turn);
        return turn.session;
      },
    );

    await controller.send('deleted');
    turns[0].complete(
      const AgentTurnFailed(AgentTurnFailure.conversationUnavailable),
    );
    await _flush();
    expect(controller.errorMessage, '对话已删除，回复未保存');

    await controller.retryLastTurn();
    turns[1].complete(
      const AgentTurnFailed(AgentTurnFailure.scopeUnavailable),
    );
    await _flush();
    expect(controller.errorMessage, '学习空间已删除，无法保存回复');
    expect(repository.messages.where(_isAssistant), isEmpty);
  });
}

ConversationController _controller(
  _MemoryRepository repository, {
  required AgentTurnStarter start,
  bool configured = true,
}) {
  final configStore = _ConfigStore(
    configured
        ? const AgentConfigCodec().encode(
            AgentConfig(
              providerKind: AgentProviderKind.deepSeekResponses,
              mainProfileId: 'profile-1',
            ),
          )
        : null,
  );
  return ConversationController(
    ConversationService(
      repository: repository,
      conversationIdFactory: () => 'conversation-1',
      messageIdFactory: repository.nextMessageId,
      clock: repository.tick,
    ),
    agentSettingsService: AgentSettingsService(
      configStore: configStore,
      profileCatalog: _Profiles(),
    ),
    startAgentTurn: start,
  );
}

bool _isUser(ConversationMessage message) =>
    message.role == ConversationMessageRole.user;
bool _isAssistant(ConversationMessage message) =>
    message.role == ConversationMessageRole.assistant;
Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _TurnHarness {
  _TurnHarness({this.cancelCompletes = false});

  final bool cancelCompletes;
  final StreamController<AgentTurnEvent> _events =
      StreamController<AgentTurnEvent>.broadcast();
  final Completer<AgentTurnResult> _result = Completer<AgentTurnResult>();
  bool cancelled = false;

  late final AgentTurnSession session = AgentTurnSession(
    events: _events.stream,
    result: _result.future,
    cancel: () {
      cancelled = true;
      if (cancelCompletes && !_result.isCompleted) {
        complete(const AgentTurnFailed(AgentTurnFailure.cancelled));
      }
    },
  );

  AgentTurnSession start({
    required String conversationId,
    required String userMessageId,
  }) =>
      session;

  void emit(AgentTurnEvent event) => _events.add(event);

  void complete(AgentTurnResult result) {
    if (_result.isCompleted) return;
    _result.complete(result);
    unawaited(_events.close());
  }
}

final class _ConfigStore implements AgentConfigStorePort {
  _ConfigStore(this.encoded);

  String? encoded;

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _Profiles implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async =>
      <AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'profile-1',
          displayName: 'Main',
          modelName: 'deepseek-v4-flash',
        ),
      ];
}

final class _MemoryRepository extends Fake
    implements ConversationRepositoryPort {
  Conversation? conversation;
  final List<ConversationMessage> messages = <ConversationMessage>[];
  var _messageCounter = 0;
  var _milliseconds = 1;

  String nextMessageId() => 'message-${++_messageCounter}';
  DateTime tick() =>
      DateTime.fromMillisecondsSinceEpoch(_milliseconds++, isUtc: true);

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    this.conversation = conversation;
    messages.add(firstMessage);
    return _slice();
  }

  @override
  Future<AppendMessageResult> appendMessage({
    required String conversationId,
    required String messageId,
    required ConversationMessageRole role,
    required String content,
    required DateTime createdAt,
  }) async {
    final current = conversation;
    if (current == null) {
      throw const ConversationException(
          ConversationFailure.conversationNotFound);
    }
    final message = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: messages.length + 1,
      role: role,
      content: content,
      createdAt: createdAt,
    );
    messages.add(message);
    conversation = current.withUpdatedAt(createdAt);
    return AppendMessageResult(conversation: conversation!, message: message);
  }

  ConversationMessage persistAssistant(String content) {
    final message = ConversationMessage(
      messageId: nextMessageId(),
      conversationId: conversation!.conversationId,
      sequence: messages.length + 1,
      role: ConversationMessageRole.assistant,
      content: content,
      createdAt: tick(),
    );
    messages.add(message);
    return message;
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async =>
      _slice();

  @override
  Future<List<Conversation>> listRecentConversations(
          {required int limit}) async =>
      conversation == null
          ? const <Conversation>[]
          : <Conversation>[conversation!];

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) async =>
      const <Conversation>[];

  @override
  Future<List<ConversationFileRef>> listAttachableFiles(
          {required int limit}) async =>
      const <ConversationFileRef>[];

  ConversationThreadSlice _slice() => ConversationThreadSlice(
        conversation: conversation!,
        messages: messages,
        files: const <ConversationFileRef>[],
        hasMoreBefore: false,
        nextBeforeSequence: null,
      );
}
