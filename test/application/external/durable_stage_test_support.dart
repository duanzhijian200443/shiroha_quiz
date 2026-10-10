import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import '../generated_question/generated_test_support.dart';

export '../generated_question/generated_test_support.dart';

final class StageClock implements ExternalClock {
  DateTime current = DateTime.utc(2026);
  @override
  DateTime now() => current;
}

/// Object possession is checked by the App-owned test credential port. Claimed
/// Profile strings, clientInfo or arbitrary evidence cannot authenticate.
final class StageCredentials implements ExternalCredentialPort {
  final authentication = Object(), proof = Object();
  @override
  AuthenticatedPeerEvidence? authenticate(Object authenticationAttempt) =>
      identical(authenticationAttempt, authentication)
          ? const AuthenticatedPeerEvidence('synthetic-credential')
          : null;
  @override
  PairingProof? provePossession(Object proofAttempt) =>
      identical(proofAttempt, proof)
          ? const PairingProof('synthetic-pairing', 'synthetic-credential')
          : null;
}

final class DurableStageHarness {
  final h = GeneratedHarness();
  final clock = StageClock();
  late ExternalAuthorizationManagement management;
  late SqliteExternalAuthorizationRepository authorization;
  late ExternalProfileReference profile;
  late ExternalTrustCore trust;
  late ExternalPrincipal principal;
  late StageCredentials credentials;
  late ExternalSession session;
  late GeneratedLocalAuthorityFactory localFactory;
  late GeneratedLocalAuthoritySession localSession;
  late GeneratedProposalRepository repository;
  late ExternalGeneratedStageService service;
  Future<void> Function(ExternalStageCheckpoint)? checkpoint;
  int maxInFlight = 16;
  String nextProfile = '';
  ExternalGrantScope get bank => ExternalGrantScope(
      kind: ExternalTargetKind.bank,
      targetId: h.target.bankName,
      projectId: h.target.projectId);
  ExternalGrantPolicy policy({
    Iterable<CapabilityPermission> permissions = const [
      CapabilityPermission.stage
    ],
    Iterable<ExternalGrantScope>? scopes,
    Iterable<ExternalContentCategory> categories = const [
      ExternalContentCategory.questionContent,
      ExternalContentCategory.proposalMetadata
    ],
  }) =>
      ExternalGrantPolicy(
          permissions: permissions,
          scopes: scopes ?? [bank],
          categories: categories);

  Future<void> open() async {
    await h.open();
    await compose();
    profile = await management.createProfile(
        displayName: 'Synthetic client', adapter: 'bridge', protocol: 'tcp-v1');
    await management.replaceGrant(profile, 0, policy());
    await authenticate();
  }

  Future<void> compose() async {
    authorization =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    management = ExternalAuthorizationManagement(
        repository: authorization,
        compositionIsCurrent: () => true,
        mintProfileId: const Uuid().v4,
        clock: clock.now);
    final local = GeneratedLocalAuthorityRepository(databaseHelper: h.helper);
    localFactory = GeneratedLocalAuthorityFactory(
        identity: local, proposals: local, compositionIsCurrent: () => true);
    localSession = await localFactory.openSession();
    credentials = StageCredentials();
    trust = ExternalTrustCore(
        credentials: credentials,
        clock: clock,
        mintProfileId: () => nextProfile);
    repository = GeneratedProposalRepository(
        databaseHelper: h.helper,
        externalStageCheckpoint: (point) async => checkpoint?.call(point));
    service = ExternalGeneratedStageService(
        trust: trust,
        management: management,
        localOwner: localSession,
        persistence: repository,
        admission: GeneratedQuestionAdmission(idFactory: const Uuid().v4),
        maxInFlight: maxInFlight);
  }

  Future<void> authenticate() async {
    nextProfile =
        profile.profileId; // App selection from opaque durable reference
    principal = trust.createProfile();
    await service.bindIdentity(profile, principal);
    trust.requestPairing(principal,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    trust.approvePairing(principal);
    trust.completePairing(principal, credentials.proof);
    trust.enable(principal, const Duration(minutes: 30));
    session = trust.openSession(trust.authenticate(credentials.authentication));
  }

  ExternalCallControl control() => ExternalCallControl(clock: clock);
  Future<ExternalStageContext> context(
          {List<GeneratedEvidence> evidence = const []}) =>
      service.approveTarget(session, h.target, evidence);
  Future<ExternalStageResult> stage(
          {String key = 'external-key',
          ExternalStageContext? approved,
          List<Map<String, Object?>>? items,
          ExternalCallControl? call,
          bool Function()? responseAvailable,
          String? externalRequestId}) async =>
      service.stage(
          session: session,
          context: approved ?? await context(),
          submissionJson: submission(key: key, items: items),
          control: call ?? control(),
          responseAvailable: responseAvailable ?? () => true,
          externalRequestId: externalRequestId);
  Future<ExternalStageResult> reconcile(String key,
          {ExternalSession? authenticated}) =>
      service.reconcile(
          session: authenticated ?? session,
          submissionKey: key,
          control: control(),
          responseAvailable: () => true);
  Future<void> reopen() async {
    final id = profile.profileId;
    service.close();
    await service.whenIdle;
    localSession.close();
    localFactory.invalidate();
    management.invalidate();
    trust.restart();
    await h.reopen(); // actual file close and reopen, not another memory DB
    await compose();
    profile = await management.selectProfile(id);
    await authenticate();
  }

  Future<void> close() async {
    service.close();
    await service.whenIdle;
    localSession.close();
    await h.close();
  }
}
