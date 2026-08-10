import 'dart:async';

import 'agent_config.dart';

final class AgentProviderCapabilities {
  const AgentProviderCapabilities({
    required this.functionTools,
    required this.nativeWebSearch,
  });

  final bool functionTools;
  final bool nativeWebSearch;
}

enum AgentProviderMessageRole { user, assistant }

final class AgentProviderMessage {
  factory AgentProviderMessage({
    required AgentProviderMessageRole role,
    required String content,
  }) {
    if (content.trim().isEmpty || content.contains('\u0000')) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
    return AgentProviderMessage._(role: role, content: content);
  }

  const AgentProviderMessage._({required this.role, required this.content});

  final AgentProviderMessageRole role;
  final String content;
}

final class AgentFunctionToolDefinition {
  factory AgentFunctionToolDefinition({
    required String name,
    required String description,
    required Map<String, Object?> inputSchema,
  }) {
    if (!_isSafeToken(name, maxRunes: 128) ||
        !_isSafeText(description, maxRunes: 1000)) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
    return AgentFunctionToolDefinition._(
      name: name,
      description: description,
      inputSchema: Map<String, Object?>.unmodifiable(inputSchema),
    );
  }

  const AgentFunctionToolDefinition._({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
}

final class AgentFunctionToolOutput {
  factory AgentFunctionToolOutput({
    required String callId,
    required String output,
  }) {
    if (!_isSafeToken(callId, maxRunes: 256) || output.contains('\u0000')) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
    return AgentFunctionToolOutput._(callId: callId, output: output);
  }

  const AgentFunctionToolOutput._({
    required this.callId,
    required this.output,
  });

  final String callId;
  final String output;
}

abstract interface class AgentProviderContinuationState {}

final class AgentProviderRequest {
  factory AgentProviderRequest({
    required String systemPrompt,
    required List<AgentProviderMessage> messages,
    List<AgentFunctionToolDefinition> tools =
        const <AgentFunctionToolDefinition>[],
    List<AgentFunctionToolOutput> toolOutputs =
        const <AgentFunctionToolOutput>[],
    AgentProviderContinuationState? continuationState,
    bool enableNativeWebSearch = false,
    int maxOutputTokens = 4096,
    required double temperature,
    required AgentReasoningEffort reasoningEffort,
  }) {
    if (!_isSafeText(systemPrompt, maxRunes: 32000) ||
        messages.isEmpty ||
        maxOutputTokens <= 0 ||
        !temperature.isFinite ||
        temperature < 0.0 ||
        temperature > 2.0 ||
        (toolOutputs.isNotEmpty) != (continuationState != null)) {
      throw const AgentProviderException(AgentProviderFailure.invalidRequest);
    }
    return AgentProviderRequest._(
      systemPrompt: systemPrompt,
      messages: List<AgentProviderMessage>.unmodifiable(messages),
      tools: List<AgentFunctionToolDefinition>.unmodifiable(tools),
      toolOutputs: List<AgentFunctionToolOutput>.unmodifiable(toolOutputs),
      continuationState: continuationState,
      enableNativeWebSearch: enableNativeWebSearch,
      maxOutputTokens: maxOutputTokens,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );
  }

  const AgentProviderRequest._({
    required this.systemPrompt,
    required this.messages,
    required this.tools,
    required this.toolOutputs,
    required this.continuationState,
    required this.enableNativeWebSearch,
    required this.maxOutputTokens,
    required this.temperature,
    required this.reasoningEffort,
  });

  final String systemPrompt;
  final List<AgentProviderMessage> messages;
  final List<AgentFunctionToolDefinition> tools;
  final List<AgentFunctionToolOutput> toolOutputs;
  final AgentProviderContinuationState? continuationState;
  final bool enableNativeWebSearch;
  final int maxOutputTokens;
  final double temperature;
  final AgentReasoningEffort reasoningEffort;
}

sealed class AgentProviderEvent {
  const AgentProviderEvent();
}

final class AgentProviderTextDelta extends AgentProviderEvent {
  factory AgentProviderTextDelta(String text) {
    if (text.isEmpty || text.contains('\u0000')) {
      throw const AgentProviderException(
        AgentProviderFailure.malformedResponse,
      );
    }
    return AgentProviderTextDelta._(text);
  }

  const AgentProviderTextDelta._(this.text);

  final String text;
}

final class AgentProviderFunctionCall extends AgentProviderEvent {
  factory AgentProviderFunctionCall({
    required String callId,
    required String name,
    required String argumentsJson,
  }) {
    if (!_isSafeToken(callId, maxRunes: 256) ||
        !_isSafeToken(name, maxRunes: 128) ||
        argumentsJson.contains('\u0000')) {
      throw const AgentProviderException(
        AgentProviderFailure.malformedResponse,
      );
    }
    return AgentProviderFunctionCall._(
      callId: callId,
      name: name,
      argumentsJson: argumentsJson,
    );
  }

  const AgentProviderFunctionCall._({
    required this.callId,
    required this.name,
    required this.argumentsJson,
  });

  final String callId;
  final String name;
  final String argumentsJson;
}

enum AgentProviderWebSearchPhase { searching, completed }

final class AgentProviderWebSearchEvent extends AgentProviderEvent {
  const AgentProviderWebSearchEvent(this.phase);

  final AgentProviderWebSearchPhase phase;
}

final class AgentProviderCompleted extends AgentProviderEvent {
  factory AgentProviderCompleted(
    String responseId, {
    AgentProviderContinuationState? continuationState,
  }) {
    final normalized = responseId.trim();
    if (!_isSafeToken(normalized, maxRunes: 256)) {
      throw const AgentProviderException(
        AgentProviderFailure.malformedResponse,
      );
    }
    return AgentProviderCompleted._(normalized, continuationState);
  }

  const AgentProviderCompleted._(this.responseId, this.continuationState);

  final String responseId;
  final AgentProviderContinuationState? continuationState;
}

abstract interface class AgentProviderPort {
  AgentProviderCapabilities get capabilities;

  Stream<AgentProviderEvent> stream(
    AgentProviderRequest request,
    AgentCancellationToken cancellationToken,
  );
}

enum AgentProviderFailure {
  invalidRequest,
  authentication,
  rateLimited,
  temporarilyUnavailable,
  timeout,
  cancelled,
  unsupportedCapability,
  unsupportedModel,
  incompleteResponse,
  malformedResponse,
  internalError,
}

final class AgentProviderException implements Exception {
  const AgentProviderException(this.failure);

  final AgentProviderFailure failure;

  @override
  String toString() => 'AgentProviderException(${failure.name})';
}

final class AgentCancellationController {
  AgentCancellationController() : token = AgentCancellationToken._();

  final AgentCancellationToken token;

  void cancel() => token._cancel();
}

final class AgentCancellationToken {
  AgentCancellationToken._();

  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void throwIfCancelled() {
    if (isCancelled) {
      throw const AgentProviderException(AgentProviderFailure.cancelled);
    }
  }

  void _cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

bool _isSafeToken(String value, {required int maxRunes}) {
  final length = value.runes.length;
  return length >= 1 &&
      length <= maxRunes &&
      !value.contains(RegExp(r'[\s\u0000]'));
}

bool _isSafeText(String value, {required int maxRunes}) {
  final length = value.runes.length;
  return value.trim().isNotEmpty &&
      length <= maxRunes &&
      !value.contains('\u0000');
}
