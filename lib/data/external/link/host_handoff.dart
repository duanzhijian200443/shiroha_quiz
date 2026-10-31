import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../services/backup/sha256.dart';
import '../bounded_json_object.dart';
import 'link_state_store.dart';
import 'link_values.dart';

enum HostHandoffPhase { prepared, released, claimed }

final class HostHandoffRecord {
  const HostHandoffRecord(
      {required this.handoffId,
      required this.handoffRevision,
      required this.slotRef,
      required this.target,
      required this.oldOwnerInstance,
      required this.oldSelectionGeneration,
      required this.oldStateRevision,
      required this.oldStateDigest,
      required this.releaseRecordRef,
      required this.newOwner,
      required this.newLinkStateRevision,
      required this.phase});
  final String handoffId,
      slotRef,
      oldOwnerInstance,
      oldStateDigest,
      releaseRecordRef,
      newOwner;
  final int handoffRevision,
      oldSelectionGeneration,
      oldStateRevision,
      newLinkStateRevision;
  final LinkVerifiedTarget target;
  final HostHandoffPhase phase;
  Map<String, Object?> toJson() => {
        'formatVersion': 1,
        'handoffId': handoffId,
        'handoffRevision': handoffRevision,
        'slotRef': slotRef,
        'target': target.toJson(),
        'oldOwnerInstance': oldOwnerInstance,
        'oldSelectionGeneration': oldSelectionGeneration,
        'oldStateRevision': oldStateRevision,
        'oldStateDigest': oldStateDigest,
        'releaseRecordRef': releaseRecordRef,
        'newOwner': newOwner,
        'newLinkStateRevision': newLinkStateRevision,
        'phase': phase.name.toUpperCase()
      };
  factory HostHandoffRecord.fromJson(Map<String, dynamic> value) {
    linkFields(value, {
      'formatVersion',
      'handoffId',
      'handoffRevision',
      'slotRef',
      'target',
      'oldOwnerInstance',
      'oldSelectionGeneration',
      'oldStateRevision',
      'oldStateDigest',
      'releaseRecordRef',
      'newOwner',
      'newLinkStateRevision',
      'phase'
    });
    if (value['formatVersion'] != 1) linkFail('handoff_required');
    try {
      return HostHandoffRecord(
          handoffId: linkToken(value['handoffId']),
          handoffRevision: linkRevision(value['handoffRevision']),
          slotRef: linkToken(value['slotRef']),
          target: LinkVerifiedTarget.fromJson(
              value['target'] as Map<String, dynamic>),
          oldOwnerInstance: linkToken(value['oldOwnerInstance']),
          oldSelectionGeneration: linkRevision(value['oldSelectionGeneration']),
          oldStateRevision: linkRevision(value['oldStateRevision']),
          oldStateDigest: linkToken(value['oldStateDigest'], digest: true),
          releaseRecordRef: linkToken(value['releaseRecordRef']),
          newOwner: linkToken(value['newOwner']),
          newLinkStateRevision: linkRevision(value['newLinkStateRevision']),
          phase: HostHandoffPhase.values
              .byName((value['phase'] as String).toLowerCase()));
    } catch (_) {
      linkFail('handoff_required');
    }
  }
  HostHandoffRecord advance(HostHandoffPhase next, {int? claimRevision}) =>
      HostHandoffRecord.fromJson({
        ...toJson(),
        'handoffRevision': handoffRevision + 1,
        'phase': next.name.toUpperCase(),
        'newLinkStateRevision': claimRevision ?? newLinkStateRevision
      });
  String get digest => sha256Hex(utf8.encode(jsonEncode(toJson())));
}

/// The old App implements this port. Link never reads the old database.
abstract interface class OldHostReleaseAuthority {
  /// Withdraws the old entry and joins original work/output/TLS/key/process.
  /// The reserved release reference is committed only after PREPARED exists.
  Future<HostHandoffRecord> freezeAndSettle(String newOwner);
  Future<void> commitRelease(HostHandoffRecord prepared);
  Future<bool> releaseCommitted(HostHandoffRecord prepared);
}

/// Protected installation-selected slot only. Same lock as the original adapter.
final class HostHandoffStore {
  HostHandoffStore(this.directory);
  final Directory directory;
  Future<T> _locked<T>(Future<T> Function() work) async {
    final guard = await File(p.join(directory.path, 'adapter.lock'))
        .open(mode: FileMode.append);
    var acquired = false;
    try {
      await guard.lock(FileLock.exclusive);
      acquired = true;
      if (await File(p.join(directory.path, 'native-client-key.pending'))
              .exists() ||
          await File(p.join(directory.path, 'host-handoff.pending')).exists()) {
        linkFail();
      }
      return await work();
    } finally {
      if (acquired) await guard.unlock();
      await guard.close();
    }
  }

  File get _file => File(p.join(directory.path, 'host-handoff.json'));
  Future<HostHandoffRecord?> _read() async => !await _file.exists()
      ? null
      : HostHandoffRecord.fromJson(boundedJsonObject(
          await readBoundedLinkFile(_file),
          maxBytes: linkStateLimit));
  Future<HostHandoffRecord?> read() => _locked(_read);
  Future<Map<String, dynamic>> settledReceipt() => _locked(() async {
        if (await File(p.join(directory.path, 'link-settlement.pending'))
            .exists()) {
          linkFail();
        }
        return boundedJsonObject(
            await readBoundedLinkFile(
                File(p.join(directory.path, 'link-settlement.json'))),
            maxBytes: linkStateLimit);
      });
  Future<void> _write(HostHandoffRecord value) async {
    HostHandoffRecord.fromJson(Map<String, dynamic>.from(value.toJson()));
    final pending = File(p.join(directory.path, 'host-handoff.pending'));
    final handle = await pending.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString(jsonEncode(value.toJson()));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await pending.rename(_file.path);
    if ((await _read())?.digest != value.digest) linkFail();
  }

  Future<void> prepare(HostHandoffRecord prepared) => _locked(() async {
        if (prepared.phase != HostHandoffPhase.prepared ||
            prepared.handoffRevision != 0) {
          linkFail();
        }
        final existing = await _read();
        if (existing != null) {
          if (existing.digest != prepared.digest) linkFail('handoff_conflict');
          return;
        }
        await _write(prepared);
      });
  Future<void> _replace(HostHandoffRecord expected, HostHandoffRecord next) =>
      _locked(() async {
        if ((await _read())?.digest != expected.digest ||
            next.handoffRevision != expected.handoffRevision + 1 ||
            next.handoffId != expected.handoffId) {
          linkFail('handoff_conflict');
        }
        await _write(next);
      });
  Future<HostHandoffRecord> release(
      OldHostReleaseAuthority old, String newOwner) async {
    final previous = await read();
    if (previous != null && previous.phase != HostHandoffPhase.prepared) {
      final original = HostHandoffRecord.fromJson({
        ...previous.toJson(),
        'handoffRevision': 0,
        'newLinkStateRevision': 0,
        'phase': 'PREPARED'
      });
      if (previous.newOwner != newOwner ||
          !await old.releaseCommitted(original)) {
        linkFail('handoff_conflict');
      }
      return previous;
    }
    final prepared = previous ?? await old.freezeAndSettle(newOwner);
    if (prepared.newOwner != newOwner ||
        prepared.phase != HostHandoffPhase.prepared) {
      linkFail('handoff_conflict');
    }
    await prepare(prepared); // fence BEFORE the owning SQLite transaction
    if (!await old.releaseCommitted(prepared)) {
      await old.commitRelease(prepared);
    }
    if (!await old.releaseCommitted(prepared)) linkFail();
    final released = prepared.advance(HostHandoffPhase.released);
    await _replace(prepared, released);
    return released;
  }

  Future<void> claim(LinkStateStore local, {required String slotRef}) async {
    var shared = await read();
    var state = local.state;
    if (shared?.phase == HostHandoffPhase.claimed &&
        state.dirtyPhase == LinkDirtyPhase.clean) {
      await requireClaim(state, slotRef);
      return;
    }
    if (shared == null ||
        shared.newOwner != state.connectorInstanceId ||
        shared.slotRef != slotRef ||
        shared.phase == HostHandoffPhase.prepared) {
      linkFail('handoff_required');
    }
    if (state.dirtyPhase == LinkDirtyPhase.clean &&
        shared.phase == HostHandoffPhase.released) {
      final pending = state.change({
        'handoffId': shared.handoffId,
        'dirtyPhase': 'claimPending',
        'targetRef': slotRef,
        'selectionRevision': state.selectionRevision + 1,
        'diagnostic': 'handoff_pending',
        'settlement': 'unknown'
      });
      await local.replace(pending, expectedRevision: state.revision);
      state = local.state;
    }
    if (state.dirtyPhase != LinkDirtyPhase.claimPending ||
        state.handoffId != shared.handoffId ||
        state.targetRef != slotRef) {
      linkFail('handoff_conflict');
    }
    if (shared.phase == HostHandoffPhase.released) {
      final claimed = shared.advance(HostHandoffPhase.claimed,
          claimRevision: state.revision);
      await _replace(shared, claimed);
      shared = claimed;
    }
    if (shared.newLinkStateRevision != state.revision) {
      linkFail('handoff_conflict');
    }
    final clean = state.change(
        {'dirtyPhase': 'clean', 'diagnostic': 'none', 'settlement': 'clean'});
    await local.replace(clean, expectedRevision: state.revision);
    await requireClaim(local.state, slotRef);
  }

  Future<HostHandoffRecord> requireClaim(
      LinkState state, String slotRef) async {
    final record = await read();
    if (record == null ||
        record.phase != HostHandoffPhase.claimed ||
        record.slotRef != slotRef ||
        record.newOwner != state.connectorInstanceId ||
        record.handoffId != state.handoffId ||
        record.newLinkStateRevision >= state.revision ||
        state.dirtyPhase == LinkDirtyPhase.claimPending) {
      linkFail('handoff_required');
    }
    return record;
  }
}
