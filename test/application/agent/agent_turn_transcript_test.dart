import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_history.dart';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_runtime_limits.dart';
import 'package:shiroha_quiz/application/agent/agent_turn_transcript.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/conversations/conversation_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/conversations/conversation_message.dart';

void main() {
  test(
      'reuses exact deterministic history selection and preserves current User',
      () {
    const limits =
        AgentRuntimeLimits(maxHistoryMessages: 3, maxHistoryUtf8Bytes: 60);
    final history = AgentHistoryBuilder(limits: limits).build(
        slice: _slice([for (var n = 1; n <= 8; n++) _message(n, '你' * n)]),
        targetMessageId: 'm8');
    final transcript =
        AgentTurnTranscript(targetMessageId: 'm8', limits: limits)
          ..initializeHistory(history);
    expect(transcript.providerVisibleHistory.map((m) => m.content),
        history.messages.map((m) => m.content));
    final visible =
        transcript.snapshot.entries.cast<AgentTranscriptVisibleMessage>();
    expect(visible.map((m) => m.persistedMessageId), ['m7', 'm8']);
    expect(visible.last.isCurrentUser, isTrue);
  });

  test('cannot silently initialize without a target User', () {
    expect(
        () => AgentTurnTranscript(targetMessageId: 'missing').initializeHistory(
            AgentHistoryBuilder().build(
                slice: _slice([_message(1, 'User')]), targetMessageId: 'm1')),
        throwsA(isA<AgentTranscriptException>().having((e) => e.failure,
            'failure', AgentTranscriptFailure.targetMissing)));
  });

  test(
      'complete business error preserves call, safe error result and real receipt',
      () {
    final transcript = _transcript();
    final receipt = _receipt(
        status: CapabilityExecutionStatus.failedWithoutEffect,
        failure: CapabilityFailure.notFound);
    final group = _group('one',
        result: '{"ok":false,"error":{"code":"not_found"}}', receipt: receipt);
    transcript.recordToolRound([group]);
    expect(transcript.snapshot.toolGroups.single, same(group));
    expect(group.call.callId, group.result.callId);
    expect(group.receipt, same(receipt));
    expect(group.receipt.knownEffect, CapabilityEffect.none);
  });

  test('mismatched pair and unknown outcome cannot become canonical group', () {
    expect(
        () => AgentToolGroup(
            call: _call('one'),
            result: AgentFunctionToolOutput(callId: 'other', output: '{}'),
            receipt: _receipt()),
        throwsArgumentError);
    expect(
        () => _group('one',
            receipt: _receipt(
                status: CapabilityExecutionStatus.outcomeUnknown,
                effect: null)),
        throwsArgumentError);
  });

  test('unknown outcome goes only into minimal unresolved ledger, never replay',
      () {
    final transcript = _transcript();
    final receipt = _receipt(
        status: CapabilityExecutionStatus.outcomeUnknown,
        effect: CapabilityEffect.derivedCache);
    transcript.recordUnresolved(
        _call('uncertain', arguments: 'PRIVATE_TOOL_ARGUMENT'), receipt);
    expect(transcript.snapshot.toolGroups, isEmpty);
    expect(transcript.snapshot.unresolved.single.callId, 'uncertain');
    expect(transcript.snapshot.unresolved.single.receipt, same(receipt));
    expect(transcript.providerVisibleHistory.single.content, 'User');
    expect(() => transcript.recordUnresolved(_call('one'), _receipt()),
        throwsArgumentError);
  });

  test('multiple round ordering is deterministic and snapshots are immutable',
      () {
    final transcript = _transcript();
    final one = _group('one'), two = _group('two'), three = _group('three');
    transcript.recordToolRound([one, two]);
    final before = transcript.snapshot;
    transcript.recordCompletedAssistant('successful visible text');
    transcript.recordToolRound([three]);
    expect(transcript.snapshot.toolGroups.map((g) => g.call.callId),
        ['one', 'two', 'three']);
    expect(before.toolGroups, [one, two]);
    expect(() => before.entries.clear(), throwsUnsupportedError);
    expect(() => before.unresolved.clear(), throwsUnsupportedError);
  });

  test(
      'count pruning removes whole visible messages and then whole tool groups',
      () {
    const limits = AgentRuntimeLimits(maxHistoryMessages: 3);
    final history = AgentHistoryBuilder(limits: limits).build(
        slice: _slice([
          _message(1, 'old A'),
          _message(2, 'old B'),
          _message(3, 'target')
        ]),
        targetMessageId: 'm3');
    final transcript =
        AgentTurnTranscript(targetMessageId: 'm3', limits: limits)
          ..initializeHistory(history);
    final one = _group('one'), two = _group('two'), three = _group('three');
    transcript.recordToolRound([one, two]);
    expect(transcript.snapshot.entries,
        [isA<AgentTranscriptVisibleMessage>(), one, two]);
    transcript.recordToolRound([three]);
    expect(transcript.snapshot.entries,
        [isA<AgentTranscriptVisibleMessage>(), two, three]);
    for (final group in transcript.snapshot.toolGroups) {
      expect(group.result.callId, group.call.callId);
      expect(group.receipt.executionId, 'execution');
    }
    expect(
        (transcript.snapshot.entries.first as AgentTranscriptVisibleMessage)
            .isCurrentUser,
        isTrue);
  });

  test('UTF-8 pruning keeps whole JSON and receipt, never truncates payload',
      () {
    const limits = AgentRuntimeLimits(maxHistoryUtf8Bytes: 110);
    final transcript = _transcript(limits: limits);
    final one = _group('one', result: '你' * 18),
        two = _group('two', result: '你' * 18);
    transcript.recordToolRound([one]);
    transcript.recordToolRound([two]);
    expect(transcript.snapshot.toolGroups, [two]);
    expect(two.result.output, '你' * 18);
    expect(two.call.argumentsJson, '{}');
    expect(two.receipt, same(two.receipt));
  });

  test('required whole batch plus target cannot fit: atomic bounded failure',
      () {
    const limits = AgentRuntimeLimits(maxHistoryMessages: 2);
    final transcript = _transcript(limits: limits);
    final before = transcript.snapshot;
    expect(
        () => transcript.recordToolRound([_group('one'), _group('two')]),
        throwsA(isA<AgentTranscriptException>().having((e) => e.failure,
            'failure', AgentTranscriptFailure.minimumContextTooLarge)));
    expect(transcript.snapshot.entries, before.entries);
    expect(transcript.snapshot.toolGroups, isEmpty);
  });

  for (final oversizeArgument in [true, false]) {
    test('individual byte bound remains hard: argument=$oversizeArgument', () {
      const limits = AgentRuntimeLimits(
          maxToolArgumentUtf8Bytes: 3, maxToolResultUtf8Bytes: 3);
      final transcript = _transcript(limits: limits);
      final group = _group('one',
          arguments: oversizeArgument ? '你你' : '{}',
          result: oversizeArgument ? '{}' : '你你');
      expect(() => transcript.recordToolRound([group]),
          throwsA(isA<AgentTranscriptException>()));
      expect(transcript.snapshot.toolGroups, isEmpty);
    });
  }

  test('confirmed STAGE effect survives an atomic minimum-context failure', () {
    const limits = AgentRuntimeLimits(maxHistoryMessages: 1);
    final transcript = _transcript(limits: limits);
    final receipt = _receipt(
        effect: CapabilityEffect.proposalStaged,
        reconciliation: TransientReconciliationReference(
            owner: Object(), artifactId: 'staged'));
    expect(
        () => transcript.recordToolRound([_group('stage', receipt: receipt)]),
        throwsA(isA<AgentTranscriptException>()));
    expect(transcript.snapshot.toolGroups, isEmpty);
    expect(transcript.snapshot.completedEffects.single, same(receipt));
    expect(
        transcript.snapshot.completedEffects.single.reconciliation!.artifactId,
        'staged');
    expect(() => transcript.snapshot.completedEffects.clear(),
        throwsUnsupportedError);
  });

  test(
      'confirmed derived-cache receipt survives whole-group pruning without replay content',
      () {
    const limits = AgentRuntimeLimits(maxHistoryMessages: 2);
    final transcript = _transcript(limits: limits);
    final cache = _group('cache',
        receipt: _receipt(effect: CapabilityEffect.derivedCache));
    transcript.recordToolRound([cache]);
    transcript.recordToolRound([_group('new')]);
    expect(transcript.snapshot.toolGroups.single.call.callId, 'new');
    expect(transcript.snapshot.completedEffects.single, same(cache.receipt));
  });

  test(
      'STAGE reconciliation/effect survives release denial; process ownership remains',
      () {
    final owner = Object();
    final reference =
        TransientReconciliationReference(owner: owner, artifactId: 'staged');
    final receipt = _receipt(
        effect: CapabilityEffect.proposalStaged, reconciliation: reference);
    final transcript = _transcript()
      ..recordToolRound([_group('stage', receipt: receipt)]);
    transcript.denyRelease('stage', '{"ok":false}');
    final group = transcript.snapshot.toolGroups.single;
    expect(group.result.output, '{"ok":false}');
    expect(group.receipt.status, CapabilityExecutionStatus.completed);
    expect(group.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(group.receipt.failure, CapabilityFailure.accessDenied);
    expect(group.receipt.reconciliation, same(reference));
    expect(reference.belongsTo(owner), isTrue);
    expect(reference.belongsTo(Object()), isFalse);
    transcript.clear();
    expect(transcript.snapshot.entries, isEmpty);
    expect(transcript.snapshot.unresolved, isEmpty);
  });
}

AgentTurnTranscript _transcript(
        {AgentRuntimeLimits limits = const AgentRuntimeLimits()}) =>
    AgentTurnTranscript(targetMessageId: 'm1', limits: limits)
      ..initializeHistory(AgentHistoryBuilder(limits: limits)
          .build(slice: _slice([_message(1, 'User')]), targetMessageId: 'm1'));
AgentProviderFunctionCall _call(String id, {String arguments = '{}'}) =>
    AgentProviderFunctionCall(
        callId: id, name: 'fixture_read', argumentsJson: arguments);
AgentToolGroup _group(String id,
        {String arguments = '{}',
        String result = '{}',
        ExecutionReceipt? receipt}) =>
    AgentToolGroup(
        call: _call(id, arguments: arguments),
        result: AgentFunctionToolOutput(callId: id, output: result),
        receipt: receipt ?? _receipt());
ExecutionReceipt _receipt(
        {CapabilityExecutionStatus status = CapabilityExecutionStatus.completed,
        CapabilityEffect? effect = CapabilityEffect.none,
        CapabilityFailure? failure,
        TransientReconciliationReference? reconciliation}) =>
    ExecutionReceipt(
        executionId: 'execution',
        capabilityId: const CapabilityId<void, void>('fixture_read'),
        status: status,
        knownEffect: effect,
        failure: failure,
        principal: CapabilityPrincipal.builtInAgent,
        scope: ConversationScope.global(),
        authorization: const CapabilityAuthorizationReferences(),
        reconciliation: reconciliation);
ConversationMessage _message(int n, String content) => ConversationMessage(
    messageId: 'm$n',
    conversationId: 'conversation',
    sequence: n,
    role: ConversationMessageRole.user,
    content: content,
    createdAt: DateTime.utc(2026));
ConversationThreadSlice _slice(List<ConversationMessage> messages) =>
    ConversationThreadSlice(
        conversation: Conversation(
            conversationId: 'conversation',
            scope: ConversationScope.global(),
            title: 'title',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026)),
        messages: messages,
        files: const [],
        hasMoreBefore: false,
        nextBeforeSequence: null);
