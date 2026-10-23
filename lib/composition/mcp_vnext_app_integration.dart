import 'dart:async';
import '../application/capabilities/capability.dart';
import '../application/external/external_authorization.dart';
import '../application/external/external_credential_association.dart';
import '../application/external/external_credential_boundary.dart';
import '../application/external/first_party_external_credentials.dart';
import '../application/external/external_file_read.dart';
import '../application/external/external_generated_stage.dart';
import '../application/external/external_read_context.dart';
import '../application/external/external_question_read.dart';
import '../application/external/external_trust_coordinator.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/first_party_external_access.dart';
import '../application/external/first_party_stage_approval.dart';
import '../application/external/local_authorization_service.dart';
import '../application/external/local_host_dispatch.dart';
import '../application/generated_question/generated_local_authority.dart';
import '../application/generated_question/generated_question_service.dart';
import '../application/parsed_artifacts/parsed_artifact_ports.dart';
import '../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../application/retrieval/retrieval_ports.dart';
import '../mcp/vnext_mcp_composition_root.dart';
import '../mcp/vnext_mcp_server.dart';

/// Inactive transport custody for this App's exact P8/P10 composition.
/// Factories construct only; start performs explicitly supplied transport work.
abstract interface class McpVnextAppTransport {
  VnextMcpAppComposition get binding;
  Future<void> start();
  Future<void> close();
}

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

  /// Read-only custody check; an existing attachment cannot be transferred.
  bool get hasAttachment => _attaching != null;

  /// Explicit trusted entry for an already admitted App/Bridge composition.
  /// No startup/UI calls it while production transport admission is blocked.
  /// The caller supplies the SAME P0 authority used for pairing/credentials.
  Future<VnextMcpPort> attachTrusted(
      {required ExternalTrustCore trust,
      required LocalHostReadinessPort readiness,
      bool enableStageApprovalWait = false,
      required Object? Function() authenticationAttempt}) {
    if (_attaching != null || !controls.isCurrent) {
      throw StateError('External composition unavailable');
    }
    return _attaching = _attach((_) => trust, readiness, authenticationAttempt,
        enableStageApprovalWait: enableStageApprovalWait);
  }

  /// Composes an inactive credential boundary against this App's management.
  ///
  /// Startup never calls this entry. All
  /// protected stores, verification and channel ownership require independent
  /// admission; this method opens no Windows object, listener or credential.
  Future<VnextMcpPort> attachCredentials({
    required ExternalCredentialAssociationStore associations,
    required ExternalCredentialVerificationPort Function(
            ExternalAuthorizationManagement management)
        verification,
    required ExternalClock clock,
    required String installationId,
    required LocalHostReadinessPort readiness,
    required FirstPartyCredentialServices Function(
            ExternalCredentialBoundary boundary)
        services,
    Duration Function()? monotonicNow,
    bool enableStageApprovalWait = false,
    McpVnextAppTransport Function(ExternalTrustCoordinator coordinator,
            VnextMcpAppComposition binding)?
        transport,
    Duration pairingRequestLifetime =
        ExternalCredentialBoundary.evidenceLifetime,
  }) {
    if (_attaching != null || !controls.isCurrent) {
      throw StateError('External composition unavailable');
    }
    late ExternalCredentialBoundary boundary;
    return _attaching = _attach(
        (management) {
          boundary = ExternalCredentialBoundary.offline(
              associations: associations,
              verification: verification(management),
              management: management,
              clock: clock,
              installationId: installationId,
              compositionIsCurrent: () => controls.isCurrent && _isCurrent(),
              monotonicNow: monotonicNow,
              pairingRequestLifetime: pairingRequestLifetime);
          return ExternalTrustCore(
              credentials: boundary, clock: clock, mintProfileId: mintId);
        },
        readiness,
        () => null,
        enableStageApprovalWait: enableStageApprovalWait,
        transport: transport,
        credentials: (coordinator, trust) {
          boundary.attach(coordinator, trust);
          final result = services(boundary);
          if (!identical(result.boundary, boundary)) {
            throw StateError('External composition unavailable');
          }
          return result;
        });
  }

  Future<VnextMcpPort> _attach(
      ExternalTrustCore Function(ExternalAuthorizationManagement) createTrust,
      LocalHostReadinessPort readiness,
      Object? Function() attempt,
      {FirstPartyCredentialServices Function(
              ExternalTrustCoordinator, ExternalTrustCore)?
          credentials,
      McpVnextAppTransport Function(ExternalTrustCoordinator coordinator,
              VnextMcpAppComposition binding)?
          transport,
      bool enableStageApprovalWait = false}) async {
    final owner = await localAuthority.openSession();
    late ExternalTrustCore trust;
    final management = ExternalAuthorizationManagement(
        repository: authorization,
        compositionIsCurrent: () =>
            controls.isCurrent && owner.isCurrent && _isCurrent(),
        mintProfileId: mintId,
        clock: () => trust.clock.now());
    try {
      trust = createTrust(management);
    } catch (_) {
      management.invalidate();
      owner.close();
      rethrow;
    }
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
    final stageApproval = enableStageApprovalWait
        ? FirstPartyStageApproval(
            host: coordinator.host,
            stages: stages,
            localOwner: owner,
            compositionIsCurrent: () => controls.isCurrent && _isCurrent())
        : null;
    final port = VnextMcpAppComposition(
        host: coordinator.host,
        reads: reads,
        stages: stages,
        stageApproval: stageApproval,
        authentication:
            VnextMcpSessionAuthentication(controls.authenticatedSession),
        approvedTargets: const []);
    FirstPartyCredentialServices? credentialServices;
    McpVnextAppTransport? attachedTransport;
    Future<void>? closing;
    Future<void> shutdown() => closing ??= () async {
          // Cancels human input synchronously before any owning drain can wait on it.
          final approvalClosing = stageApproval?.close();
          final transportClosing = attachedTransport?.close();
          // Close evidence first; P15/P27 drain the same P12/P8 owners before
          // advancing generation. No Windows owner may be released before drain.
          if (trust.credentials
              case final ExternalCredentialBoundary boundary) {
            final closing = boundary.shutdown();
            await Future.wait([
              closing,
              if (transportClosing != null) transportClosing,
              if (credentialServices != null)
                credentialServices.pairing.close(),
            ]);
            await credentialServices?.close();
          } else {
            await Future.wait([
              coordinator.shutdown(),
              if (transportClosing != null) transportClosing,
            ]);
          }
          await port.close();
          await approvalClosing;
          reads.close();
          stages.close();
          management.invalidate();
          owner.close();
        }();

    try {
      credentialServices = credentials?.call(coordinator, trust);
      controls.installTrusted(FirstPartyExternalBinding(
          management: management,
          coordinator: coordinator,
          trust: trust,
          stages: stages,
          localOwner: owner,
          authenticationAttempt: attempt,
          credentials: credentialServices,
          stageApproval: stageApproval,
          publishApprovals: port.replaceApprovedTargets,
          shutdown: shutdown));
      await coordinator.startOffline();
      if (!controls.isCurrent) {
        throw StateError('External composition unavailable');
      }
      final candidate = transport?.call(coordinator, port);
      if (candidate != null) {
        if (!identical(candidate.binding, port)) {
          throw StateError('External composition unavailable');
        }
        attachedTransport = candidate;
        await candidate.start();
      }
      if (!controls.isCurrent) {
        throw StateError('External composition unavailable');
      }
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
