import 'dart:async';
import '../application/capabilities/capability.dart';
import '../application/external/external_authorization.dart';
import '../application/external/external_file_read.dart';
import '../application/external/external_generated_stage.dart';
import '../application/external/external_read_context.dart';
import '../application/external/external_question_read.dart';
import '../application/external/external_trust_coordinator.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/first_party_external_access.dart';
import '../application/external/local_authorization_service.dart';
import '../application/external/local_host_dispatch.dart';
import '../application/generated_question/generated_local_authority.dart';
import '../application/generated_question/generated_question_service.dart';
import '../application/parsed_artifacts/parsed_artifact_ports.dart';
import '../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../application/retrieval/retrieval_ports.dart';
import '../mcp/vnext_mcp_composition_root.dart';
import '../mcp/vnext_mcp_server.dart';

final class _AppPort implements VnextMcpPort {
  const _AppPort(this.inner, this.owner);
  final VnextMcpPort inner;
  final McpVnextAppIntegration owner;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
          {required Stream<void> cancelled,
          required bool Function() available}) =>
      inner.call(tool, arguments,
          cancelled: cancelled,
          available: () => owner.controls.isCurrent && available());
  @override
  Future<void> close() => owner.close();
}

/// One dormant App composition over the existing production owners. Construction
/// installs no TrustCore, credential adapter, Host, MCP server or transport.
final class McpVnextAppIntegration {
  McpVnextAppIntegration(
      {required LocalAuthorizationService policy,
      required this.localAuthority,
      required this.authorization,
      required this.proposals,
      required this.targets,
      required this.questions,
      required this.files,
      required this.artifacts,
      required this.artifactMetadata,
      required this.index,
      required this.chunker,
      required this.mintId,
      required bool Function() compositionIsCurrent})
      : _isCurrent = compositionIsCurrent {
    controls = FirstPartyExternalAccess(
        policy: policy, compositionIsCurrent: compositionIsCurrent);
  }
  final ExternalTargetReadPort targets;
  final ExternalQuestionReadPort questions;
  final ExternalFileReadPort files;
  final GeneratedLocalAuthorityFactory localAuthority;
  final ExternalAuthorizationRepository authorization;
  final ExternalGeneratedStagePort proposals;
  final ParsedArtifactLifecyclePort artifacts;
  final ParsedArtifactRepositoryPort artifactMetadata;
  final RetrievalIndexPort index;
  final RetrievalChunkerPort chunker;
  final String Function() mintId;
  final bool Function() _isCurrent;
  late final FirstPartyExternalAccess controls;
  Future<VnextMcpPort>? _attaching;

  /// Explicit trusted entry for an already admitted App/Bridge composition.
  /// No startup/UI calls it while production transport admission is blocked.
  /// The caller supplies the SAME P0 authority used for pairing/credentials.
  Future<VnextMcpPort> attachTrusted(
      {required ExternalTrustCore trust,
      required LocalHostReadinessPort readiness,
      required Object? Function() authenticationAttempt}) {
    if (_attaching != null || !controls.isCurrent) {
      throw StateError('External composition unavailable');
    }
    return _attaching = _attach(trust, readiness, authenticationAttempt);
  }

  Future<VnextMcpPort> _attach(ExternalTrustCore trust,
      LocalHostReadinessPort readiness, Object? Function() attempt) async {
    final owner = await localAuthority.openSession();
    final management = ExternalAuthorizationManagement(
        repository: authorization,
        compositionIsCurrent: () =>
            controls.isCurrent && owner.isCurrent && _isCurrent(),
        mintProfileId: mintId,
        clock: trust.clock.now);
    final stages = ExternalGeneratedStageService(
        trust: trust,
        management: management,
        localOwner: owner,
        persistence: proposals,
        admission: GeneratedQuestionAdmission(idFactory: mintId));
    final reads = ExternalReadContextService(
        admission: stages.runtimeAdmission,
        targets: targets,
        questions: questions,
        files: ExternalFileReader(
            authorization: files,
            source: ExternalVerifiedArtifactSource(
                lifecycle: artifacts, metadata: artifactMetadata),
            index: index,
            chunker: chunker));
    final coordinator = ExternalTrustCoordinator.offline(
        gateway: ExternalCapabilityGateway(stages: stages, reads: reads),
        management: management,
        readiness: readiness,
        compositionIsCurrent: () =>
            controls.isCurrent && owner.isCurrent && _isCurrent());
    final port = VnextMcpAppComposition(
        host: coordinator.host,
        reads: reads,
        stages: stages,
        authentication:
            VnextMcpSessionAuthentication(controls.authenticatedSession),
        approvedTargets: const []);
    Future<void> shutdown() async {
      await Future.wait([coordinator.shutdown(), port.close()]);
      reads.close();
      stages.close();
      management.invalidate();
      owner.close();
    }

    try {
      controls.installTrusted(FirstPartyExternalBinding(
          management: management,
          coordinator: coordinator,
          trust: trust,
          stages: stages,
          localOwner: owner,
          authenticationAttempt: attempt,
          publishApprovals: port.replaceApprovedTargets,
          shutdown: shutdown));
      await coordinator.startOffline();
      return _AppPort(port, this);
    } catch (_) {
      await shutdown();
      rethrow;
    }
  }

  /// Await before replacement; production database close uses this same barrier.
  Future<void> close() async {
    final closing = controls.shutdown();
    try {
      await _attaching;
    } catch (_) {/* Failed attachment already drains. */}
    await closing;
  }
}
