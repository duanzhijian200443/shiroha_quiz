import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';

void main() {
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
    final request = AgentProviderRequest(
      systemPrompt: 'You are Shiroha.',
      messages: messages,
      tools: tools,
      toolOutputs: <AgentFunctionToolOutput>[output],
      previousResponseId: 'response-1',
      enableNativeWebSearch: true,
    );

    messages.clear();
    tools.clear();

    expect(request.messages, hasLength(1));
    expect(request.tools, hasLength(1));
    expect(request.toolOutputs, <AgentFunctionToolOutput>[output]);
    expect(request.previousResponseId, 'response-1');
    expect(request.enableNativeWebSearch, isTrue);
    expect(request.maxOutputTokens, 4096);

    expect(
      () => AgentProviderRequest(
        systemPrompt: 'You are Shiroha.',
        messages: request.messages,
        toolOutputs: <AgentFunctionToolOutput>[output],
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
      AgentProviderCompleted('response-1'),
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
