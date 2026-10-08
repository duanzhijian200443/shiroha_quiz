import '../../domain/conversations/conversation.dart';
import '../capabilities/capability.dart';
import 'agent_provider.dart';
import 'agent_tool_projection.dart';

enum AgentGuidanceSlot { permission, studyTools, fileTool, fileAvailability }

/// Source-owned guidance travels with the projection that makes it available.
final class AgentPromptGuidance {
  const AgentPromptGuidance(this.slot, this.text);
  final AgentGuidanceSlot slot;
  final String text;
}

/// Trusted turn values supplied by ToolExecutor, never by model arguments.
final class AgentProjectionInvocation {
  const AgentProjectionInvocation(
      {required this.argumentsJson, required this.context});
  final String argumentsJson;
  final CapabilityContext context;
}

typedef AgentEffectiveFileIds = Future<List<String>> Function({
  required ConversationScope scope,
  required List<String> conversationFileIds,
});

final class RegisteredAgentProjection {
  RegisteredAgentProjection({
    required this.capabilityId,
    required AgentFunctionToolDefinition definition,
    required this.dispatch,
    this.permission = CapabilityPermission.read,
    this.exposureOrder = 0,
    Iterable<AgentPromptGuidance> guidance = const [],
    this.effectiveFileIds,
  })  : definition = AgentFunctionToolDefinition(
            name: definition.name,
            description: definition.description,
            inputSchema: _freezeMap(definition.inputSchema)),
        guidance = List.unmodifiable(guidance);
  final CapabilityId capabilityId;
  final CapabilityPermission permission;

  /// Adapter order retains the accepted Provider request catalog order.
  final int exposureOrder;
  final AgentFunctionToolDefinition definition;
  final Future<AgentToolDispatchResult> Function(AgentProjectionInvocation)
      dispatch;
  final List<AgentPromptGuidance> guidance;
  final AgentEffectiveFileIds? effectiveFileIds;
  bool get requiresEgress => effectiveFileIds != null;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeValue(entry.value),
    });
Object? _freezeValue(Object? value) {
  if (value is Map<String, Object?>) return _freezeMap(value);
  if (value is List) return List.unmodifiable(value.map(_freezeValue));
  return value;
}

final class AgentSurface {
  AgentSurface(Iterable<RegisteredAgentProjection> projections)
      : projections = List.unmodifiable(projections);
  final List<RegisteredAgentProjection> projections;
  AgentEffectiveFileIds? get effectiveFileIds =>
      projections.where((p) => p.requiresEgress).firstOrNull?.effectiveFileIds;
  List<RegisteredAgentProjection> exposed({required bool fileAccess}) {
    final indexed = projections.indexed
        .where((p) => !p.$2.requiresEgress || fileAccess)
        .toList()
      ..sort((a, b) {
        final order = a.$2.exposureOrder.compareTo(b.$2.exposureOrder);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    return List.unmodifiable(indexed.map((p) => p.$2));
  }

  List<AgentPromptGuidance> guidance({required bool fileAccess}) =>
      List.unmodifiable(projections
          .where((p) => !p.requiresEgress || fileAccess)
          .expand((p) => p.guidance));
}
