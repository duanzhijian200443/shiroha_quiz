// Test-only isolated process. No Host/transport, real credential or persistence.
import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';

final class _Clock implements ExternalClock {
  @override
  DateTime now() => DateTime.utc(2026);
}

final class _Credentials implements ExternalCredentialPort {
  final key = Object();
  @override
  AuthenticatedPeerEvidence? authenticate(Object attempt) =>
      identical(attempt, key)
          ? const AuthenticatedPeerEvidence('synthetic')
          : null;
  @override
  PairingProof? provePossession(Object attempt) => identical(attempt, key)
      ? const PairingProof('synthetic', 'synthetic')
      : null;
}

final class _Repository
    implements ExternalAuthorizationRepository, ExternalTargetReadPort {
  _Repository(String id) {
    record = ExternalAuthorizationRecord(
        ExternalClientProfile(
            clientProfileId: id,
            displayName: 'Synthetic',
            adapter: 'bridge',
            protocol: 'tcp-v1',
            createdAtUtcMs: 0,
            grantRevision: 2),
        ExternalGrant(
            profileId: id,
            revision: 2,
            updatedAtUtcMs: 0,
            policy: ExternalGrantPolicy(permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ], scopes: [
              ExternalGrantScope(
                  kind: ExternalTargetKind.bank, targetId: 'bank')
            ], categories: [
              ExternalContentCategory.questionContent,
              ExternalContentCategory.proposalMetadata
            ])));
  }
  late final ExternalAuthorizationRecord record;
  @override
  Future<ExternalAuthorizationRecord> read(String id) async {
    if (id != record.profile.clientProfileId) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return record;
  }

  @override
  Future<ExternalReadSnapshot> query(ExternalRuntimeAccess access,
      int? revision, void Function() check) async {
    check();
    access.validate();
    await read(access.profileId);
    if (revision != null && revision != 2) {
      externalReadFail(ExternalReadFailure.stale);
    }
    check();
    return ExternalReadSnapshot(
        record.grant!, [const ExternalReadTarget('bank', null, 'folder')]);
  }

  @override
  Future<ExternalAuthorizationRecord> create(
          ExternalClientProfile profile, void Function() validateManagement) =>
      throw UnsupportedError('test-only');
  @override
  Future<ExternalAuthorizationRecord> change(
          String profileId,
          int revision,
          ExternalGrantPolicy? policy,
          int nowUtcMs,
          bool revokeProfile,
          void Function() validateManagement) =>
      throw UnsupportedError('test-only');
  @override
  Future<ExternalGrant> currentGrant(
          String profileId,
          int revision,
          CapabilityPermission permission,
          ExternalGrantScope scope,
          ExternalContentCategory category,
          String recipientProfileId) =>
      throw UnsupportedError('test-only');
}

Future<void> main() async {
  final raw =
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  final request = jsonDecode(raw) as Map<String, dynamic>;
  // The parent fixture supplies its synthetic local baseline, never a live RPC.
  final profileId = request['profileId'] as String;
  final token = request['context'] as String;
  final repository = _Repository(profileId);
  final clock = _Clock();
  final management = ExternalAuthorizationManagement(
      repository: repository,
      compositionIsCurrent: () => true,
      mintProfileId: () => profileId,
      clock: clock.now);
  final credentials = _Credentials();
  final trust = ExternalTrustCore(
      credentials: credentials, clock: clock, mintProfileId: () => profileId);
  final admission = ExternalRuntimeAdmission(
      trust: trust, management: management, compositionIsCurrent: () => true);
  final principal = trust.createProfile();
  await admission.bindIdentity(
      await management.selectProfile(profileId), principal);
  trust.requestPairing(principal,
      requestId: 'synthetic', credentialIdentity: 'synthetic');
  trust.approvePairing(principal);
  trust.completePairing(principal, credentials.key);
  trust.enable(principal, const Duration(minutes: 30));
  final session = trust.openSession(trust.authenticate(credentials.key));
  final service =
      ExternalReadContextService(admission: admission, targets: repository);
  try {
    final ref =
        (await service.listTargets(session: session)).items.single.targetRef;
    final own = await service.createContext(session: session, targetRef: ref);
    if (await service.contextStatus(session: session, context: own) !=
            ExternalReadValidity.authorized ||
        await service.contextStatus(session: session, context: token) !=
            ExternalReadValidity.invalid) {
      exitCode = 1;
      return;
    }
    stdout.write('invalid\n');
  } finally {
    service.close();
    admission.close();
  }
}
