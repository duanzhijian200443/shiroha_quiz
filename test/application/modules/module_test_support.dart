import 'dart:convert';
import 'package:shiroha_quiz/application/agent/agent_provider.dart';
import 'package:shiroha_quiz/application/agent/agent_surface.dart';
import 'package:shiroha_quiz/application/agent/agent_tool_projection.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';

const fixtureId = CapabilityId<void, String>('fixture_read');
CapabilityDefinition<void, String> fixtureCapability(
        {CapabilityPermission permission = CapabilityPermission.read,
        void Function()? onInvoke}) =>
    CapabilityDefinition(
        id: fixtureId,
        permission: permission,
        permittedEffects: const [CapabilityEffect.none],
        semantics: CapabilityExecutionSemantics.repeatableRead,
        handler: CapabilityHandler((input, context, evidence) async {
          onInvoke?.call();
          return CapabilityEvidence.completed(
              'fixture result', CapabilityEffect.none);
        }));

RegisteredAgentProjection fixtureProjection(CapabilityExecutor executor,
        {String key = 'fixture_tool',
        CapabilityId<void, String> id = fixtureId,
        CapabilityPermission permission = CapabilityPermission.read}) =>
    RegisteredAgentProjection(
      capabilityId: id,
      permission: permission,
      definition: AgentFunctionToolDefinition(
          name: key,
          description: 'Synthetic fixture read.',
          inputSchema: const {
            'type': 'object',
            'properties': <String, Object?>{}
          }),
      guidance: const [
        AgentPromptGuidance(
            AgentGuidanceSlot.permission, '- Synthetic fixture guidance.\n')
      ],
      dispatch: (call) async {
        final result = await executor.execute(id, null, call.context);
        return AgentToolDispatchResult(
            json: jsonEncode(
                {'ok': result.failure == null, 'result': result.output}),
            receipt: result.receipt);
      },
    );

ModuleContribution fixtureModule(
        {String name = 'fixture', Iterable<ModuleId> requires = const []}) =>
    ModuleContribution(
      id: ModuleId(name),
      requiredModuleIds: requires,
      registerCapabilities: (r) => r.registerCapability(fixtureCapability()),
      registerAgent: (r) => r.registerAgentProjection(fixtureProjection),
      registerMcp: (r) => r.registerMcpProjection(const ModuleMcpProjection(
          key: 'fixture_mcp', capabilityId: fixtureId)),
      registerUi: (r) => r.registerUiContribution(const ModuleUiContribution(
          key: 'fixture_artifact', slot: ModuleUiSlot.assistantArtifact)),
    );
