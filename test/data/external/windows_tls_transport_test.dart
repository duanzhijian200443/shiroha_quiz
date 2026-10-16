import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/data/external/external_certificate_der.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_credential_initialization.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../application/external/external_question_read_test_support.dart';
import 'bootstrap_test_support.dart';
import 'windows_credential_initialization_test.dart' as init;
import 'windows_pairing_test.dart' as pair;
import 'windows_peer_certificate_policy_test.dart' show OfflinePeerCalls;

final class ManualDeadlines {
  Duration now = Duration.zero;
  final tasks = <({Duration due, void Function() run, List<bool> cancelled})>[];
  void Function() schedule(Duration delay, void Function() callback) {
    final cancelled = [false];
    tasks.add((due: now + delay, run: callback, cancelled: cancelled));
    return () => cancelled[0] = true;
  }

  void advance(Duration by) {
    now += by;
    for (final task in tasks.toList()) {
      if (!task.cancelled[0] && task.due <= now) {
        task.cancelled[0] = true;
        task.run();
      }
    }
  }
}

class MemoryTlsChannel implements TlsChannel {
  MemoryTlsChannel([Uint8List? der])
      : certificate = der ?? vectorBytes('clientDer');
  Uint8List certificate;
  final chunks = <Uint8List>[];
  final writes = <Uint8List>[];
  final written = Completer<void>();
  Completer<Uint8List?>? reading;
  Completer<void>? writing, closing;
  bool open = true, failClose = false, eof = false;
  int reads = 0, closeCalls = 0;
  @override
  Uint8List get peerDer => Uint8List.fromList(certificate);
  @override
  bool get isOpen => open;
  void feed(Uint8List bytes) {
    chunks.add(bytes);
    _wake();
  }

  void _wake() {
    final waiter = reading;
    if (waiter != null) {
      reading = null;
      waiter.complete(Uint8List(0));
    }
  }

  @override
  Future<Uint8List?> read(int maximum) async {
    reads++;
    while (open && !eof && chunks.isEmpty) {
      reading = Completer<Uint8List?>();
      await reading!.future;
    }
    if (!open || chunks.isEmpty) return null;
    final first = chunks.removeAt(0);
    if (first.length <= maximum) return first;
    chunks.insert(0, Uint8List.sublistView(first, maximum));
    return Uint8List.sublistView(first, 0, maximum);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(Uint8List.fromList(bytes));
    if (!written.isCompleted) written.complete();
    await writing?.future;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    open = false;
    _wake();
    if (failClose) throw StateError('fixed Fake release failure');
    await closing?.future;
  }
}

class MemoryRawPeer implements TlsRawPeer {
  MemoryRawPeer(this.channel);
  final MemoryTlsChannel channel;
  Completer<TlsChannel>? upgrading;
  Object? upgradeFailure;
  int upgrades = 0, closes = 0;
  void Function()? beforeUpgrade;
  @override
  Future<TlsChannel> upgrade(TlsContextPlan plan) async {
    upgrades++;
    beforeUpgrade?.call();
    if (upgradeFailure != null) throw upgradeFailure!;
    return upgrading == null ? channel : await upgrading!.future;
  }

  @override
  Future<void> close() async {
    closes++;
    await channel.close();
  }
}

class MemoryListener implements TlsCandidateListener, TlsListenerIo {
  final controller = StreamController<TlsRawPeer>(sync: true);
  int binds = 0, closes = 0;
  void Function()? onBind;
  @override
  String address = '127.0.0.1';
  @override
  int port = 43123;
  @override
  bool shared = false;
  @override
  Stream<TlsRawPeer> get peers => controller.stream;
  @override
  Future<TlsCandidateListener> bind(int port) async {
    binds++;
    onBind?.call();
    return this;
  }

  @override
  Future<void> close() async {
    closes++;
    unawaited(controller.close());
  }
}

class MemoryBridgeIo implements TlsBridgeIo {
  MemoryBridgeIo(this.channel);
  final MemoryTlsChannel channel;
  int calls = 0, port = 0;
  @override
  Future<TlsChannel> connect(
      int verifiedDescriptorPort, TlsContextPlan plan) async {
    calls++;
    port = verifiedDescriptorPort;
    expect(plan.role, TlsPeerRole.client);
    return channel;
  }
}

class RecordingContext implements TlsContextSink {
  final actions = <String>[];
  Uint8List? certificatePem, anchorPem;
  @override
  void minimumTls13() => actions.add('TLS13');
  @override
  void disableRenegotiation() => actions.add('renegotiationOff');
  @override
  void chain(Uint8List pem) {
    certificatePem = Uint8List.fromList(pem);
    actions.add('chain');
  }

  @override
  void privateKey(Uint8List pem) => actions.add('key');
  @override
  void trustOnly(Uint8List pem) {
    anchorPem = Uint8List.fromList(pem);
    actions.add('trustOnly');
  }

  @override
  void clientAuthorities(Uint8List pem) =>
      actions.add('requireClientAuthority');
}

class TlsHarness {
  final pairing = pair.PairingHarness();
  final nativePeer = OfflinePeerCalls();
  final deadlines = ManualDeadlines();
  final listener = MemoryListener();
  late WindowsChannelVerification verifier;
  late TlsContextPlan plan;
  WindowsTlsHost? candidate;
  Future<void> open() async {
    await pairing.open(
        verifierFactory: (pairingVerifier, management) => verifier =
            WindowsChannelVerification(
                pairing: pairingVerifier,
                associations: pairing.associations,
                management: management,
                nativePolicy: WindowsPeerCertificatePolicy(nativePeer).check,
                verifyDigest: pairing.native.verify,
                utcNow: () => pairing.native.now,
                monotonicNow: () => deadlines.now,
                compositionIsCurrent: () =>
                    pairing.current && pairing.local.current));
    verifier.attach(pairing.boundary);
    plan = TlsContextPlan.validate(
        role: TlsPeerRole.server,
        leafDer: vectorBytes('serverDer'),
        issuerDer: vectorBytes('issuerDer'),
        privateKeyDer: init.publicFixtureKey(),
        independentlyPinnedIssuer: vectorBytes('issuerDer'),
        signDigest: pairing.native.sign,
        verifyDigest: pairing.native.verify,
        utcNow: () => pairing.native.now);
  }

  Future<void> enable() async {
    await pairing.complete(); // actual independent P-256 math -> P15 -> P0
    await pairing.local.save();
    await pairing.local.coordinator
        .enable(pairing.local.profile, const Duration(minutes: 5));
    await pairing.local.coordinator.startOffline();
  }

  Future<void> start(
      {TlsStartup? startup,
      TlsBudgets? limits,
      TlsTrustedContext? context}) async {
    final credentials = WindowsCredentialInitialization.withPrimitives(
        owner: pairing.native.owner,
        generateKey: pairing.native.generate,
        signDigest: pair.signPublicFixture,
        verifyDigest: pairing.native.verify,
        utcNow: () => pairing.native.now,
        randomBytes: pairing.random);
    candidate = WindowsTlsHost(
        io: listener,
        startup: startup ??
            P26TlsStartup(
                owner: pairing.native.owner,
                credentials: credentials,
                publisher: WindowsDiscoveryPublisher(
                    owner: pairing.native.owner, credentials: credentials),
                runtimeInstanceId: vectorBytes('runtimeInstanceId'),
                generation: BigInt.from(pairing.local.trust.generation),
                signDigest: pair.signPublicFixture,
                verifyDigest: pairing.native.verify,
                utcNow: () => pairing.native.now,
                compositionIsCurrent: () =>
                    pairing.current && pairing.boundary.isCurrent),
        verification: verifier,
        host: pairing.local.coordinator.host,
        port: listener.port,
        monotonicNow: () => deadlines.now,
        schedule: deadlines.schedule,
        limits: limits,
        context: context ??
            (session) async => pairing.local.coordinator.host.openRead(
                await pairing.local.coordinator.host.bindSession(session)));
    await candidate!.start();
  }

  Future<void> settle(MemoryTlsChannel channel) async {
    await channel.close();
    await candidate!.whenConnectionsSettled;
  }

  Future<void> close() async {
    await candidate?.shutdown();
    verifier.close();
    plan.dispose();
    await pairing.close();
    expect(nativePeer.memory.allocations, isEmpty);
  }
}

Uint8List request(String name, Object input, [String id = 'wire-id']) =>
    IpcEnvelopeCodec.encodeRequest(
        id,
        jsonEncode({
          'schemaVersion': 1,
          'type': 'command',
          'capability': name,
          'input': input
        }));

void main() {
  initializeGeneratedTests();
  late TlsHarness h;
  setUp(() async {
    h = TlsHarness();
    await h.open();
  });
  tearDown(() => h.close());

  test(
      'B1 pure plans enforce TLS13, isolated trust and leaf-first chain without OS calls',
      () {
    final sink = RecordingContext();
    h.plan.configure(sink);
    expect(sink.actions, [
      'TLS13',
      'renegotiationOff',
      'chain',
      'key',
      'trustOnly',
      'requireClientAuthority'
    ]);
    final text = ascii.decode(sink.certificatePem!);
    expect(
        text.indexOf(base64.encode(vectorBytes('serverDer')).substring(0, 60)),
        lessThan(text.indexOf(
            base64.encode(vectorBytes('issuerDer')).substring(0, 60))));
    expect(h.listener.binds, 0);
    expect(h.nativePeer.calls, 0);
    expect(() => TlsBudgets(handshakes: 3), throwsA(anything));
    expect(() => TlsBudgets(protocolBytes: 16 * 1024 * 1024 + 1),
        throwsA(anything));
  });
  test(
      'B1 key, anchor, role and validity failures never produce a context plan',
      () {
    for (final mode in ['key', 'anchor', 'role', 'expired', 'signature']) {
      expect(
          () => TlsContextPlan.validate(
              role: TlsPeerRole.server,
              leafDer: mode == 'role'
                  ? vectorBytes('clientDer')
                  : mode == 'signature'
                      ? (vectorBytes('serverDer')..last ^= 1)
                      : vectorBytes('serverDer'),
              issuerDer: vectorBytes('issuerDer'),
              privateKeyDer:
                  mode == 'key' ? Uint8List(16) : init.publicFixtureKey(),
              independentlyPinnedIssuer: mode == 'anchor'
                  ? vectorBytes('clientDer')
                  : vectorBytes('issuerDer'),
              signDigest: h.pairing.native.sign,
              verifyDigest: h.pairing.native.verify,
              utcNow: () => mode == 'expired'
                  ? DateTime.utc(2050)
                  : h.pairing.native.now),
          throwsA(anything));
    }
  });
  test(
      'B1 Owner -> credentials -> bind -> confirmed P26 publication; no default start',
      () async {
    expect(h.listener.binds, 0);
    await h.start();
    expect(h.candidate!.isReady, isTrue);
    expect(h.pairing.native.calls.discoveryFiles.keys, containsAll([1, 2, 3]));
    expect(h.listener.binds, 1);
    await h.candidate!.shutdown();
    expect(h.candidate!.isReady, isFalse);
  });
  test(
      'B1 wrong actual address, port or sharing closes candidate before publication',
      () async {
    h.listener.address = '0.0.0.0';
    await expectLater(h.start(), throwsA(anything));
    expect(h.listener.closes, 1);
    expect(h.pairing.native.calls.discoveryFiles, isEmpty);
  });
  test(
      'B2 actual peer digest maps protected P20 -> opaque Profile -> distinct P15 Session',
      () async {
    await h.enable();
    final channel = MemoryTlsChannel(vectorBytes('clientDer'));
    final binding = await h.verifier.authenticate(channel, h.plan);
    expect(binding.session.principal.profileId,
        h.pairing.local.reference.profileId);
    expect(binding.isLive, isTrue);
    expect(h.nativePeer.roles, [2]);
    await expectLater(
        h.verifier.authenticate(channel, h.plan), throwsA(anything));
    await channel.close();
    expect(binding.isLive, isFalse);
    channel.open = true;
    expect(binding.isLive, isFalse);
    expect(await binding.authenticate(), isNull);
  });
  test(
      'B2 pairing alone, disabled Profile, unregistered leaf and Native rejection deny',
      () async {
    await h.pairing.complete();
    await expectLater(
        h.verifier
            .authenticate(MemoryTlsChannel(vectorBytes('clientDer')), h.plan),
        throwsA(anything));
    final tbs = ExternalCertificateDer.buildTbs(
        role: ExternalCertificateRole.client,
        serial16: Uint8List.fromList(List.filled(16, 33)),
        generationUtc: h.pairing.native.now,
        publicKey: vectorBytes('point'));
    final unregistered = ExternalCertificateDer.assemble(
        role: ExternalCertificateRole.client,
        tbs: tbs,
        rawSignature: pair.signPublicFixture(
            pkcs8Der: init.publicFixtureKey(),
            publicPoint: vectorBytes('point'),
            digest: init.digest(tbs)));
    await expectLater(
        h.verifier.authenticate(MemoryTlsChannel(unregistered), h.plan),
        throwsA(anything));
    await h.pairing.local.save();
    await h.pairing.local.coordinator
        .enable(h.pairing.local.profile, const Duration(minutes: 5));
    await expectLater(
        h.verifier.authenticate(MemoryTlsChannel(unregistered), h.plan),
        throwsA(anything));
    h.nativePeer.status = 8;
    await expectLater(
        h.verifier
            .authenticate(MemoryTlsChannel(vectorBytes('clientDer')), h.plan),
        throwsA(anything));
  });
  test('B2 Policy revision and Disable invalidate evidence without revival',
      () async {
    await h.enable();
    final binding = await h.verifier
        .authenticate(MemoryTlsChannel(vectorBytes('clientDer')), h.plan);
    await h.pairing.local.save();
    expect(await binding.authenticate(), isNull);
    expect(binding.isLive, isFalse);
  });
  test('B2 Runtime shutdown kills exact connection evidence', () async {
    await h.enable();
    final binding = await h.verifier
        .authenticate(MemoryTlsChannel(vectorBytes('clientDer')), h.plan);
    await h.pairing.boundary.shutdown();
    expect(binding.isLive, isFalse);
  });
  test(
      'B3 fragmented P9 reaches unchanged P10/P8 once; coalesced second request is never dispatched',
      () async {
    await h.enable();
    await h.start();
    final channel = MemoryTlsChannel(vectorBytes('clientDer'));
    final frame =
        request('external_list_targets', {'pageSize': 20, 'cursor': null});
    channel.feed(Uint8List.sublistView(frame, 0, 7));
    channel.feed(Uint8List.fromList([...frame.sublist(7), ...frame]));
    h.listener.controller.add(MemoryRawPeer(channel));
    await channel.written.future;
    await pumpEventQueue(times: 12);
    // One request per connection: the coalesced second frame must never reach
    // a second P9/P10/P8 dispatch, and only the implementation may close.
    expect(channel.writes, hasLength(1));
    final response =
        IpcEnvelopeDecoder().consume(channel.writes.single).envelope!;
    expect(response.requestId, 'wire-id');
    expect(jsonDecode(response.payload)['error'], isNull);
    await h.candidate!.whenConnectionsSettled;
    expect(channel.open, isFalse);
    for (final kind in TlsResource.values) {
      expect(h.candidate!.budget.used(kind), 0, reason: kind.name);
    }
  });
  test('B3 unauthenticated claims never reach P9/P10 byte reads', () async {
    await h.start();
    final channel = MemoryTlsChannel();
    channel.feed(request(
        'external_list_targets', {'profile': 'claimed', 'session': 'claimed'}));
    h.listener.controller.add(MemoryRawPeer(channel));
    await h.candidate!.whenConnectionsSettled;
    expect(channel.reads, 0);
    expect(channel.writes, isEmpty);
    expect(channel.open, isFalse);
  });
  test('B3 pre-TLS Admission counts before upgrade, rejects excess handshakes',
      () async {
    await h.start();
    final peers = List.generate(
        3,
        (_) => MemoryRawPeer(MemoryTlsChannel())
          ..upgrading = Completer<TlsChannel>());
    for (final peer in peers) {
      peer.beforeUpgrade = () {
        expect(h.candidate!.budget.used(TlsResource.handshake),
            inInclusiveRange(1, 2));
      };
      h.listener.controller.add(peer);
    }
    await pumpEventQueue(times: 3);
    expect(peers.map((p) => p.upgrades), [1, 1, 0]);
    expect(h.candidate!.budget.used(TlsResource.handshake), 2);
    h.deadlines.advance(const Duration(seconds: 5));
    await pumpEventQueue(times: 3);
    expect(h.candidate!.budget.used(TlsResource.handshake),
        2); // timeout != settlement
    for (final peer in peers.take(2)) {
      peer.upgrading!.complete(peer.channel);
    }
    await h.candidate!.whenConnectionsSettled;
    expect(h.candidate!.budget.used(TlsResource.handshake), 0);
    expect(peers.every((p) => !p.channel.open), isTrue);
  });
  test(
      'B1 rejected TLS12/missing Client/unknown Anchor/forged/expired handshake never reads business bytes (WINDOWS_PENDING)',
      () async {
    await h.start();
    for (final mode in [
      'TLS12',
      'missingClient',
      'unknownAnchor',
      'forgedChain',
      'expiredChain'
    ]) {
      final channel = MemoryTlsChannel();
      final peer = MemoryRawPeer(channel)
        ..upgradeFailure = StateError('OFFLINE $mode rejection');
      h.listener.controller.add(peer);
      await h.candidate!.whenConnectionsSettled;
      expect(peer.upgrades, 1);
      expect(channel.reads, 0);
      expect(channel.writes, isEmpty);
      expect(h.nativePeer.calls, 0);
      for (final kind in TlsResource.values) {
        expect(h.candidate!.budget.used(kind), 0);
      }
    }
  });
  test(
      'B3 monotonic capacity reservations, duplicate release and global poison',
      () {
    final budget = TlsResourceBudget(TlsBudgets());
    final tokens = List.generate(8, (_) => budget.reserve(TlsResource.socket));
    expect(() => budget.reserve(TlsResource.socket), throwsA(anything));
    tokens.first.release();
    tokens.first.release();
    expect(budget.used(TlsResource.socket), 7);
    final bytes = budget.reserve(TlsResource.writeBytes, 512 * 1024);
    expect(() => budget.reserve(TlsResource.writeBytes), throwsA(anything));
    bytes.release();
    budget.invalidate();
    expect(() => budget.reserve(TlsResource.pipeline), throwsA(anything));
  });
  test(
      'B3 slow header deadline closes without freeing still-pending ownership early',
      () async {
    await h.enable();
    await h.start();
    final channel = MemoryTlsChannel(vectorBytes('clientDer'));
    channel.feed(Uint8List.fromList([83, 72]));
    h.listener.controller.add(MemoryRawPeer(channel));
    await pumpEventQueue(times: 20);
    expect(h.candidate!.budget.used(TlsResource.pipeline), 1);
    h.deadlines.advance(const Duration(seconds: 2));
    await h.candidate!.whenConnectionsSettled;
    expect(channel.open, isFalse);
    expect(h.candidate!.budget.used(TlsResource.pipeline), 0);
  });
  test('B3 cleanup failure poisons admission and retains owning socket',
      () async {
    await h.start();
    final channel = MemoryTlsChannel()..failClose = true;
    h.listener.controller.add(MemoryRawPeer(channel));
    await h.candidate!.whenConnectionsSettled;
    expect(h.candidate!.budget.isUsable, isFalse);
    expect(h.candidate!.budget.used(TlsResource.socket), 1);
    channel.failClose = false;
    // An unknown cleanup remains a failed shutdown even after the Fake's
    // failure switch changes. Settled connection Futures do not prove release.
    await expectLater(h.candidate!.shutdown(), throwsA(anything));
    await expectLater(h.candidate!.shutdown(), throwsA(anything));
    expect(h.candidate!.phase, WindowsTlsHostPhase.closing);
    expect(h.candidate!.budget.used(TlsResource.socket), 1);
    h.candidate = null; // Explicit fixture cleanup, no production close retry.
  });

  for (final mode in ['port', 'shared', 'publishUnknown']) {
    test('B1 $mode cannot leave a ready Listener', () async {
      if (mode == 'port') h.listener.onBind = () => h.listener.port = 43124;
      if (mode == 'shared') h.listener.shared = true;
      if (mode == 'publishUnknown') h.pairing.native.calls.discoveryStatus = 7;
      await expectLater(h.start(), throwsA(anything));
      expect(h.candidate!.isReady, isFalse);
      expect(h.listener.closes, 1);
      h.pairing.native.calls.discoveryStatus = 0;
    });
  }

  for (final mode in ['disable', 'expiry', 'revoke', 'snapshot', 'runtime']) {
    test('B2 $mode invalidates channel proof permanently', () async {
      await h.enable();
      final binding = await h.verifier.authenticate(MemoryTlsChannel(), h.plan);
      if (mode == 'disable') {
        await h.pairing.local.coordinator.disable(h.pairing.local.profile);
      } else if (mode == 'expiry') {
        h.pairing.advance(const Duration(minutes: 6));
      } else if (mode == 'revoke') {
        await h.pairing.associations.revoke(
            profileId: h.pairing.local.reference.profileId,
            expectedRevision: 1,
            validateManagement: () async {});
      } else if (mode == 'snapshot') {
        h.pairing.native.calls.associationReadStatus = 4;
        await expectLater(
            h.pairing.associations.read(h.pairing.local.reference.profileId),
            throwsA(anything));
        h.pairing.native.calls.associationReadStatus = 0;
      } else {
        h.pairing.local.trust.restart();
      }
      expect(binding.isLive, isFalse);
      if (mode == 'disable') {
        await h.pairing.local.coordinator
            .enable(h.pairing.local.profile, const Duration(minutes: 1));
      }
      expect(binding.isLive, isFalse);
      expect(await binding.authenticate(), isNull);
    });
  }

  for (final mode in ['header', 'id', 'body', 'length', 'utf8', 'version']) {
    test('B3 strict P9 $mode failure closes before business projection',
        () async {
      await h.enable();
      await h.start();
      final channel = MemoryTlsChannel()..eof = true;
      var frame =
          request('external_list_targets', {'pageSize': 20, 'cursor': null});
      if (mode == 'header') frame = frame.sublist(0, 3);
      if (mode == 'id') frame = frame.sublist(0, 17);
      if (mode == 'body') frame = frame.sublist(0, frame.length - 1);
      if (mode == 'length') {
        ByteData.sublistView(frame)
            .setUint32(12, IpcEnvelopeLimits.requestBytes + 1);
      }
      if (mode == 'utf8') frame[16 + frame[8]] = 0xff;
      if (mode == 'version') frame[4] = 2;
      channel.feed(frame);
      h.listener.controller.add(MemoryRawPeer(channel));
      await h.candidate!.whenConnectionsSettled;
      expect(channel.writes, isEmpty);
      expect(channel.open, isFalse);
      expect(h.candidate!.budget.used(TlsResource.pipeline), 0);
    });
  }

  test('B3 claim-derived authority and malformed JSON are rejected by P10',
      () async {
    await h.enable();
    await h.start();
    for (final text in ['{', '{"profile":"forged","session":"forged"}']) {
      final channel = MemoryTlsChannel();
      channel
          .feed(IpcEnvelopeCodec.encodeRequest('not-a-submission-key', text));
      h.listener.controller.add(MemoryRawPeer(channel));
      await channel.written.future;
      final response =
          IpcEnvelopeDecoder().consume(channel.writes.single).envelope!;
      expect(jsonDecode(response.payload)['error'], 'invalidRequest');
      await h.settle(channel);
    }
  });

  test(
      'B3 global pipelines reject a third channel before reads, reduced socket cap pauses accepts',
      () async {
    await h.enable();
    await h.start(limits: TlsBudgets(sockets: 3));
    final channels = List.generate(3, (_) => MemoryTlsChannel());
    for (final channel in channels) {
      h.listener.controller.add(MemoryRawPeer(channel));
      await pumpEventQueue(times: 16);
    }
    expect(h.candidate!.budget.used(TlsResource.pipeline), 2);
    expect(channels.last.reads, 0);
    expect(channels.last.open, isFalse);
    for (final channel in channels) {
      await channel.close();
    }
    await h.candidate!.whenConnectionsSettled;
  });

  test('B3 write queue overflow rejects instead of queuing', () async {
    await h.enable();
    await h.start(limits: TlsBudgets(writeBytes: 65537));
    final channel = MemoryTlsChannel();
    channel.feed(
        request('external_list_targets', {'pageSize': 20, 'cursor': null}));
    h.listener.controller.add(MemoryRawPeer(channel));
    await h.candidate!.whenConnectionsSettled;
    expect(channel.writes, isEmpty);
    expect(channel.open, isFalse);
    expect(h.candidate!.budget.used(TlsResource.writeBytes), 0);
  });

  test('B3 slow progress cannot renew the ten-second total frame deadline',
      () async {
    await h.enable();
    await h.start();
    final channel = MemoryTlsChannel();
    channel.feed(Uint8List.fromList([83]));
    h.listener.controller.add(MemoryRawPeer(channel));
    await pumpEventQueue(times: 16);
    for (var i = 0; i < 9; i++) {
      h.deadlines.advance(const Duration(seconds: 1));
      channel.feed(Uint8List.fromList([
        i == 0
            ? 72
            : i == 1
                ? 73
                : i == 2
                    ? 80
                    : 0
      ]));
      await pumpEventQueue(times: 3);
    }
    h.deadlines.advance(const Duration(seconds: 1));
    await h.candidate!.whenConnectionsSettled;
    expect(channel.open, isFalse);
    expect(channel.writes, isEmpty);
  });

  test(
      'B3 Channel Close during committed STAGE retains owning slot and never retries',
      () async {
    await h.enable();
    final reached = Completer<void>(), resume = Completer<void>();
    h.pairing.local.checkpoint = (point) async {
      if (point.name == 'afterCommit') {
        reached.complete();
        await resume.future;
      }
    };
    await h.start(context: (session) async {
      final entry = await h.pairing.local.coordinator.host.bindSession(session);
      final stage = await h.pairing.local.stages
          .approveTarget(session, h.pairing.local.local.h.target, []);
      return h.pairing.local.coordinator.host.openStage(entry, stage);
    });
    final channel = MemoryTlsChannel();
    channel.feed(request(
        'external_stage_generated_questions',
        {
          'submissionJson': submission(key: 'original-business-key'),
          'externalRequestId': null
        },
        'different-envelope-id'));
    h.listener.controller.add(MemoryRawPeer(channel));
    await reached.future;
    await channel.close();
    await pumpEventQueue(times: 5);
    expect(h.candidate!.budget.used(TlsResource.pipeline), 1);
    expect(
        await h.pairing.local.local.h.count('generated_question_proposals'), 1);
    resume.complete();
    await h.candidate!.whenConnectionsSettled;
    expect(channel.writes, isEmpty);
    expect(h.candidate!.budget.used(TlsResource.pipeline), 0);
    expect(
        await h.pairing.local.local.h.count('generated_question_proposals'), 1);
    expect(
        await h.pairing.local.local.h
            .count('generated_question_commit_receipts'),
        0);
  });

  test(
      'B3 cleanup failure still waits committed STAGE owner before reporting shutdown failure',
      () async {
    await h.enable();
    final reached = Completer<void>(), resume = Completer<void>();
    h.pairing.local.checkpoint = (point) async {
      if (point.name == 'afterCommit') {
        reached.complete();
        await resume.future;
      }
    };
    await h.start(context: (session) async {
      final entry = await h.pairing.local.coordinator.host.bindSession(session);
      final stage = await h.pairing.local.stages
          .approveTarget(session, h.pairing.local.local.h.target, []);
      return h.pairing.local.coordinator.host.openStage(entry, stage);
    });
    final channel = MemoryTlsChannel()..failClose = true;
    channel.feed(request('external_stage_generated_questions', {
      'submissionJson': submission(key: 'cleanup-owning-key'),
      'externalRequestId': null
    }));
    h.listener.controller.add(MemoryRawPeer(channel));
    await reached.future;
    var returned = false;
    final shutdown = h.candidate!.shutdown();
    final expectedFailure = expectLater(shutdown, throwsA(anything))
        .whenComplete(() => returned = true);
    await pumpEventQueue(times: 8);
    expect(returned, isFalse);
    expect(h.candidate!.budget.used(TlsResource.pipeline), 1);
    resume.complete();
    await expectedFailure;
    expect(h.candidate!.budget.isUsable, isFalse);
    expect(
        await h.pairing.local.local.h.count('generated_question_proposals'), 1);
    expect(channel.writes, isEmpty);
    h.candidate = null; // do not retry failed cleanup in test teardown
  });

  for (final mode in [
    'valid',
    'wrongRole',
    'wrongDigest',
    'epochRollback',
    'mixedEndpoint'
  ]) {
    test(
        'B4 signed P26 + existing kind4 + Native role + exact Server DER digest $mode',
        () async {
      final completion = await h.pairing.complete();
      h.pairing.bridge.confirmIndependentlyComparedCompletionAndSave(
          h.pairing.enrollment,
          committedRevision: completion.revision,
          comparedDigest: completion.digest);
      await h.start();
      if (mode == 'epochRollback') {
        final old = h.pairing.bridgeStore.read(4)! as ExternalBridgeClient;
        try {
          h.pairing.bridgeStore.write(ExternalBridgeClient(
              clientPkcs8Der: old.clientPkcs8Der,
              clientLeafDer: old.clientLeafDer,
              issuerCertificateDer: old.issuerCertificateDer,
              pinnedInstallationId: old.pinnedInstallationId,
              pinnedDiscoveryEpochHighWater: BigInt.from(3)));
        } finally {
          old.clientPkcs8Der.fillRange(0, old.clientPkcs8Der.length, 0);
        }
      }
      var serverDer = vectorBytes('serverDer');
      if (mode == 'wrongDigest') {
        final tbs = ExternalCertificateDer.buildTbs(
            role: ExternalCertificateRole.server,
            serial16: Uint8List.fromList(List.filled(16, 33)),
            generationUtc: h.pairing.native.now,
            publicKey: vectorBytes('point'));
        serverDer = ExternalCertificateDer.assemble(
            role: ExternalCertificateRole.server,
            tbs: tbs,
            rawSignature: pair.signPublicFixture(
                pkcs8Der: init.publicFixtureKey(),
                publicPoint: vectorBytes('point'),
                digest: init.digest(tbs)));
      }
      final io = MemoryBridgeIo(MemoryTlsChannel(
          mode == 'wrongRole' ? vectorBytes('clientDer') : serverDer));
      final reader = WindowsDiscoveryReader(h.pairing.bridgeOwner, verifier: (
          {required publicPoint, required digest, required rawSignature}) {
        h.pairing.native.verify(
            publicPoint: publicPoint,
            digest: digest,
            rawSignature: rawSignature);
        return true;
      });
      final bridge = WindowsTlsBridge(
          io: io,
          reader: reader,
          owner: h.pairing.bridgeOwner,
          trusted: DiscoveryExpectations(
              trustedAnchorDer: vectorBytes('issuerDer'),
              installationId: bootstrapVector['installationId'] as String,
              serverLeafDigest:
                  mode == 'mixedEndpoint' ? Uint8List(32) : h.plan.leafDigest,
              verifiedEpochHighWater: BigInt.one),
          signDigest: h.pairing.native.sign,
          verifyDigest: h.pairing.native.verify,
          nativePolicy: WindowsPeerCertificatePolicy(h.nativePeer).check,
          utcNow: () => h.pairing.native.now,
          compositionIsCurrent: () => h.pairing.current);
      expect(bridge.isLive, isFalse);
      if (mode != 'valid') {
        await expectLater(bridge.connect(), throwsA(anything));
      } else {
        await bridge.connect();
        expect(bridge.isLive, isTrue);
      }
      final connected = mode != 'epochRollback' && mode != 'mixedEndpoint';
      expect(io.calls, connected ? 1 : 0);
      if (connected) {
        expect(io.port, h.listener.port);
        expect(h.nativePeer.roles.last, 1);
      }
      await bridge.close();
      await bridge.close();
      expect(bridge.isLive, isFalse);
      expect(io.channel.closeCalls, connected ? 1 : 0);
      final saved = h.pairing.bridgeStore.read(4)! as ExternalBridgeClient;
      expect(
          saved.pinnedDiscoveryEpochHighWater,
          BigInt.from(mode == 'epochRollback'
              ? 3
              : mode == 'mixedEndpoint'
                  ? 1
                  : 2));
      saved.clientPkcs8Der.fillRange(0, saved.clientPkcs8Der.length, 0);
    });
  }
}
