import '../agent/agent_surface.dart';
import '../capabilities/capability.dart';

enum ModuleCompositionFailure {
  duplicateModule('duplicate_module'),
  missingDependency('missing_dependency'),
  dependencyCycle('dependency_cycle'),
  duplicateCapability('duplicate_capability'),
  duplicateAgentProjection('duplicate_agent_projection'),
  duplicateMcpProjection('duplicate_mcp_projection'),
  duplicateUiKey('duplicate_ui_key'),
  projectionMissingCapability('projection_missing_capability'),
  invalidModuleContribution('invalid_module_contribution');

  const ModuleCompositionFailure(this.code);
  final String code;
}

final class ModuleCompositionException implements Exception {
  const ModuleCompositionException(this.failure);
  final ModuleCompositionFailure failure;
  @override
  String toString() => 'ModuleCompositionException(${failure.code})';
}

final class ModuleId {
  const ModuleId(this.value);
  final String value;
  @override
  bool operator ==(Object other) => other is ModuleId && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

/// Adapter-owned schema/annotations/encoding remain under lib/mcp.
final class ModuleMcpProjection {
  const ModuleMcpProjection({required this.key, required this.capabilityId});
  final String key;
  final CapabilityId capabilityId;
}

enum ModuleUiSlot { workspaceAction, assistantArtifact }

/// Finite shell descriptor, without routes, Widgets or arbitrary service values.
final class ModuleUiContribution {
  const ModuleUiContribution({required this.key, required this.slot});
  final String key;
  final ModuleUiSlot slot;
}

final class ModuleContribution {
  ModuleContribution(
      {required this.id,
      Iterable<ModuleId> requiredModuleIds = const [],
      this.registerCapabilities,
      this.registerAgent,
      this.registerMcp,
      this.registerUi})
      : requiredModuleIds = List.unmodifiable(requiredModuleIds);
  final ModuleId id;
  final List<ModuleId> requiredModuleIds;
  final void Function(ModuleCapabilityRegistrar)? registerCapabilities;
  final void Function(ModuleAgentRegistrar)? registerAgent;
  final void Function(ModuleMcpRegistrar)? registerMcp;
  final void Function(ModuleUiRegistrar)? registerUi;
}

final class ModuleCapabilityRegistrar {
  ModuleCapabilityRegistrar._(this._register);
  final void Function(CapabilityDefinition) _register;
  bool _open = true;
  void registerCapability(CapabilityDefinition definition) {
    _checkOpen(_open);
    _register(definition);
  }
}

final class ModuleAgentRegistrar {
  ModuleAgentRegistrar._(this._register);
  final void Function(RegisteredAgentProjection Function(CapabilityExecutor))
      _register;
  bool _open = true;
  void registerAgentProjection(
      RegisteredAgentProjection Function(CapabilityExecutor) build) {
    _checkOpen(_open);
    _register(build);
  }
}

final class ModuleMcpRegistrar {
  ModuleMcpRegistrar._(this._register);
  final void Function(ModuleMcpProjection) _register;
  bool _open = true;
  void registerMcpProjection(ModuleMcpProjection projection) {
    _checkOpen(_open);
    _register(projection);
  }
}

final class ModuleUiRegistrar {
  ModuleUiRegistrar._(this._register);
  final void Function(ModuleUiContribution) _register;
  bool _open = true;
  void registerUiContribution(ModuleUiContribution contribution) {
    _checkOpen(_open);
    _register(contribution);
  }
}

void _checkOpen(bool open) {
  if (!open) {
    throw const ModuleCompositionException(
        ModuleCompositionFailure.invalidModuleContribution);
  }
}

void _fail(ModuleCompositionFailure failure) =>
    throw ModuleCompositionException(failure);
final _sourceKey = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
void _validateKey(String key) {
  if (!_sourceKey.hasMatch(key)) {
    _fail(ModuleCompositionFailure.invalidModuleContribution);
  }
}

final class ModuleComposition {
  ModuleComposition._(
      {required Iterable<ModuleId> moduleOrder,
      required this.capabilities,
      required this.agentSurface,
      required Iterable<ModuleMcpProjection> mcpSurface,
      required Iterable<ModuleUiContribution> uiContributions})
      : moduleOrder = List.unmodifiable(moduleOrder),
        mcpSurface = List.unmodifiable(mcpSurface),
        uiContributions = List.unmodifiable(uiContributions);
  final List<ModuleId> moduleOrder;
  final ApplicationCapabilityRegistry capabilities;
  final AgentSurface agentSurface;
  final List<ModuleMcpProjection> mcpSurface;
  final List<ModuleUiContribution> uiContributions;
}

/// All buffers are private to a single attempt. The return is the only publication.
final class ModuleComposer {
  const ModuleComposer();
  ModuleComposition compose(Iterable<ModuleContribution> contributions) {
    try {
      return _compose(List.of(contributions));
    } on ModuleCompositionException {
      rethrow;
    } catch (_) {
      _fail(ModuleCompositionFailure.invalidModuleContribution);
      rethrow;
    }
  }

  ModuleComposition _compose(List<ModuleContribution> modules) {
    final byId = <ModuleId, ModuleContribution>{};
    for (final module in modules) {
      _validateKey(module.id.value);
      if (byId.containsKey(module.id)) {
        _fail(ModuleCompositionFailure.duplicateModule);
      }
      byId[module.id] = module;
      for (final dependency in module.requiredModuleIds) {
        _validateKey(dependency.value);
      }
      if (module.requiredModuleIds.toSet().length !=
          module.requiredModuleIds.length) {
        _fail(ModuleCompositionFailure.invalidModuleContribution);
      }
    }
    for (final module in modules) {
      if (module.requiredModuleIds.any((id) => !byId.containsKey(id))) {
        _fail(ModuleCompositionFailure.missingDependency);
      }
    }
    final pending = Map.of(byId);
    final ordered = <ModuleContribution>[];
    final complete = <ModuleId>{};
    while (pending.isNotEmpty) {
      final layer = pending.values
          .where((m) => m.requiredModuleIds.every(complete.contains))
          .toList()
        ..sort((a, b) => a.id.value.compareTo(b.id.value));
      if (layer.isEmpty) _fail(ModuleCompositionFailure.dependencyCycle);
      for (final module in layer) {
        ordered.add(module);
        complete.add(module.id);
        pending.remove(module.id);
      }
    }
    final definitions = <CapabilityDefinition>[];
    final ids = <String>{};
    final capabilities = ModuleCapabilityRegistrar._((definition) {
      if (!ids.add(definition.id.value)) {
        _fail(ModuleCompositionFailure.duplicateCapability);
      }
      definitions.add(definition);
    });
    try {
      for (final module in ordered) {
        module.registerCapabilities?.call(capabilities);
      }
    } finally {
      capabilities._open = false;
    }
    final registry = ApplicationCapabilityRegistry(definitions);
    final executor = CapabilityExecutor(registry);
    void validateBinding(CapabilityId id) {
      if (!definitions.any((d) => d.id == id)) {
        _fail(ModuleCompositionFailure.projectionMissingCapability);
      }
    }

    final agents = <RegisteredAgentProjection>[];
    final agentKeys = <String>{};
    final agent = ModuleAgentRegistrar._((build) {
      final projection = build(executor);
      _validateKey(projection.definition.name);
      if (!agentKeys.add(projection.definition.name)) {
        _fail(ModuleCompositionFailure.duplicateAgentProjection);
      }
      validateBinding(projection.capabilityId);
      agents.add(projection);
    });
    final mcps = <ModuleMcpProjection>[];
    final mcpKeys = <String>{};
    final mcp = ModuleMcpRegistrar._((projection) {
      _validateKey(projection.key);
      if (!mcpKeys.add(projection.key)) {
        _fail(ModuleCompositionFailure.duplicateMcpProjection);
      }
      validateBinding(projection.capabilityId);
      mcps.add(projection);
    });
    final uis = <ModuleUiContribution>[];
    final uiKeys = <String>{};
    final ui = ModuleUiRegistrar._((contribution) {
      _validateKey(contribution.key);
      if (!uiKeys.add(contribution.key)) {
        _fail(ModuleCompositionFailure.duplicateUiKey);
      }
      uis.add(contribution);
    });
    try {
      for (final module in ordered) {
        module.registerAgent?.call(agent);
        module.registerMcp?.call(mcp);
        module.registerUi?.call(ui);
      }
    } finally {
      agent._open = false;
      mcp._open = false;
      ui._open = false;
    }
    if (agents.where((p) => p.requiresEgress).length > 1) {
      {
        _fail(ModuleCompositionFailure.invalidModuleContribution);
      }
    }
    return ModuleComposition._(
        moduleOrder: ordered.map((m) => m.id),
        capabilities: registry,
        agentSurface: AgentSurface(agents),
        mcpSurface: mcps,
        uiContributions: uis);
  }
}
