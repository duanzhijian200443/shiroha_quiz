import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'external_trust_test_support.dart';
import 'local_host_test_support.dart'
    show flushHostMicrotasks, expectNotStarted;

Matcher denied() => throwsA(isA<ExternalAuthException>().having(
    (e) => e.failure, 'safe failure', ExternalAuthFailure.unauthorized));
Matcher coreFailure(ExternalFailure failure) => throwsA(
    isA<ExternalCoreException>().having((e) => e.failure, 'failure', failure));

void main() {
  initializeGeneratedTests();
  late OfflineTrustHarness f;
  setUp(() async {
    f = OfflineTrustHarness();
    await f.open();
  });
  tearDown(() => f.close());

  Future<(ExternalSession, LocalHostSessionEntry)> ready() async {
    await f.save();
    await f.pair();
    await f.enable();
    await f.coordinator.startOffline();
    final session = await f.session();
    return (session, await f.coordinator.host.bindSession(session));
  }

  test('P11 Profile and saved Grant supply neither pairing nor usable Session',
      () async {
    await f.save();
    expect(f.trust.snapshot(f.profile.principal).state, PairingState.unpaired);
    await expectLater(
        f.session(), coreFailure(ExternalFailure.authenticationRejected));
    for (final attempt in [
      f.reference.profileId,
      {'profileId': f.reference.profileId, 'trusted': true},
      PairingProof('first', 'first'),
      AuthenticatedPeerEvidence('first'),
    ]) {
      await expectLater(f.coordinator.openSession(f.profile, attempt),
          coreFailure(ExternalFailure.authenticationRejected));
    }
  });

  test('parallel/repeated opaque selection returns one identical Principal',
      () async {
    final selected = await f.management.selectProfile(f.reference.profileId);
    final bindings = await Future.wait([
      f.coordinator.registerProfile(selected),
      f.coordinator.registerProfile(f.reference),
    ]);
    for (final binding in bindings) {
      expect(identical(binding.principal, f.profile.principal), isTrue);
    }
    expect(bindings.first.principal.profileId, f.reference.profileId);
    await f.pair(selected: bindings.first);
    await f.enable(selected: bindings.last);
    expect((await f.session()).principal, same(f.profile.principal));
  });

  test(
      'P4 rejects mismatched Principal/Profile and cross-Profile Grant records',
      () async {
    await expectLater(
        f.stages.runtimeAdmission
            .bindIdentity(f.reference, f.trust.createProfile()),
        denied());
    await f.save();
    final second = await f.secondProfile();
    final record = await f.management.read(f.reference);
    f.barrier.transform = (r) => ExternalAuthorizationRecord(
        r.profile,
        ExternalGrant(
            profileId: second.profileId,
            revision: r.profile.grantRevision,
            updatedAtUtcMs: 0,
            policy: record.grant!.policy));
    await expectLater(f.coordinator.registerProfile(f.reference),
        coreFailure(ExternalFailure.authenticationRejected));
    await expectLater(
        f.stages.runtimeAdmission
            .bindIdentity(f.reference, f.profile.principal),
        denied());
    f.barrier.transform = null;
    await f.pair();
    await f.enable();
    final session = await f.session();
    f.barrier.transform = (r) => ExternalAuthorizationRecord(
        record.profile,
        ExternalGrant(
            profileId: second.profileId,
            revision: 1,
            updatedAtUtcMs: 0,
            policy: record.grant!.policy));
    await expectLater(f.stages.runtimeAdmission.admit(session), denied());
  });

  test('missing, revoked and foreign-management Profile references reject',
      () async {
    final foreign = await f.view.select(f.reference.profileId);
    await expectLater(f.coordinator.registerProfile(foreign), denied());
    final absent = await f.secondProfile();
    await f.local.h.db.delete('external_client_profiles',
        where: 'profile_id = ?', whereArgs: [absent.profileId]);
    await expectLater(f.coordinator.registerProfile(absent),
        throwsA(isA<ExternalAuthException>()));
    await f.management.revokeProfile(f.reference, 0);
    await expectLater(f.coordinator.registerProfile(f.reference),
        coreFailure(ExternalFailure.authenticationRejected));
    await expectLater(f.enable(), denied());
  });

  test('local approval and failed proof never reach paired state', () async {
    await f.save();
    await f.coordinator.requestPairing(f.profile,
        requestId: 'first', credentialIdentity: 'first');
    expect(f.trust.snapshot(f.profile.principal).state,
        PairingState.requestPending);
    await f.coordinator.approvePairing(f.profile);
    for (final proof in [
      Object(),
      f.credentials.second,
      PairingProof('first', 'first')
    ]) {
      await expectLater(f.coordinator.completePairing(f.profile, proof),
          coreFailure(ExternalFailure.authenticationRejected));
      expect(f.trust.snapshot(f.profile.principal).state,
          PairingState.approvedPendingProof);
    }
    await expectLater(f.enable(), coreFailure(ExternalFailure.unpaired));
    await f.coordinator.completePairing(f.profile, f.credentials.first);
    expect(f.trust.snapshot(f.profile.principal).state,
        PairingState.pairedDisabled);
    await expectLater(f.session(), coreFailure(ExternalFailure.disabled));
    for (final duration in [Duration.zero, const Duration(minutes: 31)]) {
      await expectLater(f.coordinator.enable(f.profile, duration),
          coreFailure(ExternalFailure.invalidRequest));
    }
  });

  test('two Profiles cannot claim one Credential Identity; Sessions isolate',
      () async {
    final second = await f.coordinator.registerProfile(await f.secondProfile());
    await f.pair();
    await expectLater(
        f.coordinator.requestPairing(second,
            requestId: 'second', credentialIdentity: 'first'),
        coreFailure(ExternalFailure.pairingConflict));
    await f.pair(selected: second, key: f.credentials.second);
    await f.enable();
    await f.enable(selected: second);
    final session = await f.session();
    final other = await f.session(selected: second, key: f.credentials.second);
    expect(identical(session.principal, other.principal), isFalse);
    await expectLater(f.session(selected: second), denied());
  });

  for (final policy in ['missing-grant', 'empty-scope', 'empty-egress']) {
    test('enabled synthetic Session with $policy has no content release',
        () async {
      if (policy != 'missing-grant') {
        await f.save(
            scopes: policy != 'empty-scope', egress: policy != 'empty-egress');
      }
      await f.pair();
      await f.enable();
      final session = await f.session();
      await f.coordinator.startOffline();
      if (policy == 'missing-grant') {
        await expectLater(f.coordinator.host.bindSession(session),
            throwsA(isA<LocalHostAdmissionException>()));
      } else {
        final entry = await f.coordinator.host.bindSession(session);
        if (policy == 'empty-egress') {
          await expectLater(f.coordinator.host.openRead(entry),
              throwsA(isA<LocalHostAdmissionException>()));
        } else {
          final context = await f.coordinator.host.openRead(entry);
          final result = await f.coordinator.host.dispatch(
              ExternalCapabilities.listTargets, const ExternalTargetQuery(),
              entry: entry, context: context);
          expect(result.output!.items, isEmpty);
          expect(result.receipt.knownEffect, CapabilityEffect.none);
        }
      }
      final record = await f.management.read(f.reference);
      expect(
          record.grant?.policy.scopes,
          policy == 'missing-grant'
              ? isNull
              : policy == 'empty-scope'
                  ? isEmpty
                  : hasLength(1));
      expect(
          record.grant?.policy.categories,
          policy == 'missing-grant'
              ? isNull
              : policy == 'empty-egress'
                  ? isEmpty
                  : hasLength(3));
    });
  }

  test(
      'READ references cross same-Principal Sessions; execution Contexts do not',
      () async {
    final (session, entry) = await ready();
    final discovery = await f.coordinator.host.openRead(entry);
    final targets = await f.coordinator.host.dispatch(
        ExternalCapabilities.listTargets, const ExternalTargetQuery(),
        entry: entry, context: discovery);
    final token = await f.reads.createContext(
        session: session, targetRef: targets.output!.items.single.targetRef);
    final fresh = await f.session();
    expect(await f.reads.contextStatus(session: fresh, context: token),
        ExternalReadValidity.authorized);
    final freshEntry = await f.coordinator.host.bindSession(fresh);
    expectNotStarted(await f.coordinator.host.dispatch(
        ExternalCapabilities.listTargets, const ExternalTargetQuery(),
        entry: freshEntry, context: discovery));
    expect(await f.coordinator.host.openRead(freshEntry, context: token),
        isNotNull);
    final stage = await f.stages.approveTarget(session, f.local.h.target, []);
    final execution = await f.coordinator.host.openStage(entry, stage);
    expectNotStarted(await f.coordinator.host.dispatch(
        ExternalCapabilities.stage,
        ExternalStageSubmission(submission(key: 'cross-session')),
        entry: freshEntry,
        context: execution));
    expect(await f.local.h.count('generated_question_proposals'), 0);
  });

  for (final mutation in [
    'disable',
    'expiry',
    'profile-revoke',
    'revision',
    'restart',
    'restore',
    'replace'
  ]) {
    test(
        '$mutation invalidates old Session/entry/Context; authentication cannot renew it',
        () async {
      final (session, entry) = await ready();
      final context = await f.coordinator.host.openRead(entry);
      switch (mutation) {
        case 'disable':
          await f.coordinator.disable(f.profile);
        case 'expiry':
          f.clock.current = f.clock.current.add(const Duration(minutes: 10));
        case 'profile-revoke':
          await f.management.revokeProfile(f.reference, 1);
        case 'revision':
          await f.save();
        case 'restart':
          f.trust.restart();
        case 'restore':
          f.trust.restore();
        case 'replace':
          f.coordinatorCurrent = false;
      }
      expectNotStarted(await f.coordinator.host.dispatch(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          entry: entry, context: context));
      await expectLater(f.coordinator.host.openRead(entry),
          throwsA(isA<LocalHostAdmissionException>()));
      if (mutation == 'disable' || mutation == 'expiry') {
        await f.enable();
        final fresh = await f.session();
        expect(f.trust.sessionFailure(session), isNotNull);
        final freshEntry = await f.coordinator.host.bindSession(fresh);
        expectNotStarted(await f.coordinator.host.dispatch(
            ExternalCapabilities.listTargets, const ExternalTargetQuery(),
            entry: freshEntry, context: context));
      } else if (mutation == 'restart') {
        f.trust.enable(f.profile.principal, const Duration(minutes: 10));
        final fresh =
            f.trust.openSession(f.trust.authenticate(f.credentials.first));
        await expectLater(f.stages.runtimeAdmission.admit(fresh), denied());
        await expectLater(f.session(), denied());
      }
    });
  }

  for (final mutation in ['restart', 'shutdown']) {
    test('$mutation during local registration rejects late binding and drains',
        () async {
      final reference = await f.secondProfile();
      f.barrier.reached = Completer<void>();
      f.barrier.resume = Completer<void>();
      final pending = f.coordinator.registerProfile(reference);
      final rejected = expectLater(pending, throwsA(anything));
      await f.barrier.reached!.future;
      var stopped = false;
      Future<void>? shutdown;
      if (mutation == 'restart') {
        f.trust.restart();
      } else {
        shutdown = f.coordinator.shutdown().then((_) => stopped = true);
        await flushHostMicrotasks();
        expect(stopped, isFalse);
      }
      f.barrier.resume!.complete();
      await rejected;
      await shutdown;
      if (mutation == 'shutdown') expect(stopped, isTrue);
    });
  }

  test(
      'lost STAGE reconciles original SubmissionKey after disabled real SQLite restart',
      () async {
    final (session, entry) = await ready();
    final stage = await f.stages.approveTarget(session, f.local.h.target, []);
    final context = await f.coordinator.host.openStage(entry, stage);
    final lost = await f.coordinator.host.dispatch(ExternalCapabilities.stage,
        ExternalStageSubmission(submission(key: 'original-key')),
        entry: entry, context: context, responseAvailable: () => false);
    expect(lost.output, isNull);
    expect(lost.receipt.knownEffect, CapabilityEffect.proposalStaged);
    expect(lost.receipt.durableReconciliation!.submissionKey, 'original-key');
    final oldProfile = f.profile;
    await f.restart();
    expect(f.trust.snapshot(f.profile.principal).state, PairingState.unpaired);
    expect(f.coordinator.host.state, LocalHostState.disabled);
    expect(session.failure, isNotNull);
    await expectLater(
        f.coordinator.enable(oldProfile, const Duration(minutes: 1)), denied());
    await expectLater(
        f.session(), coreFailure(ExternalFailure.authenticationRejected));
    await f.pair();
    await f.enable();
    await f.coordinator.startOffline();
    final fresh = await f.coordinator.host.bindSession(await f.session());
    await expectLater(f.coordinator.host.openRead(entry),
        throwsA(isA<LocalHostAdmissionException>()));
    expectNotStarted(await f.coordinator.host.dispatch(
        ExternalCapabilities.stage,
        ExternalStageSubmission(submission(key: 'original-key')),
        entry: fresh,
        context: context));
    final reconciliation =
        await f.coordinator.host.openReconciliation(fresh, 'original-key');
    final found = await f.coordinator.host.dispatch(
        ExternalCapabilities.reconcile, const ExternalNoInput(),
        entry: fresh, context: reconciliation);
    expect(found.output!.submissionKey, 'original-key');
    expect(await f.local.h.count('generated_question_proposals'), 1);
    expect(await f.local.h.count('generated_question_commit_receipts'), 0);
    expect(await f.local.h.count('questions'), 0);
  });

  for (final mutation in ['grant-revoke', 'disable', 'expiry', 'shutdown']) {
    for (final committed in [false, true]) {
      test(
          'STAGE $mutation ${committed ? 'after' : 'before'} publication retains owning settlement',
          () async {
        final (session, entry) = await ready();
        final context = await f.coordinator.host.openStage(
            entry, await f.stages.approveTarget(session, f.local.h.target, []));
        final reached = Completer<void>(), resume = Completer<void>();
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        f.checkpoint = (point) async {
          if (point ==
              (committed
                  ? ExternalStageCheckpoint.afterCommit
                  : ExternalStageCheckpoint.beforeTransaction)) {
            reached.complete();
            await resume.future;
          }
        };
        final control = ExternalCallControl(clock: f.clock);
        final pending = f.coordinator.host.dispatch(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'race-key')),
            entry: entry, context: context, control: control);
        await reached.future;
        Future<void>? shutdown;
        var stopped = false;
        switch (mutation) {
          case 'grant-revoke':
            await f.management.revokeGrant(f.reference, 1);
          case 'disable':
            await f.coordinator.disable(f.profile);
          case 'expiry':
            f.clock.current = f.clock.current.add(const Duration(minutes: 10));
          case 'shutdown':
            // Caller interruption may return before the actual SQLite work.
            control.cancel();
            final interrupted = await pending;
            expect(interrupted.output, isNull);
            expect(interrupted.receipt.knownEffect,
                committed ? CapabilityEffect.proposalStaged : isNull);
            shutdown = f.coordinator.shutdown().then((_) => stopped = true);
            await flushHostMicrotasks();
            expect(stopped, isFalse);
            expect(f.stages.pendingCount, 1);
            expectNotStarted(await f.coordinator.host.dispatch(
                ExternalCapabilities.stage,
                ExternalStageSubmission(submission(key: 'new-key')),
                entry: entry,
                context: context));
        }
        resume.complete();
        final result = await pending;
        await shutdown;
        await f.gateway.whenIdle;
        await f.stages.whenIdle;
        expect(result.output, isNull);
        if (mutation != 'shutdown') {
          expect(
              result.receipt.knownEffect,
              committed
                  ? CapabilityEffect.proposalStaged
                  : CapabilityEffect.none);
        }
        expect(await f.local.h.count('generated_question_proposals'),
            committed ? 1 : 0);
        expect(await f.local.h.count('generated_question_commit_receipts'), 0);
        expect(await f.local.h.count('questions'), 0);
        if (shutdown != null) {
          expect(stopped, isTrue);
          expect(f.gateway.pendingCount, 0);
          expect(f.stages.pendingCount, 0);
          expect(session.failure, isNotNull);
        }
      });
    }
  }

  test(
      'production composition and projections have no authenticating offline path',
      () {
    for (final root in [
      'lib/main.dart',
      'lib/mcp',
      'lib/application/modules',
      'lib/application/agent',
      'lib/services/agent',
      'lib/ui'
    ]) {
      final files = FileSystemEntity.isFileSync(root)
          ? [File(root)]
          : Directory(root).listSync(recursive: true).whereType<File>();
      for (final file in files.where((file) => file.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        for (final forbidden in [
          'ExternalTrustCoordinator',
          'ExternalTrustCore(',
          'LocalHostDispatchCore(',
          'OfflineTrustCredentials',
          'StageCredentials',
          'registerExistingProfile'
        ]) {
          expect(source, isNot(contains(forbidden)), reason: file.path);
        }
      }
    }
    expect(
        File('lib/ui/pages/external_authorization_screen.dart')
            .readAsStringSync(),
        contains('当前仅配置访问规则。外部客户端尚未配对，真实连接功能未启用。'));
    for (final path in [
      'lib/data/external/ipc_envelope_codec.dart',
      'lib/data/external/ipc_command_projection.dart',
      'lib/data/external/ipc_command_schema.dart'
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('registerExistingProfile')));
      expect(source, isNot(contains('ExternalTrustCoordinator')));
    }
  });
}
