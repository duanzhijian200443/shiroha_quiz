import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_catalog.dart';
import 'package:shiroha_quiz/application/agent/agent_study_tool_dispatcher.dart';
import 'package:shiroha_quiz/application/agent/agent_turn.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/application/conversations/conversation_service.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';

typedef _Script = Stream<AgentProviderEvent> Function(
  AgentProviderRequest request,
  AgentCancellationToken token,
);

void main() {
  group('basic turn', () {
    test(
      'persists exactly one Assistant message for a simple answer',
      () async {
        final harness = _Harness(scripts: <_Script>[_finalAnswer('Hello')]);
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final session = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        final result = await session.result;

        expect(result, isA<AgentTurnSuccess>());
        final assistant = (result as AgentTurnSuccess).assistantMessage;
        expect(assistant.role, ConversationMessageRole.assistant);
        expect(assistant.content, 'Hello');
        expect(assistant.sequence, 2);
        final messages = await harness.messagesOf(conversationId);
        expect(
          messages.map((message) => message.role),
          <ConversationMessageRole>[
            ConversationMessageRole.user,
            ConversationMessageRole.assistant,
          ],
        );
        expect(messages.map((message) => message.content), <String>[
          'question',
          'Hello',
        ]);
        expect(harness.provider.callCount, 1);
        final request = harness.provider.requests.single;
        expect(request.messages.single.content, 'question');
        expect(request.messages.single.role, AgentProviderMessageRole.user);
        expect(request.systemPrompt, contains('You are Shiroha'));
        expect(
          request.tools.map((tool) => tool.name),
          AgentStudyToolCatalog.toolNames,
        );
        expect(request.enableNativeWebSearch, isFalse);
        expect(request.maxOutputTokens, 4096);
      },
    );

    test('streams transient deltas and persists one final message', () async {
      final harness = _Harness(
        scripts: <_Script>[
          _streamingAnswer(<String>['A', 'B']),
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );
      final session = harness.runtime.startTurn(
        conversationId: conversationId,
        userMessageId: userMessageId,
      );
      final events = <AgentTurnEvent>[];
      session.events.listen(events.add);

      final result = await session.result;

      expect(result, isA<AgentTurnSuccess>());
      expect((result as AgentTurnSuccess).assistantMessage.content, 'AB');
      expect(
        events.whereType<AgentTurnTextDelta>().map((event) => event.text),
        <String>['A', 'B'],
      );
      expect(events.whereType<AgentTurnCompleted>(), hasLength(1));
      final messages = await harness.messagesOf(conversationId);
      expect(
        messages.where(
          (message) => message.role == ConversationMessageRole.assistant,
        ),
        hasLength(1),
      );
      expect(messages.last.content, 'AB');
    });
  });

  group('tool loop', () {
    test(
      'executes one tool round and continues with cumulative continuation',
      () async {
        const state = _TestContinuationState('s1');
        final harness = _Harness(
          scripts: <_Script>[
            _toolRound(<AgentProviderFunctionCall>[_call('call-1')], state),
            _finalAnswer('answer'),
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        expect((result as AgentTurnSuccess).assistantMessage.content, 'answer');
        expect(harness.provider.callCount, 2);
        expect(harness.dispatcher.calls, <(String, String)>[
          ('list_question_banks', '{}'),
        ]);
        final continuationRequest = harness.provider.requests[1];
        expect(continuationRequest.continuationState, same(state));
        expect(continuationRequest.toolOutputs, hasLength(1));
        expect(continuationRequest.toolOutputs.single.callId, 'call-1');
        expect(
          continuationRequest.toolOutputs.single.output,
          harness.dispatcher.output,
        );
        // Persisted history is unchanged by tool activity: no tool trace.
        expect(
          continuationRequest.messages.map((message) => message.content),
          <String>['question'],
        );
      },
    );

    test('dispatches multiple calls in one round preserving order', () async {
      const state = _TestContinuationState('s1');
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(<AgentProviderFunctionCall>[
            _call('call-1', name: 'get_study_overview'),
            _call('call-2', name: 'search_questions'),
          ], state),
          _finalAnswer('done'),
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(result, isA<AgentTurnSuccess>());
      expect(harness.dispatcher.calls.map((call) => call.$1), <String>[
        'get_study_overview',
        'search_questions',
      ]);
      expect(
        harness.provider.requests[1].toolOutputs.map((output) => output.callId),
        <String>['call-1', 'call-2'],
      );
    });

    test(
      'supports multiple tool rounds with cumulative continuation',
      () async {
        const s1 = _TestContinuationState('s1');
        const s2 = _TestContinuationState('s2');
        final harness = _Harness(
          scripts: <_Script>[
            _toolRound(<AgentProviderFunctionCall>[_call('call-1')], s1),
            _toolRound(<AgentProviderFunctionCall>[_call('call-2')], s2),
            _finalAnswer('done'),
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        expect((result as AgentTurnSuccess).assistantMessage.content, 'done');
        expect(harness.provider.callCount, 3);
        expect(harness.provider.requests[1].continuationState, same(s1));
        expect(harness.provider.requests[2].continuationState, same(s2));
        expect(
          harness.provider.requests[2].toolOutputs.single.callId,
          'call-2',
        );
      },
    );

    test('fails when a fifth provider response requires local tools', () async {
      const state = _TestContinuationState('s');
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(<AgentProviderFunctionCall>[_call('call-1')], state),
          _toolRound(<AgentProviderFunctionCall>[_call('call-2')], state),
          _toolRound(<AgentProviderFunctionCall>[_call('call-3')], state),
          _toolRound(<AgentProviderFunctionCall>[_call('call-4')], state),
          _toolRound(<AgentProviderFunctionCall>[_call('call-5')], state),
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.toolLimitExceeded);
      expect(harness.provider.callCount, 5);
      expect(await harness.messagesOf(conversationId), hasLength(1));
    });

    test('fails when local calls exceed the per-turn bound', () async {
      final calls = List<AgentProviderFunctionCall>.generate(
        9,
        (index) => _call('call-${index + 1}'),
      );
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(calls, const _TestContinuationState('s')),
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.toolLimitExceeded);
      expect(harness.dispatcher.calls, isEmpty);
      expect(await harness.messagesOf(conversationId), hasLength(1));
    });

    test('fails safely on duplicate tool call ids', () async {
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(<AgentProviderFunctionCall>[
            _call('call-1'),
            _call('call-1'),
          ], const _TestContinuationState('s')),
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.providerMalformed);
      expect(harness.dispatcher.calls, isEmpty);
    });

    test('returns tool failures as safe structured provider inputs', () async {
      const state = _TestContinuationState('s');
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(<AgentProviderFunctionCall>[_call('call-1')], state),
          _finalAnswer('answer'),
        ],
      );
      harness.dispatcher.output =
          '{"ok":false,"error":{"code":"temporarily_unavailable",'
          '"message":"unavailable","retryable":true}}';
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(result, isA<AgentTurnSuccess>());
      expect(
        harness.provider.requests[1].toolOutputs.single.output,
        contains('temporarily_unavailable'),
      );
    });

    test('dispatcher crashes become safe outputs without leakage', () async {
      const state = _TestContinuationState('s');
      final harness = _Harness(
        scripts: <_Script>[
          _toolRound(<AgentProviderFunctionCall>[_call('call-1')], state),
          _finalAnswer('answer'),
        ],
      );
      harness.dispatcher.throwable = StateError('private-marker');
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(result, isA<AgentTurnSuccess>());
      final output = harness.provider.requests[1].toolOutputs.single.output;
      expect(output, contains('internal_error'));
      expect(output, isNot(contains('private-marker')));
    });
  });

  group('web and capabilities', () {
    test('forwards native web lifecycle events', () async {
      final harness = _Harness(
        webEnabled: true,
        scripts: <_Script>[
          (request, token) async* {
            yield const AgentProviderWebSearchEvent(
              AgentProviderWebSearchPhase.searching,
            );
            yield const AgentProviderWebSearchEvent(
              AgentProviderWebSearchPhase.completed,
            );
            yield AgentProviderTextDelta('found');
            yield AgentProviderCompleted('response-final');
          },
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );
      final session = harness.runtime.startTurn(
        conversationId: conversationId,
        userMessageId: userMessageId,
      );
      final events = <AgentTurnEvent>[];
      session.events.listen(events.add);

      final result = await session.result;

      expect(result, isA<AgentTurnSuccess>());
      expect(harness.provider.requests.single.enableNativeWebSearch, isTrue);
      expect(
        events.whereType<AgentTurnWebSearchEvent>().map((event) => event.phase),
        <AgentProviderWebSearchPhase>[
          AgentProviderWebSearchPhase.searching,
          AgentProviderWebSearchPhase.completed,
        ],
      );
    });

    test(
      'fails typed when web is enabled but the provider lacks native Web',
      () async {
        final harness = _Harness(
          webEnabled: true,
          capabilities: const AgentProviderCapabilities(
            functionTools: true,
            nativeWebSearch: false,
          ),
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.unsupportedCapability);
        expect(harness.provider.callCount, 0);
      },
    );

    test('fails typed when the provider lacks function tools', () async {
      final harness = _Harness(
        capabilities: const AgentProviderCapabilities(
          functionTools: false,
          nativeWebSearch: true,
        ),
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.unsupportedCapability);
      expect(harness.provider.callCount, 0);
    });

    test(
      'forwards AgentConfig tuning independently from parsing config',
      () async {
        final harness = _Harness(
          webEnabled: true,
          temperature: 0.7,
          reasoningEffort: AgentReasoningEffort.max,
          scripts: <_Script>[_finalAnswer('ok')],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        final request = harness.provider.requests.single;
        expect(request.enableNativeWebSearch, isTrue);
        expect(request.temperature, 0.7);
        expect(request.reasoningEffort, AgentReasoningEffort.max);
      },
    );
  });

  group('config failures', () {
    test('maps missing agent config to a typed failure', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      harness.configStore.encoded = null;
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.agentUnconfigured);
      expect(harness.provider.callCount, 0);
    });

    test('maps missing provider profile to a typed failure', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      harness.profileResolver.profile = null;
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.profileUnavailable);
      expect(harness.provider.callCount, 0);
    });
  });

  group('history', () {
    test(
      'sends bounded chronological history and preserves the target',
      () async {
        final harness = _Harness(scripts: <_Script>[_finalAnswer('ok')]);
        final contents = List<String>.generate(
          45,
          (index) => 'question ${index + 1}',
        );
        final (conversationId, userMessageId) = await harness.seedThread(
          contents,
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        final request = harness.provider.requests.single;
        expect(request.messages, hasLength(40));
        expect(request.messages.first.content, 'question 6');
        expect(request.messages.last.content, 'question 45');
      },
    );

    test('drops older history beyond the UTF-8 byte bound', () async {
      final harness = _Harness(
        limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 200),
        scripts: <_Script>[_finalAnswer('ok')],
      );
      final contents = List<String>.generate(5, (index) => '你' * 40);
      final (conversationId, userMessageId) = await harness.seedThread(
        contents,
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(result, isA<AgentTurnSuccess>());
      final request = harness.provider.requests.single;
      expect(request.messages, hasLength(1));
      expect(request.messages.single.content, '你' * 40);
    });

    test('fails typed when the target alone exceeds the byte bound', () async {
      final harness = _Harness(
        limits: const AgentRuntimeLimits(maxHistoryUtf8Bytes: 60),
        scripts: <_Script>[_finalAnswer('ok')],
      );
      final (conversationId, userMessageId) = await harness.seedUser('你' * 30);

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.historyLimitExceeded);
      expect(harness.provider.callCount, 0);
    });
  });

  group('cancellation and timeout', () {
    test(
      'cancellation propagates, keeps the user message, persists nothing',
      () async {
        final deltaYielded = Completer<void>();
        final harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              yield AgentProviderTextDelta('partial');
              deltaYielded.complete();
              await token.whenCancelled;
              throw const AgentProviderException(
                AgentProviderFailure.cancelled,
              );
            },
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );
        final session = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        final events = <AgentTurnEvent>[];
        session.events.listen(events.add);

        await deltaYielded.future;
        session.cancel();
        final result = await session.result;

        expect(_failureOf(result), AgentTurnFailure.cancelled);
        expect(
          events.whereType<AgentTurnTextDelta>().map((event) => event.text),
          <String>['partial'],
        );
        final messages = await harness.messagesOf(conversationId);
        expect(messages, hasLength(1));
        expect(messages.single.role, ConversationMessageRole.user);
        expect(harness.provider.lastToken!.isCancelled, isTrue);
      },
    );

    test('overall timeout fails the turn and persists nothing', () async {
      final harness = _Harness(
        limits: const AgentRuntimeLimits(
          turnTimeout: Duration(milliseconds: 80),
        ),
        scripts: <_Script>[
          (request, token) async* {
            await token.whenCancelled;
            throw const AgentProviderException(AgentProviderFailure.cancelled);
          },
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.timeout);
      expect(harness.provider.lastToken!.isCancelled, isTrue);
      expect(await harness.messagesOf(conversationId), hasLength(1));
    });
  });

  group('one in-flight turn', () {
    test(
      'second concurrent turn on the same conversation is alreadyRunning',
      () async {
        final gate = Completer<void>();
        final harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              await gate.future;
              yield AgentProviderTextDelta('first');
              yield AgentProviderCompleted('response-first');
            },
            _finalAnswer('second'),
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );
        final first = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        final second = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        expect(harness.provider.callCount, 0);

        final secondResult = await second.result;
        expect(_failureOf(secondResult), AgentTurnFailure.alreadyRunning);

        gate.complete();
        expect(await first.result, isA<AgentTurnSuccess>());

        // The in-flight lock was released: a new user turn may run again.
        await harness.appendUser(conversationId, 'question 2');
        final slice = await harness.conversationService.loadConversation(
          conversationId: conversationId,
          limit: 100,
        );
        final third = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: slice.messages.last.messageId,
        );
        expect(await third.result, isA<AgentTurnSuccess>());
      },
    );

    test('different conversations may run independently', () async {
      final gate = Completer<void>();
      final harness = _Harness(
        scripts: <_Script>[
          (request, token) async* {
            await gate.future;
            yield AgentProviderTextDelta('slow');
            yield AgentProviderCompleted('response-slow');
          },
          _finalAnswer('fast'),
        ],
      );
      final (firstId, firstTarget) = await harness.seedUser('first');
      final (secondId, secondTarget) = await harness.seedUser('second');
      final slow = harness.runtime.startTurn(
        conversationId: firstId,
        userMessageId: firstTarget,
      );
      final fast = harness.runtime.startTurn(
        conversationId: secondId,
        userMessageId: secondTarget,
      );

      expect(await fast.result, isA<AgentTurnSuccess>());
      gate.complete();
      expect(await slow.result, isA<AgentTurnSuccess>());
      expect((await harness.messagesOf(secondId)).last.content, 'fast');
    });
  });

  group('failure windows and retry', () {
    test(
      'provider failure preserves the user message and retry regenerates',
      () async {
        final harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              throw const AgentProviderException(
                AgentProviderFailure.temporarilyUnavailable,
              );
            },
            _finalAnswer('retry answer'),
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final first = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        expect(
          _failureOf(await first.result),
          AgentTurnFailure.temporarilyUnavailable,
        );
        expect(await harness.messagesOf(conversationId), hasLength(1));

        final second = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        expect(await second.result, isA<AgentTurnSuccess>());
        final messages = await harness.messagesOf(conversationId);
        expect(messages.map((message) => message.content), <String>[
          'question',
          'retry answer',
        ]);
        expect(
          messages.where(
            (message) => message.role == ConversationMessageRole.user,
          ),
          hasLength(1),
        );
        expect(harness.provider.callCount, 2);
      },
    );

    test(
      'tool continuation failure preserves the user message (window C)',
      () async {
        const state = _TestContinuationState('s');
        final harness = _Harness(
          scripts: <_Script>[
            _toolRound(<AgentProviderFunctionCall>[_call('call-1')], state),
            (request, token) async* {
              throw const AgentProviderException(
                AgentProviderFailure.temporarilyUnavailable,
              );
            },
          ],
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.temporarilyUnavailable);
        expect(harness.dispatcher.calls, hasLength(1));
        expect(await harness.messagesOf(conversationId), hasLength(1));
      },
    );

    test(
      'ambiguous append failure with the row present is treated as success',
      () async {
        final harness = _Harness(scripts: <_Script>[_finalAnswer('answer')]);
        harness.repository.appendOutcomes.add(
          const _AppendOutcome(
            failure: ConversationFailure.temporarilyUnavailable,
            persistRow: true,
          ),
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        expect(harness.repository.appendCalls, 1);
        expect(harness.provider.callCount, 1);
        expect(
          (await harness.messagesOf(
            conversationId,
          ))
              .map((message) => message.content),
          <String>['question', 'answer'],
        );
      },
    );

    test(
      'confirmed-absent append failure retries the same final text',
      () async {
        final harness = _Harness(scripts: <_Script>[_finalAnswer('answer')]);
        harness.repository.appendOutcomes.add(
          const _AppendOutcome(
            failure: ConversationFailure.temporarilyUnavailable,
            persistRow: false,
          ),
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(result, isA<AgentTurnSuccess>());
        expect(harness.repository.appendCalls, 2);
        expect(harness.provider.callCount, 1);
        expect(
          (await harness.messagesOf(
            conversationId,
          ))
              .map((message) => message.content),
          <String>['question', 'answer'],
        );
      },
    );

    test(
      'unconfirmable storage state keeps a typed persistence failure',
      () async {
        late _Harness harness;
        harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              harness.repository.loadFailure =
                  ConversationFailure.temporarilyUnavailable;
              yield AgentProviderTextDelta('answer');
              yield AgentProviderCompleted('response-final');
            },
          ],
        );
        harness.repository.appendOutcomes.add(
          const _AppendOutcome(
            failure: ConversationFailure.temporarilyUnavailable,
            persistRow: false,
          ),
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.persistenceFailed);
        expect(harness.provider.callCount, 1);
        expect(await harness.messagesOf(conversationId), hasLength(1));
      },
    );

    test(
      'persistence retry reuses generated text without provider rerun',
      () async {
        late _Harness harness;
        harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              harness.repository.loadFailure =
                  ConversationFailure.temporarilyUnavailable;
              yield AgentProviderTextDelta('answer');
              yield AgentProviderCompleted('response-final');
            },
          ],
        );
        harness.repository.appendOutcomes.add(
          const _AppendOutcome(
            failure: ConversationFailure.temporarilyUnavailable,
            persistRow: false,
          ),
        );
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );

        final first = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        expect(
          _failureOf(await first.result),
          AgentTurnFailure.persistenceFailed,
        );
        expect(harness.provider.callCount, 1);

        harness.repository.appendOutcomes.add(const _AppendOutcome());
        final second = harness.runtime.startTurn(
          conversationId: conversationId,
          userMessageId: userMessageId,
        );
        expect(await second.result, isA<AgentTurnSuccess>());
        expect(harness.provider.callCount, 1);
        expect(
          (await harness.messagesOf(
            conversationId,
          ))
              .map((message) => message.content),
          <String>['question', 'answer'],
        );
      },
    );

    test(
      'conversation deleted mid-turn fails safely without recreation',
      () async {
        var conversationId = '';
        late _Harness harness;
        harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              harness.repository.deleteConversation(conversationId);
              yield AgentProviderTextDelta('answer');
              yield AgentProviderCompleted('response-final');
            },
          ],
        );
        final (seededId, userMessageId) = await harness.seedUser('question');
        conversationId = seededId;
        final createCallsBefore = harness.repository.createCalls;

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.conversationUnavailable);
        expect(harness.repository.deleteCalls, 1);
        expect(harness.repository.createCalls, createCallsBefore);
      },
    );

    test(
      'learning space unavailable mid-turn fails with scopeUnavailable',
      () async {
        var conversationId = '';
        late _Harness harness;
        harness = _Harness(
          scripts: <_Script>[
            (request, token) async* {
              harness.repository.setScopeUnavailable(conversationId);
              yield AgentProviderTextDelta('answer');
              yield AgentProviderCompleted('response-final');
            },
          ],
        );
        final (seededId, userMessageId) = await harness.seedUser(
          'question',
          scope: ConversationScope.learningSpace('project-a'),
        );
        conversationId = seededId;

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.scopeUnavailable);
        expect(await harness.messagesOf(conversationId), hasLength(1));
      },
    );

    test('already-completed target never regenerates', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('new')]);
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );
      await harness.appendAssistant(conversationId, 'existing');

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(result, isA<AgentTurnAlreadyCompleted>());
      expect(
        (result as AgentTurnAlreadyCompleted).assistantMessage.content,
        'existing',
      );
      expect(harness.provider.callCount, 0);
    });
  });

  group('target validation', () {
    test(
      'unavailable scope at turn start fails without a provider call',
      () async {
        final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
        final (conversationId, userMessageId) = await harness.seedUser(
          'question',
        );
        harness.repository.setScopeUnavailable(conversationId);

        final result = await harness.runtime
            .startTurn(
              conversationId: conversationId,
              userMessageId: userMessageId,
            )
            .result;

        expect(_failureOf(result), AgentTurnFailure.scopeUnavailable);
        expect(harness.provider.callCount, 0);
      },
    );

    test('rejects an Assistant message id as the turn target', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );
      await harness.appendAssistant(conversationId, 'existing');
      final assistantId = (await harness.messagesOf(
        conversationId,
      ))
          .last
          .messageId;

      final result = await harness.runtime
          .startTurn(conversationId: conversationId, userMessageId: assistantId)
          .result;

      expect(_failureOf(result), AgentTurnFailure.invalidTarget);
      expect(harness.provider.callCount, 0);
    });

    test('rejects a target that is not the latest user turn', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      final (conversationId, userMessageId) = await harness.seedUser('first');
      await harness.appendUser(conversationId, 'second');

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.invalidTarget);
      expect(harness.provider.callCount, 0);
    });

    test('missing target message is invalidTarget', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      final (conversationId, _) = await harness.seedUser('question');

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: 'missing-message',
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.invalidTarget);
    });

    test('invalid identifiers fail typed before any work', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      final session = harness.runtime.startTurn(
        conversationId: '',
        userMessageId: 'message-1',
      );

      expect(_failureOf(await session.result), AgentTurnFailure.invalidTarget);
      expect(harness.repository.loadCalls, 0);
    });

    test('missing conversation is a typed failure', () async {
      final harness = _Harness(scripts: <_Script>[_finalAnswer('x')]);
      final session = harness.runtime.startTurn(
        conversationId: 'missing-conversation',
        userMessageId: 'message-1',
      );

      expect(
        _failureOf(await session.result),
        AgentTurnFailure.conversationUnavailable,
      );
    });
  });

  group('provider malformed responses', () {
    test('empty final visible text fails typed without persistence', () async {
      final harness = _Harness(
        scripts: <_Script>[
          (request, token) async* {
            yield AgentProviderCompleted('response-empty');
          },
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.providerMalformed);
      expect(await harness.messagesOf(conversationId), hasLength(1));
    });

    test('provider round without a completed event is malformed', () async {
      final harness = _Harness(
        scripts: <_Script>[
          (request, token) async* {
            yield AgentProviderTextDelta('partial');
          },
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.providerMalformed);
      expect(await harness.messagesOf(conversationId), hasLength(1));
    });

    test('tool round without continuation state is malformed', () async {
      final harness = _Harness(
        scripts: <_Script>[
          (request, token) async* {
            yield _call('call-1');
            yield AgentProviderCompleted('response-tool');
          },
        ],
      );
      final (conversationId, userMessageId) = await harness.seedUser(
        'question',
      );

      final result = await harness.runtime
          .startTurn(
            conversationId: conversationId,
            userMessageId: userMessageId,
          )
          .result;

      expect(_failureOf(result), AgentTurnFailure.providerMalformed);
      expect(harness.dispatcher.calls, isEmpty);
    });
  });
}

final class _Harness {
  _Harness({
    List<_Script> scripts = const <_Script>[],
    AgentProviderCapabilities? capabilities,
    AgentRuntimeLimits? limits,
    bool webEnabled = false,
    double temperature = 1.0,
    AgentReasoningEffort reasoningEffort = AgentReasoningEffort.high,
  })  : repository = _FakeConversationRepository(),
        configStore = _FakeConfigStore(
          encoded: AgentConfigCodec().encode(
            AgentConfig(
              providerKind: AgentProviderKind.deepSeekResponses,
              mainProfileId: 'profile-a',
              webEnabled: webEnabled,
              temperature: temperature,
              reasoningEffort: reasoningEffort,
            ),
          ),
        ),
        profileResolver = _FakeProfileResolver() {
    conversationService = ConversationService(
      repository: repository,
      conversationIdFactory: () => 'conversation-${++_conversationSequence}',
      messageIdFactory: () => 'message-${++_messageSequence}',
      clock: () => DateTime.utc(2026, 8, 10, 12),
    );
    provider = _ScriptedProvider(
      scripts,
      capabilities: capabilities ??
          const AgentProviderCapabilities(
            functionTools: true,
            nativeWebSearch: true,
          ),
    );
    dispatcher = _FakeDispatcher();
    runtime = ShirohaAgentRuntime(
      conversationService: conversationService,
      configResolver: AgentRuntimeConfigResolver(
        configStore: configStore,
        profileResolver: profileResolver,
      ),
      providerFactory: (_) => provider,
      toolDispatcher: dispatcher,
      limits: limits ?? const AgentRuntimeLimits(),
    );
  }

  final _FakeConversationRepository repository;
  final _FakeConfigStore configStore;
  final _FakeProfileResolver profileResolver;
  late final ConversationService conversationService;
  late final _ScriptedProvider provider;
  late final _FakeDispatcher dispatcher;
  late final ShirohaAgentRuntime runtime;
  var _conversationSequence = 0;
  var _messageSequence = 0;

  Future<(String, String)> seedUser(
    String content, {
    ConversationScope? scope,
  }) async {
    final result = await conversationService.startWithUserMessage(
      scope: scope ?? ConversationScope.global(),
      content: content,
    );
    return (
      result.conversation.conversationId,
      result.messages.single.messageId,
    );
  }

  Future<(String, String)> seedThread(
    List<String> contents, {
    ConversationScope? scope,
  }) async {
    final (conversationId, _) = await seedUser(contents.first, scope: scope);
    for (final content in contents.skip(1)) {
      await appendUser(conversationId, content);
    }
    final slice = await conversationService.loadConversation(
      conversationId: conversationId,
      limit: 100,
    );
    return (conversationId, slice.messages.last.messageId);
  }

  Future<void> appendUser(String conversationId, String content) async {
    await conversationService.appendUserMessage(
      conversationId: conversationId,
      content: content,
    );
  }

  Future<void> appendAssistant(String conversationId, String content) async {
    await conversationService.appendAssistantMessage(
      conversationId: conversationId,
      content: content,
    );
  }

  Future<List<ConversationMessage>> messagesOf(String conversationId) async {
    final slice = await conversationService.loadConversation(
      conversationId: conversationId,
      limit: 100,
    );
    return slice.messages;
  }
}

final class _FakeConfigStore implements AgentConfigStorePort {
  _FakeConfigStore({this.encoded});

  String? encoded;

  @override
  Future<String?> readAgentConfig() async => encoded;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _FakeProfileResolver implements AgentProviderProfileResolverPort {
  AgentProviderProfile? profile = AgentProviderProfile(
    profileId: 'profile-a',
    apiKey: 'test-key',
    baseUrl: 'https://example.test/v1',
    modelName: 'deepseek-v4-flash',
  );

  @override
  Future<AgentProviderProfile?> resolveMainProfile(String profileId) async {
    return profile;
  }
}

final class _AppendOutcome {
  const _AppendOutcome({this.failure, this.persistRow = true});

  final ConversationFailure? failure;
  final bool persistRow;
}

final class _FakeConversationRepository implements ConversationRepositoryPort {
  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<ConversationMessage>> _messagesByConversation =
      <String, List<ConversationMessage>>{};
  final List<_AppendOutcome> appendOutcomes = <_AppendOutcome>[];
  ConversationFailure? loadFailure;
  int appendCalls = 0;
  int createCalls = 0;
  int deleteCalls = 0;
  int loadCalls = 0;

  @override
  Future<ConversationThreadSlice> createWithFirstMessage({
    required Conversation conversation,
    required ConversationMessage firstMessage,
    required List<String> fileIds,
    required DateTime attachedAt,
  }) async {
    createCalls++;
    _conversations[conversation.conversationId] = conversation;
    _messagesByConversation[conversation.conversationId] =
        <ConversationMessage>[firstMessage];
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
    appendCalls++;
    final current = _conversations[conversationId];
    if (current == null) {
      throw const ConversationException(
        ConversationFailure.conversationNotFound,
      );
    }
    if (current.scope.isUnavailableLearningSpace) {
      throw const ConversationException(ConversationFailure.scopeUnavailable);
    }
    final outcome = appendOutcomes.isEmpty
        ? const _AppendOutcome()
        : appendOutcomes.removeAt(0);
    final messages = _messagesByConversation[conversationId]!;
    final sequence = messages.isEmpty ? 1 : messages.last.sequence + 1;
    final message = ConversationMessage(
      messageId: messageId,
      conversationId: conversationId,
      sequence: sequence,
      role: role,
      content: content,
      createdAt: createdAt,
    );
    if (outcome.failure != null) {
      if (outcome.persistRow) messages.add(message);
      throw ConversationException(outcome.failure!);
    }
    messages.add(message);
    return AppendMessageResult(conversation: current, message: message);
  }

  @override
  Future<ConversationThreadSlice> loadConversation({
    required String conversationId,
    required int limit,
    int? beforeSequence,
  }) async {
    loadCalls++;
    final failure = loadFailure;
    if (failure != null) {
      loadFailure = null;
      throw ConversationException(failure);
    }
    final current = _conversations[conversationId];
    if (current == null) {
      throw const ConversationException(
        ConversationFailure.conversationNotFound,
      );
    }
    var messages = _messagesByConversation[conversationId]!;
    if (beforeSequence != null) {
      messages = messages
          .where((message) => message.sequence < beforeSequence)
          .toList();
    }
    final hasMoreBefore = messages.length > limit;
    final selected = messages.length <= limit
        ? messages
        : messages.sublist(messages.length - limit);
    return ConversationThreadSlice(
      conversation: current,
      messages: List<ConversationMessage>.unmodifiable(selected),
      files: const <ConversationFileRef>[],
      hasMoreBefore: hasMoreBefore,
      nextBeforeSequence: hasMoreBefore ? selected.first.sequence : null,
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    deleteCalls++;
    _conversations.remove(conversationId);
    _messagesByConversation.remove(conversationId);
  }

  void setScopeUnavailable(String conversationId) {
    final current = _conversations[conversationId]!;
    _conversations[conversationId] = Conversation(
      conversationId: current.conversationId,
      scope: ConversationScope.unavailableLearningSpace(),
      title: current.title,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
    );
  }

  @override
  Future<AppendFileResult> attachFile({
    required String conversationId,
    required String fileId,
    required DateTime attachedAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DetachFileResult> detachFile({
    required String conversationId,
    required String fileId,
    required DateTime detachedAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<ConversationFileRef>> listAttachableFiles({
    required int limit,
  }) async {
    return const <ConversationFileRef>[];
  }

  @override
  Future<List<Conversation>> listRecentConversations({
    required int limit,
  }) async {
    return _conversations.values.toList(growable: false);
  }

  @override
  Future<List<Conversation>> listConversationsForProject({
    required String projectId,
    required int limit,
  }) async {
    return _conversations.values
        .where((conversation) => conversation.scope.projectId == projectId)
        .toList(growable: false);
  }
}

final class _ScriptedProvider implements AgentProviderPort {
  _ScriptedProvider(this._scripts, {required this.capabilities});

  final List<_Script> _scripts;

  @override
  final AgentProviderCapabilities capabilities;

  int callCount = 0;
  final List<AgentProviderRequest> requests = <AgentProviderRequest>[];
  AgentCancellationToken? lastToken;

  @override
  Stream<AgentProviderEvent> stream(
    AgentProviderRequest request,
    AgentCancellationToken cancellationToken,
  ) {
    requests.add(request);
    lastToken = cancellationToken;
    final index = callCount++;
    if (index >= _scripts.length) {
      throw const AgentProviderException(AgentProviderFailure.internalError);
    }
    return _scripts[index](request, cancellationToken);
  }
}

final class _FakeDispatcher implements AgentStudyToolDispatcher {
  final List<(String, String)> calls = <(String, String)>[];
  String output = '{"ok":true,"result":{"value":1}}';
  Object? throwable;

  @override
  Future<String> dispatch(String toolName, String argumentsJson) async {
    calls.add((toolName, argumentsJson));
    final error = throwable;
    if (error != null) throw error;
    return output;
  }
}

final class _TestContinuationState implements AgentProviderContinuationState {
  const _TestContinuationState(this.label);

  final String label;
}

_Script _finalAnswer(String text) {
  return (request, token) async* {
    yield AgentProviderTextDelta(text);
    yield AgentProviderCompleted('response-final');
  };
}

_Script _streamingAnswer(List<String> deltas) {
  return (request, token) async* {
    for (final delta in deltas) {
      yield AgentProviderTextDelta(delta);
    }
    yield AgentProviderCompleted('response-final');
  };
}

_Script _toolRound(
  List<AgentProviderFunctionCall> calls,
  AgentProviderContinuationState state,
) {
  return (request, token) async* {
    for (final call in calls) {
      yield call;
    }
    yield AgentProviderCompleted('response-tool', continuationState: state);
  };
}

AgentProviderFunctionCall _call(
  String callId, {
  String name = 'list_question_banks',
  String arguments = '{}',
}) {
  return AgentProviderFunctionCall(
    callId: callId,
    name: name,
    argumentsJson: arguments,
  );
}

AgentTurnFailure _failureOf(AgentTurnResult result) {
  return switch (result) {
    AgentTurnFailed(:final failure) => failure,
    _ => fail('expected AgentTurnFailed, got $result'),
  };
}
