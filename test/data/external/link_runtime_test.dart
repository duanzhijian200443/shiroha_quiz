import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_runtime.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';

final class _Backend implements LinkBackend {
  _Backend(this.owner, this.target, this.settle);
  @override
  final LinkOwnerReference owner;
  @override
  final LinkVerifiedTarget target;
  final Future<void> Function() settle;
  final lost = Completer<void>(), entered = Completer<void>();
  final response = Completer<Map<String, Object?>>();
  bool cancelled = false;
  @override
  Future<void> get disconnected => lost.future;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled}) async {
    final sub = cancelled.listen((_) => this.cancelled = true);
    entered.complete();
    try {
      return await response.future;
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> close() => settle();
}

void main() {
  late Directory root, slot;
  late LinkStateStore store;
  late LinkRuntime runtime;
  late _Backend backend;
  final target = LinkVerifiedTarget('a' * 64, 'installation', 'profile');
  var starts = 0, wrongReceipt = false, failClose = false;
  Future<void> receipt(LinkOwnerReference owner, String mode) =>
      File(p.join(slot.path, 'link-settlement.json')).writeAsString(jsonEncode({
        'formatVersion': 2,
        'operationId': 'operation',
        'receiptRef': owner.resourceId,
        'runId': owner.runId,
        'resourceId': owner.resourceId,
        'processId': owner.processId,
        'processStarted': owner.processStarted,
        'slotRef': 'phone',
        'owner': 'connector',
        'mode': mode,
        'target': target.toJson(),
        'targetClose': true,
        'tlsShutdown': true,
        'keyRetired': true,
      }));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-runtime-');
    slot = await Directory(p.join(root.path, 'slot')).create();
    final state = await Directory(p.join(root.path, 'state')).create();
    final config = LinkInstallation(
        stateDirectory: state.path,
        slotDirectory: slot.path,
        slotRef: 'phone',
        connectorInstanceId: 'connector',
        operationId: 'operation',
        adapterExecutable: p.join(root.path, 'adapter.exe'));
    final init = LinkInitialization(config, processCurrent: (_, __) => false);
    store = await init.open(initialize: true);
    await File(p.join(slot.path, 'device.dpapi'))
        .writeAsString('synthetic-only');
    const original = LinkOwnerReference(
        runId: 'pair-run',
        resourceId: 'pair-resource',
        processId: 100,
        processStarted: '123456',
        slotRef: 'phone');
    await receipt(original, 'pairing');
    await File(p.join(slot.path, 'initialization-joined.json'))
        .writeAsString(jsonEncode({
      'formatVersion': 1,
      'operationId': 'operation',
      'slotRef': 'phone',
      'ownerInstanceId': 'connector',
      'runId': original.runId,
      'resourceId': original.resourceId,
      'processId': original.processId,
      'processStarted': original.processStarted,
      'adapterReceiptRef': original.resourceId,
      'target': target.toJson(),
      'processExitCode': 0,
      'stdinClosed': true,
      'stdoutDrained': true,
      'stderrDrained': true,
    }));
    await File(p.join(slot.path, 'adapter-origin.json'))
        .writeAsString(jsonEncode({
      'formatVersion': 1,
      'slotRef': 'phone',
      'origin': 'independent_adapter_pairing',
      'operationId': 'operation',
      'target': target.toJson(),
      'credentialSlotRef': 'device.dpapi',
      'resourceGeneration': 'pair-resource',
      'settlementRef': 'pair-resource',
    }));
    await init.complete(store, target);
    starts = 0;
    wrongReceipt = false;
    failClose = false;
    runtime = LinkRuntime(
        installation: config,
        store: store,
        backendFactory: (
            {required proof,
            required runId,
            required resourceId,
            required acquired}) async {
          starts++;
          final owner = LinkOwnerReference(
              runId: runId,
              resourceId: resourceId,
              processId: 100 + starts,
              processStarted: '123456$starts',
              slotRef: 'phone');
          await acquired(owner);
          if (proof) await receipt(owner, 'enable-proof');
          backend = _Backend(owner, target, () async {
            if (failClose) throw const LinkException('owner_unsettled');
            if (!wrongReceipt) await receipt(owner, 'business');
          });
          return backend;
        });
  });
  tearDown(() async {
    try {
      await runtime.close();
    } catch (_) {/* Preserve failure verdict. */}
    await store.close();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> ownership() async => jsonDecode(
          await File(p.join(slot.path, 'slot-ownership.json')).readAsString())
      as Map<String, dynamic>;

  test(
      'normal proof and business closure settle exact resources, retaining owner generation',
      () async {
    await runtime.connect();
    expect((await ownership())['lastSettlementState'], 'CLEAN');
    await runtime.attach('peer', 'connection');
    expect((await ownership())['lastSettlementState'], 'DIRTY');
    expect(store.state.ownerGeneration, 'operation');
    await runtime.disconnect();
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    expect((await ownership())['lastSettlementState'], 'CLEAN');
    expect((await ownership())['lastSettlementRef'], backend.owner.resourceId);
    expect((await ownership())['ownerGeneration'], 'operation');
  });

  test(
      'second frontend cannot start another adapter or steal the original lease',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final lease = store.state.lease!.toJson();
    await expectLater(
        runtime.attach('second', 'other'), throwsA(isA<LinkException>()));
    expect(starts, 2);
    expect(store.state.lease!.toJson(), lease);
  });

  test('EOF joins original work and output without manufacturing cancellation',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final call = runtime.call('first', 'connection', 1, 'open_context', {});
    await backend.entered.future;
    var closed = false;
    final close = runtime.disconnect().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(backend.cancelled, isFalse);
    backend.response.complete({
      'profileVersion': 3,
      'data': {'contextRef': 'synthetic'},
      'error': null,
      'source': {'kind': 'android', 'deviceRef': target.deviceIdentity}
    });
    await call;
    await close;
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
  });

  test(
      'old proof receipt cannot clear a business resource, even when helper exits',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    final original = store.state.owner!.toJson();
    wrongReceipt = true;
    await expectLater(runtime.disconnect(), throwsA(isA<LinkException>()));
    expect(store.state.owner!.toJson(), original);
    expect(store.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    expect((await ownership())['ownershipState'], 'LINK_OWNED');
    expect((await ownership())['lastSettlementState'], 'DIRTY');
  });

  test('failed original settlement keeps dirty custody and blocks replacement',
      () async {
    await runtime.connect();
    await runtime.attach('first', 'connection');
    failClose = true;
    await expectLater(runtime.disconnect(), throwsA(isA<LinkException>()));
    await expectLater(runtime.connect(), throwsA(isA<LinkException>()));
    expect(starts, 2);
    expect(store.state.owner, isNotNull);
    expect((await ownership())['ownerGeneration'], 'operation');
  });

  test(
      'local initialization exposes original fingerprint while close still joins the active owner',
      () async {
    final freshSlot = await Directory(p.join(root.path, 'fresh-slot')).create();
    final freshState =
        await Directory(p.join(root.path, 'fresh-state')).create();
    final config = LinkInstallation(
        stateDirectory: freshState.path,
        slotDirectory: freshSlot.path,
        slotRef: 'new-phone',
        connectorInstanceId: 'new-owner',
        operationId: 'new-operation',
        adapterExecutable: p.join(root.path, 'not-started.exe'));
    final initial =
        LinkInitialization(config, processCurrent: (_, __) => false);
    final initialStore = await initial.open(initialize: true);
    final result = Completer<LinkVerifiedTarget>();
    var attempts = 0;
    final local = LinkRuntime(
        installation: config,
        store: initialStore,
        initializationFactory: (
            {required runId, required resourceId, required onFingerprint}) {
          attempts++;
          onFingerprint('a' * 64);
          return result.future;
        });
    await local.initialize();
    expect(local.inspect()['pairingClientFingerprint'], 'a' * 64);
    expect(local.inspect()['busy'], isTrue);
    expect(local.state.ownerGeneration, isNull);
    await expectLater(local.initialize(), throwsA(isA<LinkException>()));
    expect(attempts, 1);
    var ended = false;
    final closing = local.close().then<void>((_) {
      ended = true;
    }, onError: (Object _) {
      ended = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(ended, isFalse);
    result.completeError(const LinkException('initialization_incomplete'));
    await closing;
    expect(
        local.inspect()['initializationFailure'], 'initialization_incomplete');
    expect(local.state.ownerGeneration, isNull);
    await initialStore.close();
  });
}
