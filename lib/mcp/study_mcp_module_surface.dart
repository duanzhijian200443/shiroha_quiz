import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/study_query/study_capabilities.dart';
import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'study_mcp_adapter.dart';
import 'study_mcp_server.dart';

/// v0 is either the accepted six Study projections or absent. Its SDK schemas,
/// annotations and wire conversion remain owned by StudyMcpServer.
StudyMcpServer? buildStudyMcpServerFromComposition(
    ModuleComposition composition, StudyQueryService service) {
  if (composition.mcpSurface.isEmpty) return null;
  final projections = composition.mcpSurface;
  if (projections.length != StudyCapabilities.ids.length ||
      StudyCapabilities.ids.any((id) =>
          !projections.any((p) => p.key == id.value && p.capabilityId == id))) {
    throw const ModuleCompositionException(
        ModuleCompositionFailure.invalidModuleContribution);
  }
  return StudyMcpServer(
      adapter: StudyMcpAdapter(
          service: service,
          executor: CapabilityExecutor(composition.capabilities)));
}
