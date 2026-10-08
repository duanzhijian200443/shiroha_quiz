/// Process-local execution truth. Never serialized, logged or persisted.
library;

import 'dart:convert';

import '../../domain/conversations/conversation.dart';
import '../../domain/conversations/conversation_message.dart';
import '../capabilities/capability.dart';
import 'agent_history.dart';
import 'agent_provider.dart';
import 'agent_runtime_limits.dart';
import 'retrieval_egress_grant.dart';

sealed class AgentTranscriptEntry {
  const AgentTranscriptEntry();
  int get utf8Bytes;
}

final class AgentTranscriptVisibleMessage extends AgentTranscriptEntry {
  const AgentTranscriptVisibleMessage(
      {required this.role,
      required this.content,
      this.persistedMessageId,
      this.isCurrentUser = false});
  final AgentProviderMessageRole role;
  final String content;
  final String? persistedMessageId;
  final bool isCurrentUser;
  @override
  int get utf8Bytes => utf8.encode(content).length;
}

/// Trusted side metadata; result text never grants release or replay authority.
final class AgentToolEgressMetadata {
  const AgentToolEgressMetadata(
      {required this.providerProfileId,
      required this.scope,
      required this.grant});
  final String providerProfileId;
  final ConversationScope scope;
  final RetrievalEgressGrant grant;
}

/// A single indivisible canonical unit. Unknown outcomes have no replay group.
final class AgentToolGroup extends AgentTranscriptEntry {
  AgentToolGroup(
      {required this.call,
      required this.result,
      required this.receipt,
      this.egress}) {
    if (call.callId != result.callId ||
        receipt.status == CapabilityExecutionStatus.outcomeUnknown) {
      throw ArgumentError('Tool group requires paired, resolved evidence.');
    }
  }
  final AgentProviderFunctionCall call;
  final AgentFunctionToolOutput result;
  final ExecutionReceipt receipt;
  final AgentToolEgressMetadata? egress;
  @override
  int get utf8Bytes =>
      utf8.encode(call.argumentsJson).length +
      utf8.encode(result.output).length +
      utf8.encode(call.callId).length +
      utf8.encode(call.name).length;
}

final class AgentUnresolvedExecution {
  const AgentUnresolvedExecution({required this.callId, required this.receipt});
  final String callId;
  final ExecutionReceipt receipt;
}

/// Immutable in-process inspection; no transport representation or DB codec.
final class AgentTurnTranscriptSnapshot {
  AgentTurnTranscriptSnapshot(
      {required Iterable<AgentTranscriptEntry> entries,
      required Iterable<AgentUnresolvedExecution> unresolved,
      this.finalAssistant,
      Iterable<ExecutionReceipt> completedEffects = const []})
      : entries = List.unmodifiable(entries),
        unresolved = List.unmodifiable(unresolved),
        completedEffects = List.unmodifiable(completedEffects);
  final List<AgentTranscriptEntry> entries;
  final List<AgentUnresolvedExecution> unresolved;

  /// Settled final visible answer; terminal evidence, never next-round context.
  final AgentTranscriptVisibleMessage? finalAssistant;

  /// Confirmed cache/STAGE facts survive payload pruning or bounded release
  /// failure. Receipts alone cannot replay a tool or restore an artifact.
  final List<ExecutionReceipt> completedEffects;
  List<AgentToolGroup> get toolGroups =>
      List.unmodifiable(entries.whereType<AgentToolGroup>());
}

enum AgentTranscriptFailure { targetMissing, minimumContextTooLarge }

final class AgentTranscriptException implements Exception {
  const AgentTranscriptException(this.failure);
  final AgentTranscriptFailure failure;
}

final class AgentTurnTranscript {
  AgentTurnTranscript(
      {required this.targetMessageId,
      AgentRuntimeLimits limits = const AgentRuntimeLimits()})
      : _limits = limits;
  final String targetMessageId;
  final AgentRuntimeLimits _limits;
  final List<AgentTranscriptEntry> _entries = [];
  final List<AgentUnresolvedExecution> _unresolved = [];
  final List<ExecutionReceipt> _completedEffects = [];
  List<AgentProviderMessage> _providerPersistedHistory = const [];
  AgentTranscriptVisibleMessage? _finalAssistant;

  AgentTurnTranscriptSnapshot get snapshot => AgentTurnTranscriptSnapshot(
      entries: _entries,
      unresolved: _unresolved,
      finalAssistant: _finalAssistant,
      completedEffects: _completedEffects);

  void initializeHistory(AgentHistory history) {
    if (_entries.isNotEmpty) {
      throw StateError('Transcript already initialized.');
    }
    if (!history.persistedMessages.any((m) =>
        m.messageId == targetMessageId &&
        m.role == ConversationMessageRole.user)) {
      throw const AgentTranscriptException(
          AgentTranscriptFailure.targetMissing);
    }
    _entries.addAll(history.persistedMessages.map((m) =>
        AgentTranscriptVisibleMessage(
            role: m.role == ConversationMessageRole.user
                ? AgentProviderMessageRole.user
                : AgentProviderMessageRole.assistant,
            content: m.content,
            persistedMessageId: m.messageId,
            isCurrentUser: m.messageId == targetMessageId)));
    _providerPersistedHistory = List.unmodifiable(history.messages);
  }

  List<AgentProviderMessage> get providerVisibleHistory => List.unmodifiable([
        for (final message
            in _entries.whereType<AgentTranscriptVisibleMessage>())
          AgentProviderMessage(role: message.role, content: message.content)
      ]);

  /// Frozen initial request envelope, independent of canonical payload pruning.
  /// Same-Provider protocol state represents successful current-turn text/tools.
  List<AgentProviderMessage> get providerPersistedHistory =>
      _providerPersistedHistory;

  /// Terminal evidence cannot consume the budget for a subsequent round or
  /// reject a valid final answer before persistence. Intermediate text still
  /// uses the bounded canonical context path below.
  void recordFinalAssistant(String text) {
    _finalAssistant = AgentTranscriptVisibleMessage(
        role: AgentProviderMessageRole.assistant, content: text);
  }

  void recordCompletedAssistant(String text) {
    if (text.isEmpty) return;
    _append([
      AgentTranscriptVisibleMessage(
          role: AgentProviderMessageRole.assistant, content: text)
    ]);
  }

  /// All outputs required by the next round are retained or this fails before
  /// publishing any part of the batch. Past units may be pruned only whole.
  void recordToolRound(Iterable<AgentToolGroup> groups) {
    final batch = List<AgentToolGroup>.of(groups);
    for (final group in batch) {
      final receipt = group.receipt;
      if (receipt.status == CapabilityExecutionStatus.completed &&
          receipt.knownEffect != null &&
          receipt.knownEffect != CapabilityEffect.none &&
          !_completedEffects.any((r) => r.executionId == receipt.executionId)) {
        _completedEffects.add(receipt);
      }
    }
    for (final group in batch) {
      if (utf8.encode(group.call.argumentsJson).length >
              _limits.maxToolArgumentUtf8Bytes ||
          utf8.encode(group.result.output).length >
              _limits.maxToolResultUtf8Bytes) {
        throw const AgentTranscriptException(
            AgentTranscriptFailure.minimumContextTooLarge);
      }
    }
    _append(batch);
  }

  void recordUnresolved(
      AgentProviderFunctionCall call, ExecutionReceipt receipt) {
    if (receipt.status != CapabilityExecutionStatus.outcomeUnknown) {
      throw ArgumentError('Unresolved execution requires unknown outcome.');
    }
    _unresolved
        .add(AgentUnresolvedExecution(callId: call.callId, receipt: receipt));
  }

  /// A final live release denial replaces the entire group result, preserving
  /// the handler's status, known effect and process-local reconciliation.
  void denyRelease(String callId, String safeOutput) {
    final index = _entries
        .indexWhere((e) => e is AgentToolGroup && e.call.callId == callId);
    if (index < 0) return;
    final group = _entries[index] as AgentToolGroup;
    _entries[index] = AgentToolGroup(
        call: group.call,
        result: AgentFunctionToolOutput(callId: callId, output: safeOutput),
        receipt: group.receipt.withFailure(CapabilityFailure.accessDenied),
        egress: group.egress);
  }

  void _append(List<AgentTranscriptEntry> added) {
    final next = [..._entries, ...added];
    final pinned = added.toSet();
    bool overBound() =>
        next.length > _limits.maxHistoryMessages ||
        next.fold<int>(0, (sum, entry) => sum + entry.utf8Bytes) >
            _limits.maxHistoryUtf8Bytes;
    while (overBound()) {
      final index = next.indexWhere((entry) =>
          !pinned.contains(entry) &&
          !(entry is AgentTranscriptVisibleMessage && entry.isCurrentUser));
      if (index < 0) {
        throw const AgentTranscriptException(
            AgentTranscriptFailure.minimumContextTooLarge);
      }
      next.removeAt(index);
    }
    _entries
      ..clear()
      ..addAll(next);
  }

  void clear() {
    _entries.clear();
    _unresolved.clear();
    _completedEffects.clear();
    _providerPersistedHistory = const [];
    _finalAssistant = null;
  }
}
