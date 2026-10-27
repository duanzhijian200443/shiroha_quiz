import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_file_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_coordinator.dart';
import 'package:shiroha_quiz/application/external/local_authorization_service.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'durable_stage_test_support.dart' show StageClock;
import 'local_authorization_test_support.dart';
import 'local_host_test_support.dart' show OfflineReadiness;

export 'local_authorization_test_support.dart';

/// Synthetic object possession, deliberately confined to test composition.
final class OfflineTrustCredentials implements ExternalCredentialPort {
  final first = Object(), second = Object();
  String? identity(Object attempt) => identical(attempt, first)
      ? 'first'
      : identical(attempt, second)
          ? 'second'
          : null;
  @override
  AuthenticatedPeerEvidence? authenticate(Object attempt) {
    final id = identity(attempt);
    return id == null ? null : AuthenticatedPeerEvidence(id);
  }

  @override
  PairingProof? provePossession(Object attempt) {
    final id = identity(attempt);
    return id == null ? null : PairingProof(id, id);
  }
}

/// Wraps the actual SQLite owner solely to control local read settlement.
final class TrustManagementBarrier implements ExternalAuthorizationRepository {
  TrustManagementBarrier(this.inner);
  final ExternalAuthorizationRepository inner;
  Completer<void>? reached, resume;
  ExternalAuthorizationRecord Function(ExternalAuthorizationRecord)? transform;
  Future<void> Function(ExternalAuthorizationRecord)? afterRead;
  @override
  Future<ExternalAuthorizationRecord> read(String profileId) async {
    final record = await inner.read(profileId);
    if (afterRead != null) await afterRead!(record);
    if (reached != null && !reached!.isCompleted) reached!.complete();
    await resume?.future;
    return transform?.call(record) ?? record;
  }

  @override
  Future<ExternalAuthorizationRecord> create(
          ExternalClientProfile profile, void Function() validate) =>
      inner.create(profile, validate);
  @override
  Future<ExternalAuthorizationRecord> change(
          String profileId,
          int revision,
          ExternalGrantPolicy? policy,
          int time,
          bool revoke,
          void Function() validate) =>
      inner.change(profileId, revision, policy, time, revoke, validate);
  @override
  Future<ExternalGrant> currentGrant(
          String profileId,
          int revision,
          CapabilityPermission permission,
          ExternalGrantScope scope,
          ExternalContentCategory category,
          String recipient) =>
      inner.currentGrant(
          profileId, revision, permission, scope, category, recipient);
}

/// Reuses P11 temporary SQLite/query fixtures and P3/P4/P8 ports. No listener.
final class OfflineTrustHarness {
  final local = LocalAuthorizationHarness();
  // P11's local policy clock uses wall time. This fixed later synthetic date
  // keeps management revocations monotonic without timing-dependent sleeps.
  final clock = StageClock()..current = DateTime.utc(2030);
  final credentials = OfflineTrustCredentials();
  late LocalAuthorizationView view;
  late TrustManagementBarrier barrier;
  late ExternalAuthorizationManagement management;
  late ExternalTrustCore trust;
  late GeneratedLocalAuthorityFactory localFactory;
  late GeneratedLocalAuthoritySession localSession;
  late ExternalGeneratedStageService stages;
  late ExternalReadContextService reads;
  late ExternalCapabilityGateway gateway;
  late ExternalTrustCoordinator coordinator;
  late ExternalProfileReference reference;
  late ExternalTrustProfile profile;
  bool current = true;
  bool coordinatorCurrent = true;
  Future<void> Function(ExternalStageCheckpoint)? checkpoint;
  Future<ExternalFileReader?> Function()? fileReader;
  Future<void> open() async {
    await local.open();
    view = local.service.openView();
    final created = await view.create('Offline synthetic');
    await compose();
    reference = await management.selectProfile(created.profileId);
    profile = await coordinator.registerProfile(reference);
  }

  Future<void> compose(
      {ExternalCredentialPort? credentialPort,
      ExternalCredentialPort Function(ExternalAuthorizationManagement)?
          credentialFactory}) async {
    final database = local.h.db;
    barrier = TrustManagementBarrier(local.repository);
    management = ExternalAuthorizationManagement(
        repository: barrier,
        compositionIsCurrent: () => current && database.isOpen,
        mintProfileId: const Uuid().v4,
        clock: clock.now);
    trust = ExternalTrustCore(
        credentials: credentialFactory?.call(management) ??
            credentialPort ??
            credentials,
        clock: clock,
        mintProfileId: const Uuid().v4);
    final authority =
        GeneratedLocalAuthorityRepository(databaseHelper: local.h.helper);
    localFactory = GeneratedLocalAuthorityFactory(
        identity: authority,
        proposals: authority,
        compositionIsCurrent: () => current && database.isOpen);
    localSession = await localFactory.openSession();
    stages = ExternalGeneratedStageService(
        trust: trust,
        management: management,
        localOwner: localSession,
        persistence: GeneratedProposalRepository(
            databaseHelper: local.h.helper,
            externalStageCheckpoint: (point) async => checkpoint?.call(point)),
        admission: GeneratedQuestionAdmission(idFactory: const Uuid().v4));
    reads = ExternalReadContextService(
        admission: stages.runtimeAdmission,
        files: await fileReader?.call(),
        targets:
            SqliteExternalTargetReadRepository(databaseHelper: local.h.helper),
        questions: SqliteExternalQuestionReadRepository(
            databaseHelper: local.h.helper));
    gateway = ExternalCapabilityGateway(stages: stages, reads: reads);
    coordinator = ExternalTrustCoordinator.offline(
        gateway: gateway,
        management: management,
        readiness: OfflineReadiness(() async => database.rawQuery('SELECT 1')),
        compositionIsCurrent: () =>
            coordinatorCurrent && current && database.isOpen);
  }

  Future<ExternalProfileReference> secondProfile() async => management
      .selectProfile((await view.create('Second synthetic')).profileId);

  Future<void> save({bool scopes = true, bool egress = true}) async {
    final localRef = await view.select(reference.profileId);
    final revision = (await view.read(localRef)).profile.grantRevision;
    await view.save(localRef, revision,
        permissions: [CapabilityPermission.read, CapabilityPermission.stage],
        targets: scopes
            ? (await view.targets()).where(
                (t) => t.scope.targetId == 'bank' && t.scope.projectId == null)
            : [],
        categories: egress ? ExternalContentCategory.values : []);
  }

  Future<void> pair({ExternalTrustProfile? selected, Object? key}) async {
    selected ??= profile;
    key ??= credentials.first;
    final id = credentials.identity(key)!;
    await coordinator.requestPairing(selected,
        requestId: id, credentialIdentity: id);
    await coordinator.approvePairing(selected);
    await coordinator.completePairing(selected, key);
  }

  Future<void> enable({ExternalTrustProfile? selected}) =>
      coordinator.enable(selected ?? profile, const Duration(minutes: 10));

  Future<ExternalSession> session(
          {ExternalTrustProfile? selected, Object? key}) =>
      coordinator.openSession(selected ?? profile, key ?? credentials.first);

  Future<void> restart() async {
    final id = reference.profileId;
    await coordinator.shutdown();
    management.invalidate();
    localSession.close();
    localFactory.invalidate();
    view.close();
    local.service.invalidate();
    await local.h.reopen();
    local.compose();
    view = local.service.openView();
    await compose();
    reference = await management.selectProfile(id);
    profile = await coordinator.registerProfile(reference);
  }

  Future<void> close() async {
    if (barrier.resume != null && !barrier.resume!.isCompleted) {
      barrier.resume!.complete();
    }
    await coordinator.shutdown();
    management.invalidate();
    localSession.close();
    localFactory.invalidate();
    view.close();
    await local.close();
  }
}
