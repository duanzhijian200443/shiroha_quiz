import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/link/slot_ownership_store.dart';
import 'link_registration_cases.dart';

void main() {
  registrationCases();
  late Directory root, slot, stateDirectory;
  late LinkInstallation installation;
  late SlotOwnershipStore slots;
  late LinkInitialization initialize;
  final target =
      LinkVerifiedTarget('a' * 64, 'verified-installation', 'verified-profile');
  var alive = false;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-initialization-');
    slot = await Directory(p.join(root.path, 'slot')).create();
    stateDirectory = await Directory(p.join(root.path, 'state')).create();
    installation = LinkInstallation(
        stateDirectory: stateDirectory.path,
        slotDirectory: slot.path,
        slotRef: 'tablet',
        connectorInstanceId: 'connector',
        operationId: 'original-operation',
        adapterExecutable: p.join(root.path, 'adapter.exe'));
    slots = SlotOwnershipStore(installation);
    alive = false;
    initialize =
        LinkInitialization(installation, processCurrent: (_, __) => alive);
  });
  tearDown(() => root.delete(recursive: true));

  Future<Map<String, dynamic>> read(String name) async =>
      jsonDecode(await File(p.join(slot.path, name)).readAsString())
          as Map<String, dynamic>;
  Future<void> write(String name, Object value) async =>
      File(p.join(slot.path, name)).writeAsString(jsonEncode(value));

  // Synthetic adapter-owned receipt fixture. It is never used on a real slot,
  // never substitutes for P15, and contains no protected credential.
  Future<void> originalReceipt(
      {String operation = 'original-operation',
      String resource = 'original-resource',
      bool joined = true,
      bool close = true}) async {
    await File(p.join(slot.path, 'device.dpapi'))
        .writeAsString('test-only-ciphertext');
    await write('link-settlement.json', {
      'formatVersion': 2,
      'operationId': operation,
      'receiptRef': resource,
      'runId': 'original-run',
      'resourceId': resource,
      'processId': 100,
      'processStarted': '123456',
      'slotRef': 'tablet',
      'owner': 'connector',
      'mode': 'pairing',
      'target': target.toJson(),
      'targetClose': close,
      'tlsShutdown': true,
      'keyRetired': true,
    });
    await write('adapter-origin.json', {
      'formatVersion': 1,
      'slotRef': 'tablet',
      'origin': 'independent_adapter_pairing',
      'operationId': operation,
      'target': target.toJson(),
      'credentialSlotRef': 'device.dpapi',
      'resourceGeneration': resource,
      'settlementRef': resource,
    });
    if (joined) {
      await write('initialization-joined.json', {
        'formatVersion': 1,
        'operationId': operation,
        'slotRef': 'tablet',
        'ownerInstanceId': 'connector',
        'runId': 'original-run',
        'resourceId': resource,
        'processId': 100,
        'processStarted': '123456',
        'adapterReceiptRef': resource,
        'target': target.toJson(),
        'processExitCode': 0,
        'stdinClosed': true,
        'stdoutDrained': true,
        'stderrDrained': true,
      });
    }
  }

  test(
      'L09 preparation has no verified identity, saved credential or clean claim',
      () async {
    final store = await initialize.open(initialize: true);
    final record = await read('slot-ownership.json');
    expect(record['ownershipState'], 'UNCLAIMED');
    expect(record['verifiedInstallationBinding'], isNull);
    expect(record['adapterCredentialSlotRef'], isNull);
    expect(record['ownerGeneration'], isNull);
    expect(record['lastSettlementRef'], isNull);
    expect(record['lastSettlementState'], 'UNKNOWN');
    expect(store.state.dirtyPhase, LinkDirtyPhase.initializing);
    await expectLater(
        slots.requireOwned(store.state), throwsA(isA<LinkException>()));
    await store.close();
  });

  test('L09 preparation restart keeps original operation and revision',
      () async {
    var store = await initialize.open(initialize: true);
    await store.close();
    final before =
        await File(p.join(slot.path, 'slot-ownership.json')).readAsBytes();
    store = await initialize.open(initialize: true);
    expect(store.state.initializationOperationId, 'original-operation');
    expect(await File(p.join(slot.path, 'slot-ownership.json')).readAsBytes(),
        before);
    expect(store.state.revision, 0);
    await store.close();
  });

  test(
      'L09 verified adapter completion publishes one stable owner, repeat is idempotent',
      () async {
    final store = await initialize.open(initialize: true);
    await originalReceipt();
    await initialize.complete(store, target);
    final before = await read('slot-ownership.json');
    expect(before['ownershipState'], 'LINK_OWNED');
    expect(store.state.ownerGeneration, 'original-operation');
    await initialize.complete(store, target);
    expect(await read('slot-ownership.json'), before);
    expect((await slots.requireOwned(store.state)).toJson(), target.toJson());
    await store.close();
  });

  test(
      'L10 positive historical provenance preserves original resource evidence',
      () async {
    await originalReceipt(operation: 'prior-original-pairing');
    final store = await initialize.open(initialize: true);
    expect((await read('slot-ownership.json'))['initializationSource'],
        'registered_pairing');
    await initialize.complete(store, target);
    final record = await read('slot-ownership.json');
    expect(record['resourceGeneration'], 'original-resource');
    expect((await read('adapter-origin.json'))['operationId'],
        'prior-original-pairing');
    expect(
        await File(p.join(slot.path, 'host-handoff.json')).exists(), isFalse);
    await store.close();
  });

  test('L10 pairing alone is not proof of never-hosted provenance', () async {
    final credential = File(p.join(slot.path, 'device.dpapi'));
    await credential.writeAsString('retained-test-ciphertext');
    await expectLater(
        initialize.open(initialize: true), throwsA(isA<LinkException>()));
    expect(await credential.readAsString(), 'retained-test-ciphertext');
    expect(
        await File(p.join(slot.path, 'slot-ownership.json')).exists(), isFalse);
  });

  test(
      'L09/L10 missing new state cannot overwrite legacy owner or dirty evidence',
      () async {
    for (final name in [
      'host-handoff.json',
      'host-handoff.pending',
      'native-client-key.pending',
      'device.pending',
      'link-settlement.pending'
    ]) {
      final retained = File(p.join(slot.path, name));
      await retained.writeAsString(name == 'host-handoff.json'
          ? '{"phase":"CLAIMED","retained":"synthetic-legacy-evidence"}'
          : 'retained-dirty');
      final bytes = await retained.readAsBytes();
      await expectLater(initialize.open(initialize: true), throwsA(anything));
      expect(await retained.readAsBytes(), bytes);
      expect(await File(p.join(slot.path, 'slot-ownership.json')).exists(),
          isFalse);
      await retained.delete(); // Test fixture only.
    }
  });

  test(
      'old Link state without slot ownership is retained and routed to diagnosis',
      () async {
    final retained = File(p.join(stateDirectory.path, 'link-state.json'));
    await retained.writeAsString('{"formatVersion":1,"dirtyPhase":"active"}');
    final bytes = await retained.readAsBytes();
    await expectLater(
        initialize.open(initialize: true), throwsA(isA<LinkException>()));
    expect(await retained.readAsBytes(), bytes);
    expect(
        await File(p.join(slot.path, 'slot-ownership.json')).exists(), isFalse);
  });

  test('unverified placeholder values cannot pass the LINK_OWNED parser',
      () async {
    final prepared = await slots.prepare();
    for (final field in [
      'verifiedInstallationBinding',
      'adapterCredentialSlotRef',
      'lastSettlementRef',
      'ownerGeneration'
    ]) {
      final value = {
        ...prepared.value,
        'ownershipState': 'LINK_OWNED',
        'ownerGeneration': 'original-operation',
        'verifiedInstallationBinding': target.toJson(),
        'adapterCredentialSlotRef': 'device.dpapi',
        'lastSettlementRef': 'receipt',
        'lastSettlementState': 'CLEAN',
        field: null
      };
      expect(() => SlotOwnershipRecord(value), throwsA(anything));
    }
  });

  test(
      'live original resource refuses ownership before LINK_OWNED is published',
      () async {
    final store = await initialize.open(initialize: true);
    await originalReceipt();
    alive = true;
    await expectLater(
        initialize.complete(store, target), throwsA(isA<LinkException>()));
    expect((await read('slot-ownership.json'))['ownershipState'], 'UNCLAIMED');
    await store.close();
  });

  test('wrong binding, other operation and incomplete settlement do not claim',
      () async {
    final store = await initialize.open(initialize: true);
    await originalReceipt(close: false);
    await expectLater(initialize.complete(store, target), throwsA(anything));
    await originalReceipt(operation: 'different-operation');
    await expectLater(initialize.complete(store, target), throwsA(anything));
    await originalReceipt();
    await expectLater(
        initialize.complete(store,
            LinkVerifiedTarget('b' * 64, 'different-installation', 'profile')),
        throwsA(anything));
    expect((await read('slot-ownership.json'))['ownershipState'], 'UNCLAIMED');
    await store.close();
  });

  test('L13 complete first preparation pending resumes the original operation',
      () async {
    final original = await slots.prepare();
    await File(p.join(slot.path, 'slot-ownership.json'))
        .rename(p.join(slot.path, 'slot-ownership.pending'));
    final resumed = await slots.prepare();
    expect(resumed.value, original.value);
    expect(await File(p.join(slot.path, 'slot-ownership.pending')).exists(),
        isFalse);
  });

  test(
      'L13 partial preparation remains untouched and cannot create another operation',
      () async {
    final retained = File(p.join(slot.path, 'slot-ownership.pending'));
    await retained.writeAsString('{"operationId":"original-operation",');
    await expectLater(slots.prepare(), throwsA(anything));
    expect(
        await retained.readAsString(), '{"operationId":"original-operation",');
    expect(
        await File(p.join(slot.path, 'slot-ownership.json')).exists(), isFalse);
  });

  test(
      'L13 initial Link state publication interrupted resumes, without a second owner',
      () async {
    var store = await initialize.open(initialize: true);
    await store.close();
    final original = File(p.join(stateDirectory.path, 'link-state-v2.json'));
    await original.rename(p.join(stateDirectory.path, 'link-state-v2.pending'));
    store = await initialize.open(initialize: true);
    expect(store.state.revision, 0);
    expect(store.state.initializationOperationId, 'original-operation');
    await store.close();
  });

  test('L13 owner published before Link state finishes resumes the same owner',
      () async {
    var store = await initialize.open(initialize: true);
    final preparation = store.state.toJson();
    await originalReceipt();
    await initialize.complete(store, target);
    final owner = await read('slot-ownership.json');
    await store.close();
    // Simulates the old state left by a crash before its atomic publication.
    await File(p.join(stateDirectory.path, 'link-state-v2.json'))
        .writeAsString(jsonEncode(preparation));
    store = await initialize.open(initialize: true);
    expect(await read('slot-ownership.json'), owner);
    expect(store.state.ownerGeneration, owner['ownerGeneration']);
    expect(store.state.dirtyPhase, LinkDirtyPhase.clean);
    await store.close();
  });

  test('L13 concurrent initializers cannot acquire the same slot control lock',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final holder = slots.locked(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      await expectLater(slots.prepare(), throwsA(isA<LinkException>()));
    } finally {
      release.complete();
      await holder;
    }
    expect((await slots.prepare()).operationId, 'original-operation');
  });

  test('conflicting installer operation never replaces the first preparation',
      () async {
    await slots.prepare();
    final before = await read('slot-ownership.json');
    final other = SlotOwnershipStore(LinkInstallation(
        stateDirectory: stateDirectory.path,
        slotDirectory: slot.path,
        slotRef: 'tablet',
        connectorInstanceId: 'other',
        operationId: 'other-operation',
        adapterExecutable: installation.adapterExecutable));
    await expectLater(other.prepare(), throwsA(isA<LinkException>()));
    expect(await read('slot-ownership.json'), before);
  });

  test(
      'L13 state pending cannot be published while the original state writer is open',
      () async {
    final store = await initialize.open(initialize: true);
    final pending = File(p.join(stateDirectory.path, 'link-state-v2.pending'));
    await pending.writeAsString(jsonEncode(
        store.state.change({'diagnostic': 'initialization_pending'}).toJson()));
    final bytes = await pending.readAsBytes();
    await expectLater(initialize.open(initialize: true), throwsA(anything));
    expect(await pending.readAsBytes(), bytes);
    await store.close();
    final resumed = await initialize.open(initialize: true);
    expect(resumed.state.revision, 1);
    expect(resumed.state.initializationOperationId, 'original-operation');
    await resumed.close();
  });

  test(
      'adapter receipt and a gone PID do not replace original process and stream settlement',
      () async {
    final store = await initialize.open(initialize: true);
    try {
      await originalReceipt(joined: false);
      await expectLater(
          initialize.complete(store, target), throwsA(isA<LinkException>()));
      expect(
          (await read('slot-ownership.json'))['ownershipState'], 'UNCLAIMED');
    } finally {
      await store.close();
    }
  });

  test(
      'L13 original join publication resumes and incomplete stream evidence refuses ownership',
      () async {
    var store = await initialize.open(initialize: true);
    await originalReceipt();
    final path = File(p.join(slot.path, 'initialization-joined.json'));
    final joined = await read('initialization-joined.json');
    await write(
        'initialization-joined.json', {...joined, 'stderrDrained': false});
    await expectLater(
        initialize.complete(store, target), throwsA(isA<LinkException>()));
    expect((await read('slot-ownership.json'))['ownershipState'], 'UNCLAIMED');
    await write('initialization-joined.json', joined);
    await path.rename(p.join(slot.path, 'initialization-joined.pending'));
    await store.close();
    store = await initialize.open(initialize: true);
    await initialize.complete(store, target);
    expect(store.state.ownerGeneration, 'original-operation');
    expect(await read('initialization-joined.json'), joined);
    await store.close();
  });

  test(
      'L13 resource reservation before local attempt write reuses the original resource',
      () async {
    var store = await initialize.open(initialize: true);
    final prepared = await slots.prepare();
    await slots.locked(() => slots.writeLocked(
        prepared.change({
          'resourceGeneration': 'reserved-original-resource',
        }),
        prepared.revision));
    await store.close();
    store = await initialize.open(initialize: true);
    final attempt = await initialize.beginAttempt(store, 'new-process-run');
    expect(attempt.resourceId, 'reserved-original-resource');
    expect(
        (await initialize.beginAttempt(store, 'ignored-second-run')).toJson(),
        attempt.toJson());
    expect(store.state.initializationOperationId, 'original-operation');
    await store.close();
  });
}
