import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';

import '../../application/external/external_question_read_test_support.dart';
import 'bootstrap_test_support.dart';
import 'windows_pairing_test.dart' show signPublicFixture;
import 'windows_credential_object_store_test.dart' as objects;
import 'windows_tls_transport_test.dart' as tls;

class BindBarrier implements TlsListenerIo {
  final listener = tls.MemoryListener();
  final reached = Completer<void>(), resume = Completer<void>();
  @override
  Future<TlsCandidateListener> bind(int port) async {
    reached.complete();
    await resume.future;
    return listener.bind(port);
  }
}

class OwnedHarness extends tls.TlsHarness {
  WindowsTlsHost compose(
      {TlsListenerIo? io,
      TlsTrustedContext? context,
      Future<void> Function()? closeLocalConnections,
      bool wrongOwner = false,
      bool wrongRuntime = false,
      bool wrongGeneration = false}) {
    final p = pairing;
    final credentials = WindowsCredentialInitialization.withPrimitives(
        owner: p.native.owner,
        generateKey: p.native.generate,
        signDigest: signPublicFixture,
        verifyDigest: p.native.verify,
        utcNow: () => p.native.now,
        randomBytes: p.random);
    final startup = P26TlsStartup(
        owner: p.native.owner,
        credentials: credentials,
        publisher: WindowsDiscoveryPublisher(
            owner: p.native.owner, credentials: credentials),
        runtimeInstanceId:
            wrongRuntime ? Uint8List(16) : p.app.runtimeInstanceId,
        generation:
            BigInt.from(p.local.trust.generation + (wrongGeneration ? 1 : 0)),
        signDigest: signPublicFixture,
        verifyDigest: p.native.verify,
        utcNow: () => p.native.now,
        compositionIsCurrent: () => p.current && p.boundary.isCurrent);
    return this.candidate = WindowsTlsHost.owned(
        owner: wrongOwner ? p.bridgeOwner : p.native.owner,
        pairing: p.app,
        associations: p.associations,
        boundary: p.boundary,
        coordinator: p.local.coordinator,
        startup: startup,
        verification: verifier,
        closeLocalConnections: closeLocalConnections,
        io: io ?? listener,
        context: context ??
            (session) async => p.local.coordinator.host
                .openRead(await p.local.coordinator.host.bindSession(session)),
        port: listener.port,
        monotonicNow: () => deadlines.now,
        schedule: deadlines.schedule);
  }

  Future<void> authorize() async {
    await pairing.complete();
    await pairing.local.save();
    await pairing.local.coordinator
        .enable(pairing.local.profile, const Duration(minutes: 5));
  }

  Future<ExternalExecutionContext> stageContext(ExternalSession session) async {
    final host = pairing.local.coordinator.host;
    return host.openStage(
        await host.bindSession(session),
        await pairing.local.stages
            .approveTarget(session, pairing.local.local.h.target, []));
  }
}

void main() {
  initializeGeneratedTests();
  late OwnedHarness h;
  setUp(() async {
    h = OwnedHarness();
    await h.open();
    await h.pairing.local.coordinator.startOffline();
  });
  tearDown(() async {
    h.pairing.native.calls.closeStatus = 0;
    await h.close();
  });

  test(
      'C1 same Host owns inactive/preparing/ready/closing/closed and lock last',
      () async {
    final runtime = h.compose();
    expect(runtime.phase, WindowsTlsHostPhase.inactive);
    expect(h.listener.binds, 0);
    h.listener.onBind = () {
      expect(runtime.phase, WindowsTlsHostPhase.preparing);
      expect(h.pairing.local.coordinator.host.state, LocalHostState.ready);
      expect(h.pairing.native.owner.isUsable, isTrue);
    };
    await runtime.start();
    expect(runtime.phase, WindowsTlsHostPhase.ready);
    expect(runtime.isReady, isTrue);
    final descriptor = DiscoveryDescriptorCodec.decode(
        h.pairing.native.calls.discoveryFiles[1]!);
    expect(descriptor.publicationEpoch, BigInt.two);
    final first = runtime.shutdown(), second = runtime.shutdown();
    expect(identical(first, second), isTrue);
    expect(runtime.phase, WindowsTlsHostPhase.closing);
    await first;
    expect(runtime.phase, WindowsTlsHostPhase.closed);
    expect(h.pairing.native.owner.isClosed, isTrue);
    expect(h.pairing.local.coordinator.host.state, LocalHostState.stopped);
    expect(h.pairing.native.calls.events.last, 'close');
    await expectLater(runtime.start(), throwsA(anything));
    // Public residue is inert; never unlink Endpoint/Anchor/Installation by path.
    expect(h.pairing.native.calls.discoveryFiles[1], isNotNull);
  });

  test('C1 close before start acquires no listener and cannot reopen',
      () async {
    final runtime = h.compose();
    await runtime.shutdown();
    expect(runtime.phase, WindowsTlsHostPhase.closed);
    expect(h.listener.binds, 0);
    expect(h.pairing.native.calls.discoveryPublishes, 0);
    await expectLater(runtime.start(), throwsA(anything));
  });

  test('C1 Application not ready prevents preparation/bind/publication',
      () async {
    await h.pairing.local.coordinator.host.shutdown();
    final runtime = h.compose();
    await expectLater(runtime.start(), throwsA(anything));
    await runtime.shutdown();
    expect(runtime.phase, WindowsTlsHostPhase.closed);
    expect(h.listener.binds, 0);
    expect(h.pairing.native.calls.discoveryPublishes, 0);
  });

  test('C1 foreign Owner and competing runtime lock fail before bind/store',
      () async {
    expect(() => h.compose(wrongOwner: true), throwsA(anything));
    expect(() => h.compose(wrongRuntime: true), throwsA(anything));
    expect(() => h.compose(wrongGeneration: true), throwsA(anything));
    final calls = h.pairing.native.calls;
    final commits = calls.commits;
    expect(() => objects.adapter(calls).acquireAppObjects(), throwsA(anything));
    expect(calls.commits, commits);
    expect(h.listener.binds, 0);
    expect(calls.discoveryPublishes, 0);
  });

  test(
      'C1 sharing an acquired Owner cannot create a second Host or close the first',
      () async {
    final runtime = h.compose();
    await runtime.start();
    expect(() => h.compose(), throwsA(anything));
    expect(runtime.isReady, isTrue);
    expect(h.listener.binds, 1);
    expect(h.pairing.native.owner.isUsable, isTrue);
  });

  for (final interrupted in [false, true]) {
    test(
        'C2 successor uses durable epoch with identical Generation, interruption=$interrupted',
        () async {
      final runtime = h.compose();
      await runtime.start();
      final calls = h.pairing.native.calls;
      final oldBytes = Uint8List.fromList(calls.discoveryFiles[1]!);
      final old = DiscoveryDescriptorCodec.decode(oldBytes);
      await runtime.shutdown();
      expect(h.listener.closes, 1);
      var owner = objects.adapter(calls).acquireAppObjects();
      WindowsDiscoveryPublisher publisher() {
        final credentials = WindowsCredentialInitialization.withPrimitives(
            owner: owner,
            generateKey: h.pairing.native.generate,
            signDigest: signPublicFixture,
            verifyDigest: h.pairing.native.verify,
            utcNow: () => h.pairing.native.now,
            randomBytes: h.pairing.random);
        return WindowsDiscoveryPublisher(
            owner: owner, credentials: credentials);
      }

      DiscoveryDescriptor publish() => publisher().publish(
          runtimeInstanceId: Uint8List.fromList(List.filled(16, 42)),
          generation: old.generation,
          port: old.port + 1,
          publishedAtUtcMs: old.publishedAtUtcMs + BigInt.one);
      if (interrupted) {
        // Fake failure AFTER persistent kind-1 epoch commit, before Endpoint.
        // Explicit fixture handle release models post-crash acquisition only;
        // it proves no OS crash/lock-release behavior.
        calls.beforeDiscoveryPublish = (_) => throw StateError('fixed cut');
        expect(publish, throwsA(anything));
        expect(calls.discoveryFiles[1], oldBytes);
        calls.beforeDiscoveryPublish = null;
        owner.close();
        owner = objects.adapter(calls).acquireAppObjects();
      }
      try {
        final next = publish();
        expect(next.generation, old.generation);
        expect(next.publicationEpoch,
            old.publicationEpoch + BigInt.from(interrupted ? 2 : 1));
        final reader = WindowsDiscoveryReader(h.pairing.bridgeOwner, verifier: (
            {required publicPoint, required digest, required rawSignature}) {
          h.pairing.native.verify(
              publicPoint: publicPoint,
              digest: digest,
              rawSignature: rawSignature);
          return true;
        });
        final expected = DiscoveryExpectations(
            trustedAnchorDer: vectorBytes('issuerDer'),
            installationId: old.installationId,
            serverLeafDigest: old.serverLeafDigest,
            verifiedEpochHighWater: next.publicationEpoch);
        expect(reader.read(expected).publicationEpoch, next.publicationEpoch);
        calls.discoveryFiles[1] = oldBytes;
        expect(() => reader.read(expected), throwsA(anything));
      } finally {
        owner.close();
      }
    });
  }

  test(
      'C2 shutdown preserves foreign public/Exchange sentinels and unknown files',
      () async {
    final calls = h.pairing.native.calls;
    final sentinel = Uint8List.fromList([9, 7, 5]);
    calls.discoveryFiles[99] = sentinel;
    calls.exchangeFiles[(99, 'foreign-sentinel')] = sentinel;
    calls.unknownExchangeEntries = 1;
    final runtime = h.compose();
    await runtime.start();
    await runtime.shutdown();
    expect(calls.discoveryFiles[99], sentinel);
    expect(calls.exchangeFiles[(99, 'foreign-sentinel')], sentinel);
    expect(calls.unknownExchangeEntries, 1);
  });

  test('C1 close racing bind retains lock until original bind and close settle',
      () async {
    final io = BindBarrier();
    final runtime = h.compose(io: io);
    final start = expectLater(runtime.start(), throwsA(anything));
    await io.reached.future;
    var settled = false;
    final close = runtime.shutdown().then((_) => settled = true);
    await pumpEventQueue(times: 4);
    expect(settled, isFalse);
    expect(h.pairing.native.owner.isClosed, isFalse);
    io.resume.complete();
    await start;
    await close;
    expect(io.listener.closes, 1);
    expect(h.pairing.native.calls.discoveryPublishes, 0);
    expect(runtime.phase, WindowsTlsHostPhase.closed);
  });

  test('C1 close during publication never becomes Ready or retries epoch',
      () async {
    final runtime = h.compose();
    Future<void>? closing;
    h.pairing.native.calls.beforeDiscoveryPublish = (kind) {
      if (kind == 1) closing = runtime.shutdown();
    };
    await expectLater(runtime.start(), throwsA(anything));
    await closing;
    expect(runtime.phase, WindowsTlsHostPhase.closed);
    expect(runtime.isReady, isFalse);
    expect(h.listener.binds, 1);
    expect(h.pairing.native.calls.discoveryPublishes, 3);
  });

  for (final mode in ['missing', 'corrupt', 'commitUnknown']) {
    test('C1 $mode credential/publication fails closed without repair',
        () async {
      final runtime = h.compose();
      final calls = h.pairing.native.calls;
      if (mode == 'missing') calls.credentialFiles.remove(2);
      if (mode == 'corrupt') calls.credentialFiles[2] = Uint8List.fromList([1]);
      if (mode == 'commitUnknown') calls.unknownAfterCommit = true;
      final generated = h.pairing.native.generated;
      await expectLater(runtime.start(), throwsA(anything));
      await runtime.shutdown();
      expect(runtime.isReady, isFalse);
      expect(calls.discoveryFiles[1], isNull);
      expect(h.pairing.native.generated, generated);
      expect(h.listener.binds, mode == 'commitUnknown' ? 1 : 0);
    });
  }

  test('C2 disposed connection object can never mint another P15 attempt',
      () async {
    await h.authorize();
    final channel = tls.MemoryTlsChannel();
    final session = await h.verifier.authenticate(channel, h.plan);
    h.verifier.invalidateChannel(channel);
    // Socket close is NOT P0 per-Session revocation.
    expect(session.session.failure, isNull);
    await channel.close();
    channel.open = true;
    await expectLater(
        h.verifier.authenticate(channel, h.plan), throwsA(anything));
    expect(await session.authenticate(), isNull);
  });

  test(
      'C2 shutdown waits late handshake and does not release its slots on close',
      () async {
    await h.authorize();
    final runtime = h.compose();
    await runtime.start();
    final channel = tls.MemoryTlsChannel();
    final peer = tls.MemoryRawPeer(channel)
      ..upgrading = Completer<TlsChannel>();
    h.listener.controller.add(peer);
    await pumpEventQueue(times: 4);
    final close = runtime.shutdown();
    await pumpEventQueue(times: 4);
    expect(runtime.budget.used(TlsResource.handshake), 1);
    expect(h.pairing.native.owner.isClosed, isFalse);
    peer.upgrading!.complete(channel);
    await close;
    expect(channel.open, isFalse);
    expect(channel.reads, 0);
    expect(runtime.budget.used(TlsResource.socket), 0);
  });

  test(
      'C2 late TLS cleanup failure after acknowledged Raw Close retains lock/slots',
      () async {
    await h.authorize();
    final runtime = h.compose();
    await runtime.start();
    final channel = tls.MemoryTlsChannel();
    final peer = tls.MemoryRawPeer(channel)
      ..upgrading = Completer<TlsChannel>();
    h.listener.controller.add(peer);
    await pumpEventQueue(times: 4);
    final closing = expectLater(runtime.shutdown(), throwsA(anything));
    await pumpEventQueue(times: 4);
    expect(peer.closes, 1);
    // Raw Close already acknowledged; only the late TLS result now fails.
    channel.failClose = true;
    peer.upgrading!.complete(channel);
    await closing;
    expect(runtime.budget.isUsable, isFalse);
    expect(runtime.budget.used(TlsResource.socket), 1);
    expect(runtime.budget.used(TlsResource.handshake), 1);
    expect(h.pairing.native.owner.isClosed, isFalse);
    expect(runtime.phase, WindowsTlsHostPhase.closing);
    h.candidate = null;
  });

  for (final failed in [false, true]) {
    test('C2 pending P15/Store work drains; release failure=$failed is sticky',
        () async {
      await h.authorize();
      final runtime = h.compose();
      await runtime.start();
      final p = h.pairing;
      p.local.barrier.reached = Completer<void>();
      p.local.barrier.resume = Completer<void>();
      h.listener.controller.add(tls.MemoryRawPeer(tls.MemoryTlsChannel()));
      await p.local.barrier.reached!.future;
      if (failed) p.native.calls.closeStatus = 4;
      var settled = false;
      final close = runtime.shutdown();
      final observation =
          (failed ? expectLater(close, throwsA(anything)) : close)
              .then((_) => settled = true);
      await pumpEventQueue(times: 4);
      expect(settled, isFalse);
      expect(p.native.owner.isClosed, isFalse);
      p.local.barrier.resume!.complete();
      await observation;
      expect(runtime.phase,
          failed ? WindowsTlsHostPhase.closing : WindowsTlsHostPhase.closed);
      if (failed) {
        await expectLater(runtime.shutdown(), throwsA(anything));
        h.candidate = null;
      }
    });
  }

  test('local connection cleanup failure retains Owner and is never retried',
      () async {
    var closes = 0;
    final runtime = h.compose(closeLocalConnections: () async {
      closes++;
      throw StateError('fixed offline cleanup failure');
    });
    await runtime.start();
    await expectLater(runtime.shutdown(), throwsA(anything));
    expect(runtime.phase, WindowsTlsHostPhase.closing);
    expect(h.pairing.native.owner.isClosed, isFalse);
    expect(runtime.budget.isUsable, isFalse);
    await expectLater(runtime.shutdown(), throwsA(anything));
    expect(closes, 1);
    h.candidate =
        null; // Only fixture teardown releases the retained Fake owner.
  });

  for (final failed in [false, true]) {
    test('C2 P15 revoke CAS failure=$failed never reopens runtime', () async {
      await h.authorize();
      final runtime = h.compose();
      await runtime.start();
      if (failed) h.pairing.native.calls.associationCommitStatus = 4;
      final revoke = runtime.revoke(h.pairing.local.reference, 1);
      if (failed) {
        await expectLater(revoke, throwsA(anything));
        expect(runtime.phase, WindowsTlsHostPhase.closing);
        expect(h.pairing.native.owner.isClosed, isFalse);
        h.candidate = null;
      } else {
        await revoke;
        expect(runtime.phase, WindowsTlsHostPhase.closed);
      }
      expect(runtime.isReady, isFalse);
      await expectLater(runtime.start(), throwsA(anything));
    });
  }

  for (final point in ['beforeTransaction', 'afterCommit']) {
    test(
        'C2 Revoke at $point preserves P3 publication ordering and Owner custody',
        () async {
      await h.authorize();
      final runtime = h.compose(context: h.stageContext);
      await runtime.start();
      final reached = Completer<void>(), resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      h.pairing.local.checkpoint = (checkpoint) async {
        if (checkpoint.name == point) {
          reached.complete();
          await resume.future;
        }
      };
      final channel = tls.MemoryTlsChannel()
        ..feed(tls.request('external_stage_generated_questions', {
          'submissionJson': submission(key: 'ordering-key'),
          'externalRequestId': null
        }));
      h.listener.controller.add(tls.MemoryRawPeer(channel));
      await reached.future;
      var revoked = false;
      final managementRead = Completer<void>();
      h.pairing.local.barrier.reached = managementRead;
      final revoke = runtime
          .revoke(h.pairing.local.reference, 1)
          .then((_) => revoked = true);
      await managementRead.future;
      // The completed management read resumes P15; no OS/timing inference.
      await pumpEventQueue(times: 10);
      expect(runtime.isReady, isFalse);
      expect(revoked, isFalse);
      expect(h.pairing.native.owner.isClosed, isFalse);
      expect(runtime.budget.used(TlsResource.pipeline), 1);
      resume.complete();
      await revoke;
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          point == 'afterCommit' ? 1 : 0);
      expect(
          await h.pairing.local.local.h
              .count('generated_question_commit_receipts'),
          0);
      expect(channel.writes, isEmpty);
    });
  }

  test(
      'A8 committed response loss reconciles same Proposal via fresh P15 Session/original Key',
      () async {
    await h.authorize();
    final runtime = h.compose(context: h.stageContext);
    await runtime.start();
    final reached = Completer<void>(), resume = Completer<void>();
    h.pairing.local.checkpoint = (point) async {
      if (point.name == 'afterCommit') {
        reached.complete();
        await resume.future;
      }
    };
    final channel = tls.MemoryTlsChannel()
      ..feed(tls.request(
          'external_stage_generated_questions',
          {
            'submissionJson': submission(key: 'original-key'),
            'externalRequestId': null
          },
          'unrelated-envelope-id'));
    h.listener.controller.add(tls.MemoryRawPeer(channel));
    await reached.future;
    await channel.close();
    expect(runtime.budget.used(TlsResource.pipeline), 1);
    resume.complete();
    await runtime.whenConnectionsSettled;
    expect(channel.writes, isEmpty); // Client has UNKNOWN, not a failed commit.
    final db = h.pairing.local.local.h;
    final original = await db.db.query('generated_question_proposals');
    final fresh = await h.verifier.authenticate(tls.MemoryTlsChannel(), h.plan);
    final host = h.pairing.local.coordinator.host;
    final entry = await host.bindSession(fresh.session);
    final found = await host.dispatch(
        ExternalCapabilities.reconcile, const ExternalNoInput(),
        entry: entry,
        context: await host.openReconciliation(entry, 'original-key'));
    expect(found.output!.submissionKey, 'original-key');
    expect(await db.db.query('generated_question_proposals'), original);
    expect(await db.count('generated_question_proposals'), 1);
    expect(await db.count('generated_question_commit_receipts'), 0);
  });

  test(
      'C2 unknown Socket cleanup waits STAGE then retains Runtime lock forever',
      () async {
    await h.authorize();
    final runtime = h.compose(context: h.stageContext);
    await runtime.start();
    final reached = Completer<void>(), resume = Completer<void>();
    h.pairing.local.checkpoint = (point) async {
      if (point.name == 'afterCommit') {
        reached.complete();
        await resume.future;
      }
    };
    final channel = tls.MemoryTlsChannel()..failClose = true;
    channel.feed(tls.request('external_stage_generated_questions', {
      'submissionJson': submission(key: 'unknown-close'),
      'externalRequestId': null
    }));
    h.listener.controller.add(tls.MemoryRawPeer(channel));
    await reached.future;
    var settled = false;
    final observation = expectLater(runtime.shutdown(), throwsA(anything))
        .then((_) => settled = true);
    await pumpEventQueue(times: 4);
    expect(settled, isFalse);
    resume.complete();
    await observation;
    expect(runtime.phase, WindowsTlsHostPhase.closing);
    expect(runtime.budget.used(TlsResource.pipeline), 1);
    expect(h.pairing.native.owner.isClosed, isFalse);
    expect(() => objects.adapter(h.pairing.native.calls).acquireAppObjects(),
        throwsA(anything));
    h.candidate =
        null; // Fixture cleanup is explicit, never production recovery.
  });
}
