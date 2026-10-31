import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/bounded_json_object.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';

void main() {
  test(
      'generated identifiers retain 256 random bits and always pass the token codec',
      () {
    for (var i = 0; i < 128; i++) {
      final id = linkNonce();
      expect(linkToken(id), id);
      expect(base64Url.decode('${id.substring(1)}=').length, 32);
    }
  });
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shiroha-link-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<LinkStateStore> create() =>
      LinkStateStore.open(directory, initializeInstance: 'test-connector');
  test('dirty owner survives restart without new generation or implicit repair',
      () async {
    var store = await create();
    final next = store.state.change({
      'targetRef': 'phone',
      'dirtyPhase': 'preparing',
      'settlement': 'unknown',
      'owner': const LinkOwnerReference(
              runId: 'run-1',
              resourceId: 'resource-1',
              processId: 0,
              processStarted: 'pending',
              slotRef: 'phone')
          .toJson()
    });
    await store.replace(next, expectedRevision: 0);
    await store.close();
    store = await LinkStateStore.open(directory);
    expect(store.state.toJson(), next.toJson());
    expect(store.state.dirtyPhase, LinkDirtyPhase.preparing);
    await store.close();
  });
  test('stale revision cannot clear the original dirty state', () async {
    final store = await create();
    final dirty = store.state.change({
      'targetRef': 'phone',
      'dirtyPhase': 'recoveryRequired',
      'settlement': 'unknown'
    });
    await store.replace(dirty, expectedRevision: 0);
    await expectLater(
        store.replace(
            dirty.change({'dirtyPhase': 'clean', 'settlement': 'clean'}),
            expectedRevision: 0),
        throwsA(isA<LinkException>()));
    await store.close();
    final reopened = await LinkStateStore.open(directory);
    expect(reopened.state.dirtyPhase, LinkDirtyPhase.recoveryRequired);
    await reopened.close();
  });
  test('interrupted atomic replacement is retained and blocks restart',
      () async {
    final store = await create();
    await store.close();
    final pending = File(p.join(directory.path, 'link-state.pending'));
    await pending.writeAsString('{');
    await expectLater(
        LinkStateStore.open(directory), throwsA(isA<LinkException>()));
    expect(await pending.readAsString(), '{');
  });
  test(
      'corruption, foreign fields and oversize never become an empty selection',
      () async {
    final store = await create();
    final valid = store.state.toJson();
    await store.close();
    final file = File(p.join(directory.path, 'link-state.json'));
    for (final raw in [
      '{',
      jsonEncode({
        ...valid,
        'request': {'tool': 'write'}
      }),
      ' ' * (linkStateLimit + 1)
    ]) {
      await file.writeAsString(raw);
      await expectLater(LinkStateStore.open(directory), throwsA(anything));
      expect(await file.readAsString(), raw);
    }
  });
  test('missing state is not inferred to be a fresh installation', () async {
    await expectLater(
        LinkStateStore.open(directory), throwsA(isA<LinkException>()));
    expect(await File(p.join(directory.path, 'link-state.json')).exists(),
        isFalse);
  });
  test('lease cannot transfer between targets or route generations', () async {
    final store = await create();
    final lease = LinkLease(
        connectorRunId: 'run',
        selectionRevision: 1,
        routeGeneration: 2,
        targetRef: 'other',
        target: LinkVerifiedTarget('a' * 64, 'installation', 'profile'),
        frontendPeerIdentity: 'kernel-peer',
        frontendConnectionId: 'connection',
        leaseId: 'lease');
    expect(
        () => store.state.change({
              'targetRef': 'phone',
              'dirtyPhase': 'active',
              'settlement': 'unknown',
              'owner': const LinkOwnerReference(
                      runId: 'run',
                      resourceId: 'resource',
                      processId: 10,
                      processStarted: 'creation-time',
                      slotRef: 'phone')
                  .toJson(),
              'lease': lease.toJson()
            }),
        throwsA(isA<LinkException>()));
    await store.close();
  });
  test('duplicate and escaped duplicate JSON fields fail before map folding',
      () {
    for (final raw in [
      r'{"a":1,"a":2}',
      r'{"a":1,"\u0061":2}',
      r'{"a":{"b":1,"b":2}}'
    ]) {
      expect(
          () => boundedJsonObject(Uint8List.fromList(utf8.encode(raw)),
              maxBytes: 128),
          throwsFormatException);
    }
  });
}
