import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'module_test_support.dart';

Matcher failure(ModuleCompositionFailure code) =>
    throwsA(isA<ModuleCompositionException>()
        .having((e) => e.failure, 'fixed failure', code));

void main() {
  const composer = ModuleComposer();
  ModuleContribution graph(String id, List<String> dependencies) =>
      ModuleContribution(
          id: ModuleId(id), requiredModuleIds: dependencies.map(ModuleId.new));
  test('entire topology layer is sorted; permutations preserve every surface',
      () {
    final modules = [
      graph('z', []),
      graph('b', ['z']),
      graph('a', []),
      fixtureModule(requires: const [ModuleId('b')])
    ];
    final permutations = [
      modules,
      modules.reversed,
      [modules[1], modules[3], modules[0], modules[2]]
    ];
    for (final input in permutations) {
      final result = composer.compose(input);
      expect(
          result.moduleOrder.map((id) => id.value), ['a', 'z', 'b', 'fixture']);
      expect(result.capabilities.definitions.map((d) => d.id.value),
          ['fixture_read']);
      expect(result.agentSurface.projections.map((p) => p.definition.name),
          ['fixture_tool']);
      expect(result.mcpSurface.map((p) => p.key), ['fixture_mcp']);
      expect(result.uiContributions.map((p) => p.key), ['fixture_artifact']);
    }
  });
  test(
      'graph failure occurs before callbacks and leaves old publication intact',
      () {
    var callbacks = 0;
    final bad = ModuleContribution(
        id: const ModuleId('a'),
        requiredModuleIds: const [ModuleId('b')],
        registerCapabilities: (_) => callbacks++);
    var published = composer.compose([fixtureModule()]);
    final old = published;
    expect(() => published = composer.compose([bad]),
        failure(ModuleCompositionFailure.missingDependency));
    expect(callbacks, 0);
    expect(published, same(old));
    expect(
        () => composer.compose([
              graph('a', ['b']),
              graph('b', ['c']),
              graph('c', ['a'])
            ]),
        failure(ModuleCompositionFailure.dependencyCycle));
    expect(callbacks, 0);
  });
  for (final id in ['', 'Study', 'a b', 'a' * 65]) {
    test(
        'bounded source ModuleId rejects invalid form: ${id.length}',
        () => expect(() => composer.compose([graph(id, [])]),
            failure(ModuleCompositionFailure.invalidModuleContribution)));
  }
  test('duplicate module and duplicate required ID fail', () {
    expect(() => composer.compose([graph('a', []), graph('a', [])]),
        failure(ModuleCompositionFailure.duplicateModule));
    expect(
        () => composer.compose([
              graph('a', ['b', 'b']),
              graph('b', [])
            ]),
        failure(ModuleCompositionFailure.invalidModuleContribution));
  });
  final duplicates = <ModuleCompositionFailure, ModuleContribution>{
    ModuleCompositionFailure.duplicateCapability: ModuleContribution(
        id: const ModuleId('second'),
        registerCapabilities: (r) => r.registerCapability(fixtureCapability())),
    ModuleCompositionFailure.duplicateAgentProjection: ModuleContribution(
        id: const ModuleId('second'),
        registerAgent: (r) => r.registerAgentProjection(fixtureProjection)),
    ModuleCompositionFailure.duplicateMcpProjection: ModuleContribution(
        id: const ModuleId('second'),
        registerMcp: (r) => r.registerMcpProjection(const ModuleMcpProjection(
            key: 'fixture_mcp', capabilityId: fixtureId))),
    ModuleCompositionFailure.duplicateUiKey: ModuleContribution(
        id: const ModuleId('second'),
        registerUi: (r) => r.registerUiContribution(const ModuleUiContribution(
            key: 'fixture_artifact', slot: ModuleUiSlot.workspaceAction))),
  };
  for (final entry in duplicates.entries) {
    test('${entry.key.code} prevents replacing a published composition', () {
      var published = composer.compose([fixtureModule()]);
      final old = published;
      expect(() => published = composer.compose([fixtureModule(), entry.value]),
          failure(entry.key));
      expect(published, same(old));
    });
  }
  test(
      'all capabilities register before any projection, independent of modules',
      () {
    final projected = ModuleContribution(
        id: const ModuleId('a'),
        registerAgent: (r) => r.registerAgentProjection(fixtureProjection));
    final truth = ModuleContribution(
        id: const ModuleId('z'),
        registerCapabilities: (r) => r.registerCapability(fixtureCapability()));
    expect(composer.compose([projected, truth]).agentSurface.projections,
        hasLength(1));
  });
  for (final agent in [true, false]) {
    test(
        'absent or mismatched capability fails ${agent ? 'Agent' : 'MCP'} binding',
        () {
      final orphan = ModuleContribution(
          id: const ModuleId('orphan'),
          registerAgent: agent
              ? (r) => r.registerAgentProjection(fixtureProjection)
              : null,
          registerMcp: agent
              ? null
              : (r) => r.registerMcpProjection(const ModuleMcpProjection(
                  key: 'orphan', capabilityId: fixtureId)));
      expect(() => composer.compose([orphan]),
          failure(ModuleCompositionFailure.projectionMissingCapability));
      final mismatch = ModuleContribution(
          id: const ModuleId('mismatch'),
          registerCapabilities: (r) =>
              r.registerCapability(fixtureCapability()),
          registerMcp: (r) => r.registerMcpProjection(const ModuleMcpProjection(
              key: 'mismatch',
              capabilityId: CapabilityId<String, String>('fixture_read'))));
      expect(() => composer.compose([mismatch]),
          failure(ModuleCompositionFailure.projectionMissingCapability));
    });
  }
  test('source callback exceptions are redacted and publication is atomic', () {
    var published = composer.compose([fixtureModule()]);
    final old = published;
    expect(
        () => published = composer.compose([
              ModuleContribution(
                  id: const ModuleId('bad'),
                  registerUi: (_) => throw StateError('private marker'))
            ]),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(published, same(old));
    expect(
        const ModuleCompositionException(
                ModuleCompositionFailure.invalidModuleContribution)
            .toString(),
        isNot(contains('private')));
  });
  test('registrars close after their phase, on success and failure', () {
    late ModuleCapabilityRegistrar capability;
    late ModuleAgentRegistrar agent;
    late ModuleMcpRegistrar mcp;
    late ModuleUiRegistrar ui;
    final capture = ModuleContribution(
        id: const ModuleId('capture'),
        registerCapabilities: (r) => capability = r,
        registerAgent: (r) => agent = r,
        registerMcp: (r) => mcp = r,
        registerUi: (r) => ui = r);
    composer.compose([capture, fixtureModule()]);
    expect(() => capability.registerCapability(fixtureCapability()),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(() => agent.registerAgentProjection(fixtureProjection),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(
        () => mcp.registerMcpProjection(
            const ModuleMcpProjection(key: 'late', capabilityId: fixtureId)),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(
        () => ui.registerUiContribution(const ModuleUiContribution(
            key: 'late', slot: ModuleUiSlot.workspaceAction)),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(
        () => composer.compose([
              capture,
              ModuleContribution(
                  id: const ModuleId('failure'),
                  registerAgent: (_) => throw StateError('failed'))
            ]),
        failure(ModuleCompositionFailure.invalidModuleContribution));
    expect(
        () => ui.registerUiContribution(const ModuleUiContribution(
            key: 'late', slot: ModuleUiSlot.workspaceAction)),
        failure(ModuleCompositionFailure.invalidModuleContribution));
  });
  test('immutable result, nested schema, and source-list defensive copies', () {
    final dependencies = <ModuleId>[];
    final descriptor = ModuleContribution(
        id: const ModuleId('empty'), requiredModuleIds: dependencies);
    dependencies.add(const ModuleId('missing'));
    final result = composer.compose([descriptor, fixtureModule()]);
    expect(() => result.moduleOrder.clear(), throwsUnsupportedError);
    expect(
        () => result.capabilities.definitions.clear(), throwsUnsupportedError);
    expect(
        () => result.agentSurface.projections.clear(), throwsUnsupportedError);
    expect(() => result.mcpSurface.clear(), throwsUnsupportedError);
    expect(() => result.uiContributions.clear(), throwsUnsupportedError);
    expect(() => result.agentSurface.projections.single.guidance.clear(),
        throwsUnsupportedError);
    final schema =
        result.agentSurface.projections.single.definition.inputSchema;
    expect(() => (schema['properties'] as Map).clear(), throwsUnsupportedError);
  });
  test('fixture added/removed solely by explicit list has all/zero surfaces',
      () {
    final enabled = composer.compose([fixtureModule()]);
    expect(enabled.capabilities.definitions, hasLength(1));
    expect(enabled.agentSurface.guidance(fileAccess: false).single.text,
        contains('fixture'));
    expect(enabled.mcpSurface, hasLength(1));
    expect(enabled.uiContributions.single.slot, ModuleUiSlot.assistantArtifact);
    final disabled = composer.compose([]);
    expect(disabled.capabilities.definitions, isEmpty);
    expect(disabled.agentSurface.projections, isEmpty);
    expect(disabled.agentSurface.guidance(fileAccess: true), isEmpty);
    expect(disabled.mcpSurface, isEmpty);
    expect(disabled.uiContributions, isEmpty);
  });
}
