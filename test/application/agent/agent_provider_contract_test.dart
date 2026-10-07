import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/provider_round.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';

void main() {
  group('AR-R1 round settlement', () {
    late _RoundSink sink;
    setUp(() {
      sink = _RoundSink();
      LogWriter.setSink(sink);
    });
    tearDown(() => LogWriter.setSink(null));

    final call = AgentProviderFunctionCall(
        callId: 'c1',
        name: 'search_questions',
        argumentsJson: '{"query":"tool-secret"}');
    for (final entry in <(
      List<AgentProviderEvent>,
      AgentProviderException?,
      ProviderRoundOutcome,
      bool
    )>[
      (
        [AgentProviderTextDelta('private-marker'), AgentProviderCompleted('r')],
        null,
        ProviderRoundOutcome.completed,
        true
      ),
      (
        [call, AgentProviderCompleted('r')],
        null,
        ProviderRoundOutcome.toolCallsRequested,
        true
      ),
      (
        [call],
        const AgentProviderException.detailed(
            ProviderFailureCode.maxOutputTokens,
            terminalSeen: true),
        ProviderRoundOutcome.incomplete,
        true
      ),
      (
        [AgentProviderTextDelta('private-marker')],
        const AgentProviderException.detailed(
            ProviderFailureCode.incompleteUnknown,
            terminalSeen: true),
        ProviderRoundOutcome.incomplete,
        true
      ),
      (
        [call],
        const AgentProviderException.detailed(
            ProviderFailureCode.authentication,
            terminalSeen: true),
        ProviderRoundOutcome.failed,
        true
      ),
      (
        [call],
        const AgentProviderException.detailed(
            ProviderFailureCode.connectionLost),
        ProviderRoundOutcome.failed,
        false
      ),
      (
        [call],
        const AgentProviderException(AgentProviderFailure.cancelled),
        ProviderRoundOutcome.cancelled,
        false
      ),
      ([call], null, ProviderRoundOutcome.failed, false),
      (
        [call, AgentProviderCompleted('r'), AgentProviderCompleted('r2')],
        null,
        ProviderRoundOutcome.failed,
        true
      ),
    ]) {
      test(
          '${entry.$3.name} ${entry.$2?.safeCode?.code} events=${entry.$1.length}',
          () async {
        final provider = _RoundProvider(() async* {
          yield* Stream.fromIterable(entry.$1);
          if (entry.$2 case final failure?) throw failure;
        });
        final result = await TraceContext.runRoot(
            operationKind: TraceOperationKind.agentTurn,
            action: () => _normalize(provider));
        expect(result.outcome, entry.$3);
        final executable = entry.$3 == ProviderRoundOutcome.toolCallsRequested;
        expect(result.functionCalls, executable ? hasLength(1) : isEmpty);
        final terminal = _terminal(sink);
        expect(terminal.data['terminalSeen'], entry.$4);
        expect(terminal.data['outcome'], entry.$3.name);
        expect(sink.records.map((r) => r.traceId).toSet(), hasLength(1));
        expect(sink.records.map((r) => r.correlationId).toSet(), hasLength(1));
        for (final marker in [
          'private-marker',
          'secret prompt',
          'tool-secret',
          'reasoning-secret',
          'unsafe exception text'
        ]) {
          expect(jsonEncode(sink.records.map((r) => r.toJson()).toList()),
              isNot(contains(marker)));
        }
      });
    }

    test('untyped adapter throw retains no-fallback bridge', () async {
      final result = await _normalize(
          _RoundProvider(() => throw StateError('unsafe exception text')));
      expect(
          result.failure!.safeCode, ProviderFailureCode.adapterInternalError);
      expect(result.failure!.legacyFallbackAllowed, isFalse);
      _terminal(sink);
      expect(jsonEncode(sink.records.map((r) => r.toJson()).toList()),
          isNot(contains('unsafe exception text')));
    });

    test('untyped timeout retains timeout mapping without new fallback',
        () async {
      final result = await _normalize(_RoundProvider(
          () => Stream.error(TimeoutException('unsafe exception text'))));
      expect(result.failure!.safeCode, ProviderFailureCode.streamTimeout);
      expect(result.failure!.failure, AgentProviderFailure.timeout);
      expect(result.failure!.legacyFallbackAllowed, isFalse);
      _terminal(sink);
    });

    for (final terminalFirst in [false, true]) {
      test('terminal/cancel order terminalFirst=$terminalFirst', () async {
        final cancellation = AgentCancellationController();
        final source = StreamController<AgentProviderEvent>(sync: true);
        final future = _normalize(_RoundProvider(() => source.stream),
            cancellation: cancellation);
        if (terminalFirst) source.add(AgentProviderCompleted('r'));
        cancellation.cancel();
        if (!terminalFirst) source.add(AgentProviderCompleted('r'));
        final result = await future;
        expect(result.outcome, ProviderRoundOutcome.cancelled);
        final terminal = _terminal(sink);
        expect(terminal.data['terminalSeen'], terminalFirst);
        await source.close();
        _terminal(sink);
      });
    }

    for (final terminalFirst in [false, true]) {
      test('terminal/deadline order terminalFirst=$terminalFirst', () async {
        final source = StreamController<AgentProviderEvent>(sync: true);
        late _ControlledTimer deadline;
        final future = runZoned(
          () => _normalize(_RoundProvider(() => source.stream),
              budget: const Duration(seconds: 1)),
          zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
            expect(duration, const Duration(seconds: 1));
            deadline = _ControlledTimer(callback);
            return deadline;
          }),
        );
        if (terminalFirst) source.add(AgentProviderCompleted('r'));
        deadline.fire();
        final result = await future;
        expect(result.outcome, ProviderRoundOutcome.failed);
        expect(result.failure!.safeCode, ProviderFailureCode.streamTimeout);
        expect(result.failure!.failure, AgentProviderFailure.timeout);
        expect(_terminal(sink).data['terminalSeen'], terminalFirst);
        if (!terminalFirst) source.add(AgentProviderCompleted('r'));
        await source.close();
        _terminal(sink);
      });
    }

    test('completed stream wins before later cancellation', () async {
      final cancellation = AgentCancellationController();
      final result = await _normalize(
          _RoundProvider(() => Stream.value(AgentProviderCompleted('r'))),
          cancellation: cancellation);
      cancellation.cancel();
      expect(result.outcome, ProviderRoundOutcome.completed);
      await cancellation.token.whenCancelled;
      _terminal(sink);
    });
  });
  test('provider request freezes the minimum Responses continuation contract',
      () {
    final messages = <AgentProviderMessage>[
      AgentProviderMessage(
        role: AgentProviderMessageRole.user,
        content: 'question',
      ),
    ];
    final tools = <AgentFunctionToolDefinition>[
      AgentFunctionToolDefinition(
        name: 'get_study_overview',
        description: 'Read study overview.',
        inputSchema: <String, Object?>{'type': 'object'},
      ),
    ];
    final output = AgentFunctionToolOutput(
      callId: 'call-1',
      output: '{"ok":true}',
    );
    final continuationState = _FixtureContinuationState();
    final request = AgentProviderRequest(
      systemPrompt: 'You are Shiroha.',
      messages: messages,
      tools: tools,
      toolOutputs: <AgentFunctionToolOutput>[output],
      continuationState: continuationState,
      enableNativeWebSearch: true,
      temperature: 0.75,
      reasoningEffort: AgentReasoningEffort.max,
    );

    messages.clear();
    tools.clear();

    expect(request.messages, hasLength(1));
    expect(request.tools, hasLength(1));
    expect(request.toolOutputs, <AgentFunctionToolOutput>[output]);
    expect(request.continuationState, same(continuationState));
    expect(request.enableNativeWebSearch, isTrue);
    expect(request.maxOutputTokens, 4096);
    expect(request.temperature, 0.75);
    expect(request.reasoningEffort, AgentReasoningEffort.max);

    expect(
      () => AgentProviderRequest(
        systemPrompt: 'You are Shiroha.',
        messages: request.messages,
        toolOutputs: <AgentFunctionToolOutput>[output],
        temperature: 1.0,
        reasoningEffort: AgentReasoningEffort.high,
      ),
      throwsA(isA<AgentProviderException>()),
    );
  });

  test('provider events expose visible protocol state but no reasoning event',
      () {
    final events = <AgentProviderEvent>[
      AgentProviderTextDelta('answer'),
      AgentProviderFunctionCall(
        callId: 'call-1',
        name: 'search_questions',
        argumentsJson: '{"query":"fixture"}',
      ),
      const AgentProviderWebSearchEvent(
        AgentProviderWebSearchPhase.searching,
      ),
      AgentProviderCompleted(
        'response-1',
        continuationState: _FixtureContinuationState(),
      ),
    ];

    expect(events.whereType<AgentProviderTextDelta>().single.text, 'answer');
    expect(
      events.whereType<AgentProviderFunctionCall>().single.name,
      'search_questions',
    );
    expect(
      events.whereType<AgentProviderCompleted>().single.responseId,
      'response-1',
    );
    expect(
      events.whereType<AgentProviderCompleted>().single.continuationState,
      isA<AgentProviderContinuationState>(),
    );
  });

  test('cancellation is idempotent and reports a fixed safe failure', () async {
    final controller = AgentCancellationController();

    expect(controller.token.isCancelled, isFalse);
    controller.cancel();
    controller.cancel();
    await controller.token.whenCancelled;

    expect(controller.token.isCancelled, isTrue);
    expect(
      controller.token.throwIfCancelled,
      throwsA(
        isA<AgentProviderException>().having(
          (error) => error.failure,
          'failure',
          AgentProviderFailure.cancelled,
        ),
      ),
    );
    expect(
      const AgentProviderException(AgentProviderFailure.authentication)
          .toString(),
      isNot(contains('key')),
    );
  });

  test('runtime limits match the frozen A0 v0 bounds', () {
    const limits = AgentRuntimeLimits();

    expect(limits.maxHistoryMessages, 40);
    expect(limits.maxHistoryUtf8Bytes, 64 * 1024);
    expect(limits.maxToolArgumentUtf8Bytes, 16 * 1024);
    expect(limits.maxToolResultUtf8Bytes, 64 * 1024);
    expect(limits.maxToolRounds, 4);
    expect(limits.maxLocalCalls, 8);
    expect(limits.turnTimeout, const Duration(seconds: 120));
    expect(limits.maxOutputTokens, 4096);
  });
}

LogRecord _terminal(_RoundSink sink) {
  expect(sink.records.where((r) => r.data['stage'] == 'provider_round_started'),
      hasLength(1));
  final terminal =
      sink.records.where((r) => r.data['stage'] == 'provider_round_completed');
  expect(terminal, hasLength(1));
  return terminal.single;
}

Future<ProviderRoundResult> _normalize(AgentProviderPort provider,
        {AgentCancellationController? cancellation,
        Duration budget = const Duration(seconds: 10)}) =>
    normalizeProviderRound(
      provider: provider,
      request: AgentProviderRequest(
          systemPrompt: 'secret prompt',
          messages: [
            AgentProviderMessage(
                role: AgentProviderMessageRole.user, content: 'private-marker')
          ],
          temperature: 1,
          reasoningEffort: AgentReasoningEffort.high),
      cancellationToken: (cancellation ?? AgentCancellationController()).token,
      remainingBudget: budget,
      providerRound: 1,
      onText: (_) {},
      onWebSearch: (_) {},
      isTurnTimedOut: () => false,
    );

final class _RoundProvider implements AgentProviderPort {
  _RoundProvider(this.source);
  final Stream<AgentProviderEvent> Function() source;
  @override
  AgentProviderCapabilities get capabilities => const AgentProviderCapabilities(
      functionTools: true, nativeWebSearch: true);
  @override
  Stream<AgentProviderEvent> stream(AgentProviderRequest request,
          AgentCancellationToken cancellationToken) =>
      source();
}

final class _RoundSink implements LogSink {
  final records = <LogRecord>[];
  @override
  Future<void> write(LogRecord record) async => records.add(record);
  @override
  Future<void> flush() async {}
}

final class _ControlledTimer implements Timer {
  _ControlledTimer(this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick = 1;
    callback();
  }

  @override
  void cancel() => isActive = false;
}

final class _FixtureContinuationState
    implements AgentProviderContinuationState {}
