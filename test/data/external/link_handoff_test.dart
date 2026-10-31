import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/host_handoff.dart';
import 'package:shiroha_quiz/data/external/link/link_state_store.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';

HostHandoffRecord preparedRecord() => HostHandoffRecord(
    handoffId: 'handoff',
    handoffRevision: 0,
    slotRef: 'phone',
    target: LinkVerifiedTarget('a' * 64, 'installation', 'profile'),
    oldOwnerInstance: 'old-owner',
    oldSelectionGeneration: 7,
    oldStateRevision: 7,
    oldStateDigest: 'b' * 64,
    releaseRecordRef: 'exact-release',
    newOwner: 'new-owner',
    newLinkStateRevision: 0,
    phase: HostHandoffPhase.prepared);

final class OldOwner implements OldHostReleaseAuthority {
  OldOwner(this.slot);
  final HostHandoffStore slot;
  bool committed = false, crashAfterCommit = false, failCommit = false;
  int freezes = 0, commits = 0;
  @override
  Future<HostHandoffRecord> freezeAndSettle(String newOwner) async {
    freezes++;
    return preparedRecord();
  }

  @override
  Future<void> commitRelease(HostHandoffRecord prepared) async {
    expect((await slot.read())!.phase, HostHandoffPhase.prepared);
    commits++;
    if (failCommit) throw StateError('injected_transaction_failure');
    committed = true;
    if (crashAfterCommit) throw StateError('injected_interruption');
  }

  @override
  Future<bool> releaseCommitted(HostHandoffRecord prepared) async => committed;
}

void main() {
  late Directory root, slotDir, localDir;
  late HostHandoffStore slot;
  late LinkStateStore local;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('link-handoff-');
    slotDir = await Directory(p.join(root.path, 'slot')).create();
    localDir = await Directory(p.join(root.path, 'local')).create();
    slot = HostHandoffStore(slotDir);
    local =
        await LinkStateStore.open(localDir, initializeInstance: 'new-owner');
  });
  tearDown(() async {
    await local.close();
    await root.delete(recursive: true);
  });
  test('PREPARED precedes old commit; failed commit never releases', () async {
    final old = OldOwner(slot)..failCommit = true;
    await expectLater(slot.release(old, 'new-owner'), throwsStateError);
    expect((await slot.read())!.phase, HostHandoffPhase.prepared);
    await expectLater(
        slot.claim(local, slotRef: 'phone'), throwsA(isA<LinkException>()));
    expect(local.state.revision, 0);
  });
  test(
      'old commit then crash resumes exact release without another transaction',
      () async {
    final old = OldOwner(slot)..crashAfterCommit = true;
    await expectLater(slot.release(old, 'new-owner'), throwsStateError);
    expect((await slot.read())!.phase, HostHandoffPhase.prepared);
    old.crashAfterCommit = false;
    final released = await slot.release(old, 'new-owner');
    expect(released.phase, HostHandoffPhase.released);
    expect(released.releaseRecordRef, 'exact-release');
    expect(old.commits, 1);
    await slot.claim(local, slotRef: 'phone');
    final claimed = await slot.requireClaim(local.state, 'phone');
    expect(claimed.phase, HostHandoffPhase.claimed);
    expect(local.state.dirtyPhase, LinkDirtyPhase.clean);
    expect(local.state.lease, isNull);
    expect((await slot.release(old, 'new-owner')).digest, claimed.digest);
  });
  test('CLAIMED before final local replace recovers same pending claim',
      () async {
    final released = await slot.release(OldOwner(slot), 'new-owner');
    await local.replace(
        local.state.change({
          'targetRef': 'phone',
          'handoffId': 'handoff',
          'dirtyPhase': 'claimPending',
          'selectionRevision': 1,
          'settlement': 'unknown',
          'diagnostic': 'handoff_pending'
        }),
        expectedRevision: 0);
    final claimed =
        released.advance(HostHandoffPhase.claimed, claimRevision: 1);
    await File(p.join(slotDir.path, 'host-handoff.json'))
        .writeAsString(jsonEncode(claimed.toJson()));
    await local.close();
    local = await LinkStateStore.open(localDir);
    await slot.claim(local, slotRef: 'phone');
    expect(local.state.revision, 2);
    await slot.claim(local, slotRef: 'phone');
    expect(local.state.revision, 2);
  });
  test('second owner, stale claim and unknown CNG marker retain fences',
      () async {
    await slot.release(OldOwner(slot), 'new-owner');
    await slot.claim(local, slotRef: 'phone');
    final original = (await slot.read())!.digest;
    final foreignDir = await Directory(p.join(root.path, 'foreign')).create();
    final foreign = await LinkStateStore.open(foreignDir,
        initializeInstance: 'other-owner');
    await expectLater(
        slot.claim(foreign, slotRef: 'phone'), throwsA(isA<LinkException>()));
    await foreign.close();
    final marker = File(p.join(slotDir.path, 'native-client-key.pending'));
    await marker.writeAsString('test-owned-marker');
    await expectLater(slot.read(), throwsA(isA<LinkException>()));
    expect(await marker.readAsString(), 'test-owned-marker');
    expect(
        HostHandoffRecord.fromJson(jsonDecode(
                await File(p.join(slotDir.path, 'host-handoff.json'))
                    .readAsString()) as Map<String, dynamic>)
            .digest,
        original);
  });
}
