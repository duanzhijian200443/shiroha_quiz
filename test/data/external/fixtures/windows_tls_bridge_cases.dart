import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'package:shiroha_quiz/data/external/windows_discovery.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../../application/external/external_question_read_test_support.dart';
import '../bootstrap_test_support.dart';
import '../windows_tls_transport_test.dart' as tls;

// The existing Fake channel carries bytes both ways; no business result is
// substituted. Only the existing Host/P10/P8 and real SQLite produce replies.
final class LinkedChannel extends tls.MemoryTlsChannel {
  LinkedChannel(super.der);
  LinkedChannel? peer;
  Uint8List Function(Uint8List)? transform;
  bool abortPeer = false;
  bool _peerEnded = false;
  void Function(int)? beforeRead;
  @override
  void endInput() {
    _peerEnded = true;
    super.endInput();
    if (chunks.isEmpty) open = false;
  }

  @override
  Future<Uint8List?> read(int maximum) async {
    beforeRead?.call(maximum);
    final bytes = await super.read(maximum);
    // RawSecureSocket emits readClosed only after its plaintext is drained.
    // The close event can precede the Bridge's final EOF read/continuation.
    if (_peerEnded && chunks.isEmpty) open = false;
    return bytes;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    await super.write(bytes);
    final output = transform?.call(bytes) ?? bytes;
    // Memory channels retain only test-owned bytes.
    peer?.feed(output);
  }

  @override
  Future<void> close() async {
    await super.close();
    if (abortPeer) peer?.open = false;
    peer?.endInput();
  }
}

final class BridgeFixture {
  BridgeFixture(this.h);
  final tls.TlsHarness h;
  final client = LinkedChannel(vectorBytes('serverDer'));
  final server = LinkedChannel(vectorBytes('clientDer'));
  late WindowsTlsBridge bridge;
  late tls.MemoryBridgeIo io;
  void Function()? beforePeerPolicy;
  Future<void> open(
      {TlsTrustedContext? context,
      IpcTrustedContextBinding? binding,
      bool enableStageApprovalWait = false,
      bool prepare = true,
      Future<void> Function()? configureGrant,
      bool enabled = true,
      TlsBudgets? limits,
      bool attachHost = true}) async {
    if (prepare) {
      final completion = await h.pairing.complete();
      h.pairing.bridge.confirmIndependentlyComparedCompletionAndSave(
          h.pairing.enrollment,
          committedRevision: completion.revision,
          comparedDigest: completion.digest);
      if (enabled) {
        await h.pairing.local.save();
        await configureGrant?.call();
        await h.pairing.local.coordinator
            .enable(h.pairing.local.profile, const Duration(minutes: 5));
        await h.pairing.local.coordinator.startOffline();
      }
      await h.start(
          context: context,
          binding: binding,
          enableStageApprovalWait: enableStageApprovalWait && binding != null);
    }
    client.peer = server;
    client.abortPeer = true;
    server.peer = client;
    io = tls.MemoryBridgeIo(client);
    bridge = WindowsTlsBridge(
        enableStageApprovalWait: enableStageApprovalWait,
        io: io,
        reader: WindowsDiscoveryReader(h.pairing.bridgeOwner, verifier: (
            {required publicPoint, required digest, required rawSignature}) {
          h.pairing.native.verify(
              publicPoint: publicPoint,
              digest: digest,
              rawSignature: rawSignature);
          return true;
        }),
        trusted: DiscoveryExpectations(
            trustedAnchorDer: vectorBytes('issuerDer'),
            installationId: bootstrapVector['installationId'] as String,
            serverLeafDigest: h.plan.leafDigest,
            verifiedEpochHighWater: BigInt.one),
        owner: h.pairing.bridgeOwner,
        signDigest: h.pairing.native.sign,
        verifyDigest: h.pairing.native.verify,
        nativePolicy: (der, role) {
          beforePeerPolicy?.call();
          WindowsPeerCertificatePolicy(h.nativePeer).check(der, role);
        },
        utcNow: () => h.pairing.native.now,
        monotonicNow: () => h.deadlines.now,
        schedule: h.deadlines.schedule,
        compositionIsCurrent: () => h.pairing.current,
        limits: limits);
    await bridge.connect();
    addTearDown(() async {
      client.writing?.complete();
      client.writing = null;
      client.closing?.complete();
      client.closing = null;
      if (client.failClose) {
        await expectLater(bridge.close(), throwsA(anything));
      } else {
        await bridge.close();
      }
    });
    if (attachHost) h.listener.controller.add(tls.MemoryRawPeer(server));
  }

  Future<UntrustedIpcEnvelope> call(String name, Object input,
          {String id = 'bridge-id'}) =>
      bridge.request(
          requestId: id,
          payload: jsonEncode({
            'schemaVersion': 1,
            'type': 'command',
            'capability': name,
            'input': input
          }));
  Future<UntrustedIpcEnvelope> read() =>
      call('external_list_targets', {'pageSize': 20, 'cursor': null});
  void released() {
    for (final kind in TlsResource.values) {
      expect(bridge.budget.used(kind), 0, reason: kind.name);
    }
    expect(bridge.isLive, isFalse);
    expect(io.calls, 1);
  }
}

Matcher transportFailure(TlsBridgeFailure failure,
        {bool unknown = true, IpcProtocolFailure? protocol}) =>
    throwsA(isA<TlsBridgeException>()
        .having((e) => e.failure, 'fixed failure', failure)
        .having((e) => e.executionUnknown, 'execution unknown', unknown)
        .having((e) => e.protocolFailure, 'protocol failure', protocol));

void bridgeCases(tls.TlsHarness Function() harness) {
  group('bounded Bridge P9/P10 client', () {
    late tls.TlsHarness h;
    late BridgeFixture f;
    setUp(() {
      h = harness();
      f = BridgeFixture(h);
    });

    test('authorized READ uses real Host and closes after matching response',
        () async {
      await f.open();
      final response = await f.read();
      expect(response.requestId, 'bridge-id');
      expect(response.kind, IpcMessageKind.response);
      final body = jsonDecode(response.payload) as Map;
      expect(body['error'], isNull);
      expect((body['data'] as Map)['items'], isNotEmpty);
      await h.candidate!.whenConnectionsSettled;
      f.released();
      expect(() => f.read(),
          transportFailure(TlsBridgeFailure.unavailable, unknown: false));
      expect(() => f.bridge.connect(), throwsA(anything));
    });

    for (final mode in [
      'silence',
      'response-progress',
      'response-total',
      'upload'
    ]) {
      test(
          'explicit STAGE wait bounds $mode without renewing ordinary requests',
          () async {
        await f.open(attachHost: false, enableStageApprovalWait: true);
        if (mode == 'upload') f.client.writing = Completer<void>();
        final pending = f.bridge.requestStageApproval(
            requestId: 'stage-window', buildPayload: () => '{}');
        final failure =
            expectLater(pending, transportFailure(TlsBridgeFailure.timedOut));
        await f.client.written.future;
        await pumpEventQueue(times: 4);
        if (mode == 'upload') {
          h.deadlines.advance(const Duration(seconds: 2));
        } else {
          h.deadlines.advance(const Duration(seconds: 11));
          expect(f.bridge.isLive, isTrue);
          if (mode == 'silence') {
            h.deadlines.advance(const Duration(seconds: 121));
          } else {
            final header =
                IpcEnvelopeCodec.encodeResponse('stage-window', '{}');
            f.client.feed(Uint8List.fromList([header[0]]));
            await pumpEventQueue(times: 4);
            if (mode == 'response-progress') {
              h.deadlines.advance(const Duration(seconds: 2));
            } else {
              for (var i = 1; i < 10; i++) {
                h.deadlines.advance(const Duration(seconds: 1));
                f.client.feed(Uint8List.fromList([header[i]]));
                await pumpEventQueue(times: 2);
              }
              h.deadlines.advance(const Duration(seconds: 1));
            }
          }
        }
        await failure;
        if (mode == 'upload') {
          expect(f.bridge.budget.used(TlsResource.pipeline), 1);
          f.client.writing!.complete();
          f.client.writing = null;
        }
        await f.bridge.close();
        f.released();
      });
    }

    test('server verification must finish before request admission', () async {
      var checked = false;
      f.beforePeerPolicy = () {
        checked = true;
        expect(f.bridge.isLive, isFalse);
        expect(() => f.read(),
            transportFailure(TlsBridgeFailure.unavailable, unknown: false));
        expect(f.client.writes, isEmpty);
      };
      await f.open();
      expect(checked, isTrue);
      expect((jsonDecode((await f.read()).payload) as Map)['error'], isNull);
      f.released();
    });

    test('normal peer close before final EOF read accepts the matched response',
        () async {
      await f.open(attachHost: false);
      f.client.feed(IpcEnvelopeCodec.encodeResponse('bridge-id', '{}'));
      f.client.endInput();
      var checkedEof = false;
      f.client.beforeRead = (maximum) {
        if (maximum != 1) return;
        checkedEof = true;
        expect(f.client.isOpen, isFalse);
        expect(f.bridge.isLive, isFalse);
      };
      final result = await f.read();
      expect(result.payload, '{}');
      expect(checkedEof, isTrue);
      expect(f.client.writes, hasLength(1));
      f.released();
    });

    test('peer EOF before request admission sends nothing', () async {
      await f.open(attachHost: false);
      f.client.endInput();
      expect(() => f.read(),
          transportFailure(TlsBridgeFailure.unavailable, unknown: false));
      expect(f.client.writes, isEmpty);
      await f.bridge.close();
      f.released();
    });

    for (final mode in [
      'clean',
      'cancel',
      'replacement',
      'expiry',
      'timeout'
    ]) {
      test('$mode while awaiting final EOF preserves result and drain rules',
          () async {
        await f.open(attachHost: false);
        f.client.feed(IpcEnvelopeCodec.encodeResponse('bridge-id', '{}'));
        final reachedEof = Completer<void>();
        f.client.beforeRead = (maximum) {
          if (maximum == 1) reachedEof.complete();
        };
        final pending = f.read();
        final assertion = mode == 'clean'
            ? expectLater(pending, completion(isA<UntrustedIpcEnvelope>()))
            : expectLater(
                pending,
                transportFailure(switch (mode) {
                  'cancel' => TlsBridgeFailure.cancelled,
                  'timeout' => TlsBridgeFailure.timedOut,
                  _ => TlsBridgeFailure.responseLost,
                }));
        await reachedEof.future;
        expect(f.client.reading, isNotNull);
        expect(f.bridge.budget.used(TlsResource.pipeline), 1);
        if (mode == 'cancel') unawaited(f.bridge.close());
        if (mode == 'replacement') h.pairing.current = false;
        if (mode == 'expiry') h.pairing.native.now = DateTime.utc(9999);
        if (mode == 'timeout') {
          h.deadlines.advance(const Duration(seconds: 2));
        }
        f.client.endInput();
        expect(f.client.isOpen, isFalse);
        await assertion;
        await f.bridge.close();
        expect(f.client.writes, hasLength(1));
        f.released();
      });
    }

    test('trusted STAGE Context publishes once with original business key',
        () async {
      await f.open(context: (session) async {
        final host = h.pairing.local.coordinator.host;
        final stage = await h.pairing.local.stages
            .approveTarget(session, h.pairing.local.local.h.target, []);
        return host.openStage(await host.bindSession(session), stage);
      });
      final result = await f.call('external_stage_generated_questions', {
        'submissionJson': submission(key: 'bridge-original-key'),
        'externalRequestId': null,
      });
      final body = jsonDecode(result.payload) as Map;
      expect(body['error'], isNull);
      expect((body['data'] as Map)['submissionKey'], 'bridge-original-key');
      expect((body['data'] as Map)['publication'], 'STAGED');
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          1);
      expect(
          await h.pairing.local.local.h
              .count('generated_question_commit_receipts'),
          0);
      f.released();
    });

    test('no finite enablement yields no business response or Session',
        () async {
      await f.open(enabled: false);
      await expectLater(
          f.read(),
          transportFailure(TlsBridgeFailure.protocol,
              protocol: IpcProtocolFailure.truncated));
      await f.bridge.close();
      expect(f.server.writes, isEmpty);
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          0);
      f.released();
    });

    for (final mode in [
      'id',
      'magic',
      'kind',
      'length',
      'utf8',
      'truncated',
      'duplicate',
      'trailing',
      'protocol'
    ]) {
      test('rejects $mode response with no retry or execution inference',
          () async {
        await f.open();
        final protocol = switch (mode) {
          'id' => IpcProtocolFailure.invalidId,
          'magic' ||
          'duplicate' ||
          'trailing' =>
            IpcProtocolFailure.invalidFrame,
          'kind' => IpcProtocolFailure.unsupportedMessage,
          'length' => IpcProtocolFailure.resourceLimit,
          'utf8' => IpcProtocolFailure.invalidUtf8,
          'truncated' => IpcProtocolFailure.truncated,
          _ => IpcProtocolFailure.unsupportedVersion,
        };
        f.server.transform = (bytes) {
          final frame = Uint8List.fromList(bytes);
          switch (mode) {
            case 'id':
              frame[16] ^= 1;
            case 'magic':
              frame[0] = 0;
            case 'kind':
              frame[5] = 1;
            case 'length':
              ByteData.sublistView(frame)
                  .setUint32(12, IpcEnvelopeLimits.responseBytes + 1);
            case 'utf8':
              frame.last = 0xff;
            case 'truncated':
              return Uint8List.sublistView(frame, 0, frame.length - 1);
            case 'duplicate':
              return Uint8List.fromList([...frame, ...frame]);
            case 'trailing':
              return Uint8List.fromList([...frame, 0]);
            case 'protocol':
              return IpcEnvelopeCodec.encodeError(protocol);
          }
          return frame;
        };
        await expectLater(f.read(),
            transportFailure(TlsBridgeFailure.protocol, protocol: protocol));
        await f.bridge.close();
        expect(f.client.writes, hasLength(1));
        f.released();
      });
    }

    test('invalid request ID sends nothing and consumes this connection',
        () async {
      await f.open(attachHost: false);
      await expectLater(
          f.bridge.request(requestId: 'invalid id', payload: '{}'),
          transportFailure(TlsBridgeFailure.invalidRequest,
              unknown: false, protocol: IpcProtocolFailure.invalidId));
      await f.bridge.close();
      expect(f.client.writes, isEmpty);
      f.released();
    });

    test('READ Context cannot supply STAGE authority', () async {
      await f.open();
      final result = await f.call('external_stage_generated_questions', {
        'submissionJson': submission(key: 'no-approval'),
        'externalRequestId': null,
      });
      expect((jsonDecode(result.payload) as Map)['data'], isNull);
      expect((jsonDecode(result.payload) as Map)['error'], isNotNull);
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          0);
      f.released();
    });

    test('fragmented maximum response and maximum request retain P9 ceilings',
        () async {
      await f.open(attachHost: false);
      final text = 'x' * IpcEnvelopeLimits.responseBytes;
      final response = IpcEnvelopeCodec.encodeResponse('bridge-id', text);
      for (var offset = 0; offset < response.length; offset += 13) {
        f.client.feed(Uint8List.sublistView(response, offset,
            offset + 13 < response.length ? offset + 13 : response.length));
      }
      f.client.endInput();
      final result = await f.bridge.request(
          requestId: 'bridge-id',
          payload: 'x' * IpcEnvelopeLimits.requestBytes);
      expect(result.payload, text);
      expect(f.client.writes.map((b) => b.length),
          everyElement(lessThanOrEqualTo(65536)));
      expect(
          f.client.writes.fold<int>(0, (total, bytes) => total + bytes.length),
          IpcEnvelopeLimits.requestBytes + 16 + 'bridge-id'.length);
      f.released();
    });

    test('reduced budget rejects before sending, without enlarging ceilings',
        () async {
      await f.open(attachHost: false, limits: TlsBudgets(protocolBytes: 65536));
      await expectLater(f.read(),
          transportFailure(TlsBridgeFailure.unavailable, unknown: false));
      await f.bridge.close();
      expect(f.client.writes, isEmpty);
      f.released();
    });

    for (final mode in ['idle', 'total', 'replacement']) {
      test('$mode during response reading invalidates response availability',
          () async {
        await f.open(attachHost: false);
        final expected = expectLater(
            f.read(),
            transportFailure(mode == 'replacement'
                ? TlsBridgeFailure.responseLost
                : TlsBridgeFailure.timedOut));
        await pumpEventQueue(times: 4);
        if (mode == 'replacement') {
          h.pairing.current = false;
          f.client.feed(Uint8List.fromList([83]));
        } else if (mode == 'idle') {
          h.deadlines.advance(const Duration(seconds: 2));
        } else {
          final header = IpcEnvelopeCodec.encodeResponse('bridge-id', '{}');
          for (var i = 0; i < 9; i++) {
            h.deadlines.advance(const Duration(seconds: 1));
            f.client.feed(Uint8List.fromList([header[i]]));
            await pumpEventQueue(times: 2);
          }
          h.deadlines.advance(const Duration(seconds: 1));
        }
        await expected;
        await f.bridge.close();
        f.released();
      });
    }

    test('unacknowledged close keeps reservations until acknowledgement',
        () async {
      await f.open(attachHost: false);
      f.client.closing = Completer<void>();
      final assertion =
          expectLater(f.read(), transportFailure(TlsBridgeFailure.cancelled));
      await f.client.written.future;
      var closed = false;
      final closing = f.bridge.close().whenComplete(() => closed = true);
      await assertion;
      await pumpEventQueue(times: 4);
      expect(closed, isFalse);
      expect(f.bridge.budget.used(TlsResource.socket), 1);
      expect(f.bridge.budget.used(TlsResource.pipeline), 1);
      f.client.closing!.complete();
      f.client.closing = null;
      await closing;
      f.released();
    });

    test('failed close still drains write and poisons uncertain reservations',
        () async {
      await f.open(attachHost: false);
      f.client.writing = Completer<void>();
      final assertion =
          expectLater(f.read(), transportFailure(TlsBridgeFailure.cancelled));
      await f.client.written.future;
      f.client.failClose = true;
      var closed = false;
      final closing = expectLater(f.bridge.close(), throwsA(anything))
          .whenComplete(() => closed = true);
      await assertion;
      await pumpEventQueue(times: 4);
      expect(closed, isFalse);
      expect(f.bridge.budget.isUsable, isFalse);
      f.client.writing!.complete();
      f.client.writing = null;
      await closing;
      expect(f.bridge.budget.used(TlsResource.socket), 1);
      expect(f.bridge.budget.used(TlsResource.pipeline), 1);
      // Preserve failed close evidence rather than retry it in generic teardown.
    });

    test(
        'request bytes are chunked at 64 KiB; duplicate request rejected in flight',
        () async {
      await f.open();
      f.client.writing = Completer<void>();
      final pending =
          f.bridge.request(requestId: 'large', payload: ' ' * 140000);
      expect(() => f.read(),
          transportFailure(TlsBridgeFailure.unavailable, unknown: false));
      f.client.writing!.complete();
      f.client.writing = null;
      final response = await pending;
      expect((jsonDecode(response.payload) as Map)['error'], 'invalidRequest');
      expect(f.client.writes.length, 3);
      expect(f.client.writes.map((b) => b.length),
          everyElement(lessThanOrEqualTo(65536)));
      f.released();
    });

    for (final mode in ['timeout', 'cancel', 'disconnect']) {
      test(
          '$mode invalidates old request and retains pending write reservation',
          () async {
        await f.open(attachHost: false);
        f.client.writing = Completer<void>();
        final pending = f.read();
        final assertion = expectLater(
            pending,
            transportFailure(switch (mode) {
              'timeout' => TlsBridgeFailure.timedOut,
              'cancel' => TlsBridgeFailure.cancelled,
              _ => TlsBridgeFailure.responseLost,
            }));
        await f.client.written.future;
        if (mode == 'timeout') h.deadlines.advance(const Duration(seconds: 2));
        if (mode == 'cancel') unawaited(f.bridge.close());
        if (mode == 'disconnect') await f.client.close();
        if (mode != 'disconnect') await assertion;
        expect(f.bridge.budget.used(TlsResource.pipeline), 1);
        expect(f.bridge.budget.used(TlsResource.socket), 1);
        expect(() => f.read(),
            transportFailure(TlsBridgeFailure.unavailable, unknown: false));
        f.client.writing!.complete();
        f.client.writing = null;
        await assertion;
        await f.bridge.close();
        f.released();
      });
    }

    test('lost committed STAGE keeps Host settlement and original-key recovery',
        () async {
      final reached = Completer<void>(), resume = Completer<void>();
      addTearDown(() {
        if (!resume.isCompleted) resume.complete();
      });
      h.pairing.local.checkpoint = (point) async {
        if (point.name == 'afterCommit') {
          reached.complete();
          await resume.future;
        }
      };
      await f.open(context: (session) async {
        final host = h.pairing.local.coordinator.host;
        final stage = await h.pairing.local.stages
            .approveTarget(session, h.pairing.local.local.h.target, []);
        return host.openStage(await host.bindSession(session), stage);
      });
      final assertion = expectLater(
          f.call('external_stage_generated_questions', {
            'submissionJson': submission(key: 'lost-bridge-key'),
            'externalRequestId': null,
          }),
          transportFailure(TlsBridgeFailure.cancelled));
      await reached.future;
      await f.bridge.close();
      await assertion;
      expect(h.candidate!.budget.used(TlsResource.pipeline), 1);
      expect(f.client.writes, hasLength(1));
      resume.complete();
      await h.candidate!.whenConnectionsSettled;
      expect(h.candidate!.budget.used(TlsResource.pipeline), 0);
      expect(f.server.writes, isEmpty);
      final binding =
          await h.verifier.authenticate(tls.MemoryTlsChannel(), h.plan);
      final host = h.pairing.local.coordinator.host;
      final entry = await host.bindSession(binding.session);
      final context = await host.openReconciliation(entry, 'lost-bridge-key');
      // Reconciliation stays an explicit trusted App action, never a Bridge retry.
      final result = await host.dispatch(
          ExternalCapabilities.reconcile, const ExternalNoInput(),
          entry: entry, context: context);
      expect(result.output!.submissionKey, 'lost-bridge-key');
      expect(
          await h.pairing.local.local.h.count('generated_question_proposals'),
          1);
      expect(
          await h.pairing.local.local.h
              .count('generated_question_commit_receipts'),
          0);
      f.released();
    });
  });
}
